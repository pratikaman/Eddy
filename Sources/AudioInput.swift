import Accelerate
import AVFoundation
import CoreAudio
import Foundation

enum Source: String, CaseIterable {
    case system = "System Audio", room = "Room (Microphone)"
}

/// Feeds the analyzer from either a Core Audio process tap (whatever macOS is playing,
/// macOS 14.2+) or the microphone, and publishes bass / mid / high levels plus a beat counter.
final class AudioInput {
    struct Levels { var bass: Float = 0, mid: Float = 0, high: Float = 0; var beats = 0 }

    private let lock = NSLock()
    private var levels = Levels()
    private let analyzer = Analyzer()
    private let queue = DispatchQueue(label: "eddy.audio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?

    init() {
        // Headphones in, speakers out: the aggregate device dies with the old output, so rebuild.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self, self.tapID != kAudioObjectUnknown else { return }
            self.stop()
            do { try self.start(.system) } catch { NSLog("Eddy: audio restart failed: \(error)") }
        }
    }

    func current() -> Levels { lock.lock(); defer { lock.unlock() }; return levels }
    var raw: (rms: Float, bands: SIMD3<Float>) { analyzer.raw }

    func start(_ source: Source) throws {
        stop()
        switch source {
        case .system: try startTap()
        case .room: startMicrophone()
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); levels = Levels(); lock.unlock()
    }

    // MARK: room mode

    private func startMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { NSLog("Eddy: microphone access denied"); return }
            DispatchQueue.main.async { self?.runEngine() }
        }
    }

    private func runEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        analyzer.configure(sampleRate: Float(format.sampleRate), floor: Analyzer.roomFloor)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do { try engine.start(); self.engine = engine } catch { NSLog("Eddy: microphone failed: \(error)") }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { m in
            for c in 0..<count { vDSP_vadd(channels[c], 1, m.baseAddress!, 1, m.baseAddress!, 1, vDSP_Length(frames)) }
            var scale = 1 / Float(count)
            vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(frames))
        }
        // The engine hands over ~100 ms at a time; feed it in 512-frame bites so beats stay sharp.
        for start in stride(from: 0, to: frames, by: 512) {
            let result = analyzer.push(Array(mono[start..<min(start + 512, frames)]))
            lock.lock(); levels = result; lock.unlock()
        }
    }

    // MARK: system audio

    private func startTap() throws {
        let outputUID = try defaultOutputUID()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Eddy"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eddy Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID), "create aggregate")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "tap format")
        analyzer.configure(sampleRate: Float(format.mSampleRate), floor: Analyzer.systemFloor)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "io proc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    /// Mixes every channel (interleaved or not) down to mono and feeds the analyzer.
    private func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        var lanes: Float = 0
        mono.withUnsafeMutableBufferPointer { m in
            for buf in buffers {
                guard let data = buf.mData else { continue }
                let p = data.assumingMemoryBound(to: Float.self)
                let ch = Int(buf.mNumberChannels)
                for c in 0..<ch {
                    vDSP_vadd(p + c, vDSP_Stride(ch), m.baseAddress!, 1, m.baseAddress!, 1, vDSP_Length(frames))
                    lanes += 1
                }
            }
            var scale = 1 / max(lanes, 1)
            vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(frames))
        }
        let result = analyzer.push(mono)
        lock.lock(); levels = result; lock.unlock()
    }

    private func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "default output")
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "device uid")
        return uid as String
    }

    struct AudioError: Error, CustomStringConvertible {
        let status: OSStatus, what: String
        var description: String { "\(what) failed (\(status))" }
    }
    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw AudioError(status: status, what: what) }
    }
}

