import AppKit
import MetalKit
import QuartzCore

enum SceneKind: String, CaseIterable {
    case smoke = "Smoke", aurora = "Aurora", lava = "Lava", nebula = "Nebula", pulse = "Pulse"
    /// Fragment function for single-pass scenes; Smoke is the fluid sim and has none.
    var fragment: String? { self == .smoke ? nil : "scene_\(rawValue.lowercased())" }
}

/// Everything a scene gets per frame. Audio is already smoothed and gated by the user's settings.
struct Frame {
    var dt: Float, time: Float
    var bass: Float, mid: Float, high: Float
    var beat: Float          // 1 on a beat, fading to 0
    var newBeats: Int        // beats since the previous frame (capped at 2)
    var beatPhase: Float     // +1 per beat, gliding; lets stateless shaders step on the beat
    var palette: Palette, gain: Float
    var size: SIMD2<Float>   // drawable pixels
}

protocol Scene: AnyObject {
    func draw(_ cb: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, _ frame: Frame)
}

/// Mirrors `Uniforms` in Shaders.metal (48 bytes).
struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var beat: Float
    var audio: SIMD4<Float>     // bass, mid, high, gain
    var palette: SIMD4<Float>   // hue base, hue span, saturation, beat phase
}

/// One fullscreen fragment shader driven by `Uniforms`.
final class ShaderScene: Scene {
    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary, fragment: String) {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen")
        d.fragmentFunction = library.makeFunction(name: fragment)!
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
    }

    func draw(_ cb: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, _ f: Frame) {
        let r = f.palette.range
        var u = Uniforms(resolution: f.size, time: f.time, beat: f.beat,
                         audio: [f.bass, f.mid, f.high, f.gain],
                         palette: [r.base, r.span, r.sat, f.beatPhase])
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Owns the clock and the audio smoothing; swaps scenes when the setting changes.
final class Renderer: NSObject, MTKViewDelegate {
    /// Compiled at launch from the bundled .metal source: no Metal toolchain needed to build.
    static func makeLibrary(_ device: MTLDevice) throws -> MTLLibrary {
        let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal")!
        return try device.makeLibrary(source: try String(contentsOf: url, encoding: .utf8), options: nil)
    }

    static func makeScene(_ kind: SceneKind, _ device: MTLDevice, _ library: MTLLibrary, aspect: Float) -> Scene {
        if let fragment = kind.fragment { return ShaderScene(device: device, library: library, fragment: fragment) }
        return FluidScene(device: device, library: library, aspect: aspect)
    }

    private let device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary
    private let audio: AudioInput?
    private var scene: Scene?, kind: SceneKind?
    private var time: Float = 0, last = CACurrentMediaTime()
    private var smooth = AudioInput.Levels(), beatsSeen = 0
    private var beat: Float = 0, beatTarget: Float = 0, beatPhase: Float = 0

    init(view: MTKView, audio: AudioInput?) {
        device = view.device ?? MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = try! Renderer.makeLibrary(device)
        self.audio = audio
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let s = Settings.shared
        if kind != s.scene {
            scene = Renderer.makeScene(s.scene, device, library, aspect: Float(view.bounds.width / max(view.bounds.height, 1)))
            kind = s.scene
        }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - last, 1.0 / 30)); last = now; time += dt

        let raw = audio?.current() ?? .init()
        let live = s.reactive ? raw : .init()
        smooth.bass = max(live.bass, smooth.bass - dt * 4)
        smooth.mid = max(live.mid, smooth.mid - dt * 4)
        smooth.high = max(live.high, smooth.high - dt * 4)
        var newBeats = 0
        if s.reactive {
            beatsSeen = max(beatsSeen, raw.beats - 2)   // never replay a backlog
            newBeats = raw.beats - beatsSeen
        }
        beatsSeen = raw.beats
        beat = newBeats > 0 ? 1 : max(0, beat - dt * 3)
        beatTarget += Float(newBeats)
        beatPhase += (beatTarget - beatPhase) * min(1, dt * 10)

        let frame = Frame(dt: dt, time: time, bass: smooth.bass, mid: smooth.mid, high: smooth.high,
                          beat: beat, newBeats: newBeats, beatPhase: beatPhase,
                          palette: s.palette, gain: s.intensity.gain,
                          size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
        guard let cb = queue.makeCommandBuffer(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        scene?.draw(cb, pass, frame)
        cb.present(drawable)
        cb.commit()
    }

    /// Renders every scene offscreen with a synthetic loud frame. Fails if a shader doesn't compile
    /// or a scene comes out black; with `dir` set, also writes `<scene>.png` files for the README.
    static func preview(to dir: String?) {
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let library: MTLLibrary
        do { library = try makeLibrary(device) } catch { print("shader compile failed:\n\(error)"); exit(1) }
        let w = 960, h = 600
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = device.makeTexture(descriptor: desc)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        for kind in SceneKind.allCases {
            let scene = makeScene(kind, device, library, aspect: Float(w) / Float(h))
            let steps = kind == .smoke ? 420 : 1                    // the fluid needs time to fill in
            for i in 0..<steps {
                let frame = Frame(dt: 1 / 60, time: 40 + Float(i) / 60, bass: 0.6, mid: 0.4, high: 0.5,
                                  beat: 0.5, newBeats: kind == .smoke && i % 45 == 0 ? 1 : 0, beatPhase: 3.3,
                                  palette: .neon, gain: 1, size: SIMD2(Float(w), Float(h)))
                let cb = queue.makeCommandBuffer()!
                scene.draw(cb, pass, frame)
                cb.commit()
                cb.waitUntilCompleted()
            }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var sum = 0
            for i in stride(from: 0, to: bytes.count, by: 4) { sum += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) }
            let mean = sum / (w * h * 3)
            precondition(mean > 2, "\(kind.rawValue) rendered black")
            print("\(kind.rawValue): mean brightness \(mean)/255")
            if let dir {
                let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
                let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
                try! rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: "\(dir)/\(kind.rawValue.lowercased()).png"))
            }
        }
    }
}
