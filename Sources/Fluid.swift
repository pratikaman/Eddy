import MetalKit
import simd

// Knobs. The sim is physically meaningless, these are taste.
enum Tuning {
    static let simWidth = 256               // velocity/pressure grid; height follows the screen aspect
    static let dyeWidth = 1024
    static let pressureIterations = 20
    static let curlStrength: Float = 30
    static let velocityDissipation: Float = 0.2   // per second
    static let dyeDissipation: Float = 1.0
    static let emitterForce: Float = 20
    static let emitterDye: Float = 0.08
    static let emitterRadius: Float = 0.002
    static let beatForce: Float = 250
    static let beatRadius: Float = 0.004
    static let sparkleRate: Float = 0.4           // sparkles per frame at high == 1
}

struct Splat { var point: SIMD2<Float>; var aspectRadius: SIMD2<Float>; var value: SIMD4<Float> }
struct Sim { var texel: SIMD2<Float>; var dt: Float; var k: Float }

func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD4<Float> {
    let i = Int(floor(h * 6)) % 6, f = h * 6 - floor(h * 6)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return [v, t, p, 0]
    case 1: return [q, v, p, 0]
    case 2: return [p, v, t, 0]
    case 3: return [p, q, v, 0]
    case 4: return [t, p, v, 0]
    default: return [v, p, q, 0]
    }
}

/// Three invisible brushes wandering on Lissajous paths keep the fluid alive in silence.
private struct Emitter {
    var freq: SIMD2<Float>, phase: SIMD2<Float>, hue: Float, last: SIMD2<Float>
    func position(at t: Float) -> SIMD2<Float> { SIMD2(0.5, 0.5) + SIMD2(0.4, 0.35) * sin(freq * t + phase) }
}

/// Stam-style stable fluids on ping-pong textures, driven by the frame's audio.
final class FluidScene: Scene {
    private let device: MTLDevice
    private let kernels: [String: MTLComputePipelineState]
    private let display: MTLRenderPipelineState
    private var velocity: MTLTexture, velocity2: MTLTexture
    private var dye: MTLTexture, dye2: MTLTexture
    private var pressure: MTLTexture, pressure2: MTLTexture
    private let divergence: MTLTexture, curl: MTLTexture
    private let simSize: SIMD2<Int>
    private let aspect: Float
    private var emitters: [Emitter]

    init(device dev: MTLDevice, library lib: MTLLibrary, aspect asp: Float) {
        var k: [String: MTLComputePipelineState] = [:]
        for name in ["splat", "advect", "divergence", "jacobi", "gradientSubtract", "curl", "vorticity"] {
            k[name] = try! dev.makeComputePipelineState(function: lib.makeFunction(name: name)!)
        }
        let rp = MTLRenderPipelineDescriptor()
        rp.vertexFunction = lib.makeFunction(name: "fullscreen")
        rp.fragmentFunction = lib.makeFunction(name: "display")
        rp.colorAttachments[0].pixelFormat = .bgra8Unorm

        let sim = SIMD2(Tuning.simWidth, Int(Float(Tuning.simWidth) / asp))
        let dyeSize = SIMD2(Tuning.dyeWidth, Int(Float(Tuning.dyeWidth) / asp))
        func tex(_ s: SIMD2<Int>, _ f: MTLPixelFormat, _ bpp: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: s.x, height: s.y, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            let t = dev.makeTexture(descriptor: d)!
            let zeros = [UInt8](repeating: 0, count: s.x * s.y * bpp)
            t.replace(region: MTLRegionMake2D(0, 0, s.x, s.y), mipmapLevel: 0, withBytes: zeros, bytesPerRow: s.x * bpp)
            return t
        }

        device = dev
        kernels = k
        display = try! dev.makeRenderPipelineState(descriptor: rp)
        aspect = asp
        simSize = sim
        velocity = tex(sim, .rgba16Float, 8); velocity2 = tex(sim, .rgba16Float, 8)
        pressure = tex(sim, .r16Float, 2); pressure2 = tex(sim, .r16Float, 2)
        divergence = tex(sim, .r16Float, 2); curl = tex(sim, .r16Float, 2)
        dye = tex(dyeSize, .rgba16Float, 8); dye2 = tex(dyeSize, .rgba16Float, 8)
        emitters = (0..<3).map { i in
            var e = Emitter(freq: SIMD2(.random(in: 0.05...0.12), .random(in: 0.05...0.12)),
                            phase: SIMD2(.random(in: 0..<6.28), .random(in: 0..<6.28)),
                            hue: Float(i) / 3, last: .zero)
            e.last = e.position(at: 0)
            return e
        }
    }

