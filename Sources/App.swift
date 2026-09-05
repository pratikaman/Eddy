import AppKit
import MetalKit
import ServiceManagement

/// One per screen: borderless, sits at the desktop layer (above the wallpaper, below the
/// icons), ignores the mouse, and stops rendering whenever it can't be seen.
final class WallpaperWindow: NSWindow {
    let view: MTKView
    let renderer: FluidRenderer
    var userPaused = false { didSet { updatePause() } }

    init(screen: NSScreen, audio: SystemAudio?) {
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
    private let audio = SystemAudio()
    private var windows: [WallpaperWindow] = []
    private var statusItem: NSStatusItem!
    private var paused = false { didSet { windows.forEach { $0.userPaused = paused } } }
    private var reactive = true { didSet { windows.forEach { $0.renderer.reactive = reactive } } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try audio.start() } catch { NSLog("Eddy: system audio unavailable: \(error)") }
        rebuildWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildWindows),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Eddy")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func rebuildWindows() {
        let screens = NSScreen.screens
        if windows.map(\.frame) == screens.map(\.frame) { return }
        windows.forEach { $0.close() }
        windows = screens.map { WallpaperWindow(screen: $0, audio: audio) }
        windows.forEach { $0.userPaused = paused; $0.renderer.reactive = reactive }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
        }
        add(paused ? "Resume" : "Pause", #selector(togglePause))
        add("React to Audio", #selector(toggleReactive), on: reactive)
        add("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Eddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func togglePause() { paused.toggle() }
    @objc private func toggleReactive() { reactive.toggle() }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do { try svc.status == .enabled ? svc.unregister() : svc.register() }
        catch { NSLog("Eddy: launch at login: \(error)") }
    }
}
