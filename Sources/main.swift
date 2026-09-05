import AppKit

if CommandLine.arguments.contains("--selftest") {
    Analyzer.selfTest()
    exit(0)
}

// `Eddy --levels`: start the system-audio tap and print what it hears for 5 s.
if CommandLine.arguments.contains("--levels") {
    let audio = SystemAudio()
    do { try audio.start() } catch { print("tap failed: \(error)"); exit(1) }
    for _ in 0..<25 { Thread.sleep(forTimeInterval: 0.2); print(audio.current()) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
