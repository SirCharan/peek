import AppKit
import SwiftUI
import PeekCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var contextMenu: NSMenu?
    // let the panel sit over the menu bar / notch band
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .rightMouseDown, let m = contextMenu, let v = contentView {
            NSMenu.popUpContextMenu(m, with: e, for: v)
            return
        }
        super.sendEvent(e)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var panel: NotchPanel!
    var host: NSHostingView<Root>!
    var screen: NSScreen = NSScreen.screens[0]
    var geo = Geo(notchW: 100, notchH: 24)
    var collapseTask: Task<Void, Never>?
    var lastPublish = 0.0
    var choice: ScreenChoice { ScreenChoice(UserDefaults.standard.string(forKey: "screen")) }

    func applicationDidFinishLaunching(_ n: Notification) {
        computeGeo()
        host = NSHostingView(rootView: Root(store: store, geo: geo))
        host.safeAreaRegions = []
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = host
        buildMenu()
        reframe()
        panel.orderFrontRegardless()
        track()
        panel.acceptsMouseMovedEvents = true
        startPointer()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.relayout()
            }
        }
    }

    static func uuid(_ s: NSScreen) -> String? {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
    static func inside(_ p: CGPoint, _ r: NSRect) -> Bool { p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY }

    /// Picks the screen for the saved choice (a missing display falls back to the notch screen, the saved choice stays) and sizes the bar from it.
    func computeGeo() {
        let all = NSScreen.screens
        guard !all.isEmpty else { return }
        let m = NSEvent.mouseLocation
        let cands = all.map { ScreenCandidate(uuid: AppDelegate.uuid($0), hasNotch: $0.safeAreaInsets.top > 0, containsMouse: AppDelegate.inside(m, $0.frame)) }
        screen = all[ScreenResolver.index(choice, in: cands) ?? 0]
        let b = BarGeometry(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top, auxLeft: screen.auxiliaryTopLeftArea?.width,
                            auxRight: screen.auxiliaryTopRightArea?.width, menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
        geo = Geo(notchW: b.width, notchH: b.height)
    }

    func relayout() {
        computeGeo()
        host.rootView = Root(store: store, geo: geo)
        reframe()
    }

    /// One global + one local mouseMoved monitor (no Accessibility permission needed); the pointer feeds the presence machine.
    func startPointer() {
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in MainActor.assumeIsolated { self.moved() } }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in MainActor.assumeIsolated { self.moved() }; return e }
    }

    func moved() {
        let m = NSEvent.mouseLocation, p = store.presence
        if choice == .mouse, p != .home, !AppDelegate.inside(m, screen.frame) { relayout() }
        let f = screen.frame
        let hit: Bool
        if p == .home { hit = AppDelegate.inside(m, panel.frame) }
        else if m.y < f.maxY - geo.notchH - 1 { hit = false }  // far below the bar: nothing to compute
        else {
            let w = p == .hidden ? geo.notchW : Layout.bandW(geo)
            hit = AppDelegate.inside(m, NSRect(x: f.midX - w / 2, y: f.maxY - geo.notchH, width: w, height: geo.notchH))
        }
        store.setInside(hit)
        let now = ProcessInfo.processInfo.systemUptime
        if store.presence != .hidden, now - lastPublish >= 1.0 / 30 { lastPublish = now; store.pointer.location = m }
    }

    func reframe() {
        let r = Layout.rect(expanded: store.open, g: geo, jobs: store.shown, replying: store.replying, diff: store.diffOpen, footer: store.expanded && store.usage != nil)
        let f = NSRect(x: screen.frame.midX + r.dx - r.size.width / 2, y: screen.frame.maxY - r.size.height,
                       width: r.size.width, height: r.size.height)
        panel.ignoresMouseEvents = store.presence == .hidden
        collapseTask?.cancel()
        if !store.open && f.height < panel.frame.height {
            // ponytail: shrink after the spring so content isn't clipped mid-animation
            collapseTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { panel.setFrame(f, display: true) }
            }
        } else {
            panel.setFrame(f, display: true)
        }
    }

    func track() {
        withObservationTracking {
            _ = store.open; _ = store.expanded; _ = store.replying; _ = store.jobs; _ = store.alert; _ = store.diffOpen; _ = store.usage; _ = store.presence
        } onChange: {
            Task { @MainActor in self.reframe(); self.track() }
        }
    }

    func buildMenu() {
        let m = NSMenu()
        let sub = NSMenu(title: "Screen")
        sub.delegate = self
        let item = NSMenuItem(title: "Screen", action: nil, keyEquivalent: "")
        item.submenu = sub
        m.addItem(item)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        panel.contextMenu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = choice
        func add(_ title: String, _ c: ScreenChoice, on: Bool) {
            let i = NSMenuItem(title: title, action: #selector(pickScreen(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.stored; i.state = on ? .on : .off
            menu.addItem(i)
        }
        add("Notch display", .notch, on: cur == .notch)
        add("Main display", .main, on: cur == .main)
        add("Follow mouse", .mouse, on: cur == .mouse)
        menu.addItem(.separator())
        for s in NSScreen.screens {
            guard let u = AppDelegate.uuid(s) else { continue }
            add(s.localizedName, .display(u), on: cur == .display(u))
        }
    }

    @objc func pickScreen(_ i: NSMenuItem) {
        UserDefaults.standard.set(i.representedObject as? String ?? "notch", forKey: "screen")
        relayout()
    }
}

let app = NSApplication.shared
if let dir = ProcessInfo.processInfo.environment["PEEK_RENDER_MASCOT"] { MainActor.assumeIsolated { renderMascot(to: dir) }; exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