    func draw(_ cb: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, _ frame: Frame) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        emit(enc, frame)
        step(enc, frame.dt)
        enc.endEncoding()
        guard let r = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        r.setRenderPipelineState(display)
        r.setFragmentTexture(dye, index: 0)
        r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        r.endEncoding()
    }

    // MARK: forces in

    private func emit(_ enc: MTLComputeCommandEncoder, _ f: Frame) {
        let dt = f.dt, gain = f.gain, palette = f.palette
        let perFrame = dt * 60

        for i in emitters.indices {
            let p = emitters[i].position(at: f.time)
            let v = (p - emitters[i].last) / max(dt, 1e-3)
            emitters[i].last = p
            emitters[i].hue = (emitters[i].hue + dt * (0.01 + 0.1 * f.mid)).truncatingRemainder(dividingBy: 1)
            let force = v * Float(simSize.x) * Tuning.emitterForce * dt
            splat(enc, velocity, p, Tuning.emitterRadius, SIMD4(force.x, force.y, 0, 0))
            let color = palette.color(emitters[i].hue) * Tuning.emitterDye * (1 + 4 * f.bass * gain) * perFrame
            splat(enc, dye, p, Tuning.emitterRadius * (1 + 2 * f.bass * gain), color)
        }
        for _ in 0..<f.newBeats { burst(enc, palette, gain) }
        if Float.random(in: 0..<1) < f.high * Tuning.sparkleRate * perFrame * gain { sparkle(enc, palette) }
    }

    private func burst(_ enc: MTLComputeCommandEncoder, _ palette: Palette, _ gain: Float) {
        let p = SIMD2<Float>(.random(in: 0.15...0.85), .random(in: 0.15...0.85))
        let force = Tuning.beatForce * gain
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            let d = SIMD2<Float>(cos(a), sin(a))
            splat(enc, velocity, p + d * 0.03, Tuning.beatRadius, SIMD4(d.x * force, d.y * force, 0, 0))
        }
        splat(enc, dye, p, Tuning.beatRadius * 2 * gain, palette.color(.random(in: 0..<1)) * 0.8)
    }

    private func sparkle(_ enc: MTLComputeCommandEncoder, _ palette: Palette) {
        let p = SIMD2<Float>(.random(in: 0.05...0.95), .random(in: 0.05...0.95))
        let a = Float.random(in: 0..<2 * .pi)
        splat(enc, velocity, p, 0.0006, SIMD4(cos(a) * 80, sin(a) * 80, 0, 0))
        let tint = palette.color(.random(in: 0..<1)) * 0.4 + SIMD4<Float>(0.6, 0.6, 0.6, 0)   // palette-tinted white
        splat(enc, dye, p, 0.0004, tint * 0.6)
    }

    private func splat(_ enc: MTLComputeCommandEncoder, _ tex: MTLTexture, _ p: SIMD2<Float>, _ radius: Float, _ value: SIMD4<Float>) {
        run(enc, "splat", [tex], Splat(point: p, aspectRadius: SIMD2(aspect, radius), value: value))
    }

    // MARK: one sim step

    private func step(_ enc: MTLComputeCommandEncoder, _ dt: Float) {
        let texel = SIMD2<Float>(1 / Float(simSize.x), 1 / Float(simSize.y))
        let sim = Sim(texel: texel, dt: dt, k: 0)
        run(enc, "curl", [velocity, curl], sim)
        run(enc, "vorticity", [curl, velocity], Sim(texel: texel, dt: dt, k: Tuning.curlStrength))
        run(enc, "divergence", [velocity, divergence], sim)
        for _ in 0..<Tuning.pressureIterations {          // warm-started from last frame
            run(enc, "jacobi", [pressure, divergence, pressure2], sim)
            swap(&pressure, &pressure2)
        }
        run(enc, "gradientSubtract", [pressure, velocity], sim)
        run(enc, "advect", [velocity, velocity, velocity2], Sim(texel: texel, dt: dt, k: 1 / (1 + Tuning.velocityDissipation * dt)))
        swap(&velocity, &velocity2)
        run(enc, "advect", [velocity, dye, dye2], Sim(texel: texel, dt: dt, k: 1 / (1 + Tuning.dyeDissipation * dt)))
        swap(&dye, &dye2)
    }

    /// Dispatches `name` over the last texture's grid; textures bind in order, params to buffer 0.
    private func run<T>(_ enc: MTLComputeCommandEncoder, _ name: String, _ textures: [MTLTexture], _ params: T) {
        var p = params
        enc.setComputePipelineState(kernels[name]!)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        enc.setBytes(&p, length: MemoryLayout<T>.stride, index: 0)
        let grid = textures.last!
        enc.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }
}
