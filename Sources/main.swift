import AppKit

if CommandLine.arguments.contains("--selftest") {
    Analyzer.selfTest()
    exit(0)
}

// `Eddy --levels [--mic]`: start the system-audio tap (or the microphone) and print what it hears for 8 s.
if CommandLine.arguments.contains("--levels") {
    let audio = AudioInput()
    let source: Source = CommandLine.arguments.contains("--mic") ? .room : .system
    do { try audio.start(source) } catch { print("\(source.rawValue) failed: \(error)"); exit(1) }
    for _ in 0..<40 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))   // the mic permission callback needs the run loop
        let r = audio.raw
        print(audio.current(), String(format: "rms %.5f  raw %.4f %.4f %.4f", r.rms, r.bands.x, r.bands.y, r.bands.z))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