/// 2048-point Hann FFT over the latest samples → band RMS with a shared auto-gain,
/// so quiet and loud tracks both land near 0..1 and bands keep their relative shape.
final class Analyzer {
    static let n = 2048
    /// Music is roughly pink (1/f), so lift mid and high until real tracks put all three bands in similar ranges.
    static let tilt: SIMD3<Float> = [1, 2, 5]
    /// (silence RMS, auto-gain floor). Below the RMS everything reads zero; the floor stops
    /// quiet hiss from being normalised up to full scale.
    static let systemFloor: (silence: Float, peak: Float) = (1e-4, 1e-3)
    static let roomFloor: (silence: Float, peak: Float) = (0.02, 20)   // built-in mic: room hiss ≈ rms 0.012, raw 2–6; speaker music ≈ rms 0.05–0.2, raw 15–90
    /// Each band rides its own auto-gain, but may be boosted at most this far past the loudest band,
    /// so a hi-hat can't squash the kick and a pure tone's leakage doesn't read as a full band.
    static let relativeFloor: Float = 0.05
    var sampleRate: Float = 48000
    private var floor = systemFloor
    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: n)
    private var head = 0
    private var peaks = SIMD3<Float>(repeating: systemFloor.peak)
    private var bassAvg: Float = 0
    private var samplesSinceBeat = 0
    private var levels = AudioInput.Levels()
    /// Raw numbers behind the last push, for `--levels` calibration.
    private(set) var raw: (rms: Float, bands: SIMD3<Float>) = (0, .zero)

    func configure(sampleRate: Float, floor: (silence: Float, peak: Float)) {
        self.sampleRate = sampleRate
        self.floor = floor
        peaks = SIMD3(repeating: floor.peak)
    }

    func push(_ samples: [Float]) -> AudioInput.Levels {
        for s in samples { ring[head] = s; head = (head + 1) % Self.n }
        samplesSinceBeat += samples.count
        var frame = Array(ring[head...] + ring[..<head])
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.n))
        raw.rms = rms
        if rms < floor.silence {              // silence: fall to zero instead of amplifying noise
            levels.bass = 0; levels.mid = 0; levels.high = 0
            return levels
        }
        vDSP.multiply(frame, window, result: &frame)

        let half = Self.n / 2
        var real = [Float](repeating: 0, count: half), imag = real, outR = real, outI = real, mags = real
        frame.withUnsafeBufferPointer { fp in
            real.withUnsafeMutableBufferPointer { rp in imag.withUnsafeMutableBufferPointer { ip in
                var input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &input, 1, vDSP_Length(half))
                }
                outR.withUnsafeMutableBufferPointer { orp in outI.withUnsafeMutableBufferPointer { oip in
                    var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                    fft.forward(input: input, output: &output)
                    vDSP.squareMagnitudes(output, result: &mags)
                }}
            }}
        }

        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo * Float(Self.n) / sampleRate))
            let b = min(half - 1, Int(hi * Float(Self.n) / sampleRate))
            return sqrt(vDSP.sum(mags[a...b]) / Float(b - a + 1))
        }
        let bands = SIMD3<Float>(band(20, 150), band(150, 2000), band(2000, 8000)) * Self.tilt
        raw.bands = bands
        let loudest = max(peaks.max() * 0.998, bands.max(), floor.peak)
        peaks = pointwiseMax(pointwiseMax(peaks * 0.998, bands), SIMD3(repeating: max(floor.peak, loudest * Self.relativeFloor)))
        let level = bands / peaks
        levels.bass = level.x
        levels.mid = level.y
        levels.high = level.z

        bassAvg += (levels.bass - bassAvg) * 0.08
        if levels.bass > bassAvg * 1.4 + 0.08, Float(samplesSinceBeat) > sampleRate * 0.2 {
            levels.beats += 1
            samplesSinceBeat = 0
        }
        return levels
    }

    /// `Eddy --selftest`: a 60 Hz tone must land in bass, a 4 kHz tone in high.
    static func selfTest() {
        func run(_ hz: Float) -> AudioInput.Levels {
            let a = Analyzer()
            var out = AudioInput.Levels()
            for chunk in 0..<8 {
                out = a.push((0..<512).map { 0.5 * sin(2 * .pi * hz * Float(chunk * 512 + $0) / 48000) })
            }
            return out
        }
        let low = run(60), high = run(4000)
        precondition(low.bass > low.mid * 3 && low.bass > low.high * 3, "60 Hz should land in bass: \(low)")
        precondition(high.high > high.bass * 3 && high.high > high.mid * 3, "4 kHz should land in high: \(high)")
        print("selftest ok\n  60Hz → \(low)\n  4kHz → \(high)")
    }
}
