import AppKit
import MetalKit
import ServiceManagement

/// One per screen: borderless, sits at the desktop layer (above the wallpaper, below the
/// icons), ignores the mouse, and stops rendering whenever it can't be seen.
final class WallpaperWindow: NSWindow {
    let view: MTKView
    let renderer: FluidRenderer
    var userPaused = false { didSet { updatePause() } }

    init(screen: NSScreen, audio: AudioInput?) {
        view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: MTLCreateSystemDefaultDevice())
        renderer = FluidRenderer(view: view, audio: audio)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        contentView = view
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: self)
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    @objc private func occlusionChanged() { updatePause() }
    private func updatePause() { view.isPaused = userPaused || !occlusionState.contains(.visible) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let audio = AudioInput()
    private var windows: [WallpaperWindow] = []
    private var statusItem: NSStatusItem!
    private var paused = false { didSet { windows.forEach { $0.userPaused = paused } } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startAudio()
        rebuildWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = waveIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startAudio() {
        do { try audio.start(Settings.shared.source) } catch { NSLog("Eddy: audio unavailable: \(error)") }
    }

    @objc private func rebuildWindows() {
        let screens = NSScreen.screens
        if windows.map(\.frame) == screens.map(\.frame) { return }
        windows.forEach { $0.close() }
        windows = screens.map { WallpaperWindow(screen: $0, audio: audio) }
        windows.forEach { $0.userPaused = paused }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
        }
        let s = Settings.shared
        add(paused ? "Resume" : "Pause", #selector(togglePause))
        add("React to Audio", #selector(toggleReactive), on: s.reactive)
        menu.addItem(picker("Palette", Palette.allCases.map(\.rawValue), current: s.palette.rawValue, #selector(pickPalette)))
        menu.addItem(picker("Intensity", Intensity.allCases.map(\.rawValue), current: s.intensity.rawValue, #selector(pickIntensity)))
        menu.addItem(picker("Listen to", Source.allCases.map(\.rawValue), current: s.source.rawValue, #selector(pickSource)))
        menu.addItem(.separator())
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Eddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Hand-drawn: the `water.waves` SF Symbol renders as a stray glyph on the macOS 27 beta.
    private func waveIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            for y in [4.0, 9.0, 14.0] {
                let p = NSBezierPath()
                p.lineWidth = 1.6
                p.lineCapStyle = .round
                p.move(to: NSPoint(x: 2, y: y))
                p.curve(to: NSPoint(x: 9, y: y), controlPoint1: NSPoint(x: 4, y: y + 3), controlPoint2: NSPoint(x: 7, y: y - 3))
                p.curve(to: NSPoint(x: 16, y: y), controlPoint1: NSPoint(x: 11, y: y + 3), controlPoint2: NSPoint(x: 14, y: y - 3))
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Eddy"
        return img
    }

    /// A submenu of radio-style choices; the chosen title rides along as `representedObject`.
    private func picker(_ title: String, _ options: [String], current: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for option in options {
            let i = sub.addItem(withTitle: option, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = option
            i.state = option == current ? .on : .off
        }
        item.submenu = sub
        return item
    }

    @objc private func togglePause() { paused.toggle() }
    @objc private func toggleReactive() { Settings.shared.reactive.toggle() }
    @objc private func pickPalette(_ sender: NSMenuItem) {
        Settings.shared.palette = Palette(rawValue: sender.representedObject as! String) ?? .neon
    }
    @objc private func pickSource(_ sender: NSMenuItem) {
        Settings.shared.source = Source(rawValue: sender.representedObject as! String) ?? .system
        startAudio()
    }
    @objc private func pickIntensity(_ sender: NSMenuItem) {
        Settings.shared.intensity = Intensity(rawValue: sender.representedObject as! String) ?? .normal
    }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { try svc.status == .enabled ? svc.unregister() : svc.register() }
        catch { NSLog("Eddy: launch at login: \(error)") }
    }
}
