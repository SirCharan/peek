import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: NotchPanel!
    var host: NSHostingView<Root>!
    var screen: NSScreen = NSScreen.screens[0]
    var geo = Geo(notchW: 100, notchH: 24)
    var collapseTask: Task<Void, Never>?

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
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.computeGeo()
                self.host.rootView = Root(store: self.store, geo: self.geo)
                self.reframe()
            }
        }
    }

    func computeGeo() {
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            screen = s
            let l = s.auxiliaryTopLeftArea?.width ?? 0, r = s.auxiliaryTopRightArea?.width ?? 0
            geo = Geo(notchW: s.frame.width - l - r, notchH: s.safeAreaInsets.top)
        } else {
            screen = NSScreen.main ?? NSScreen.screens[0]
            geo = Geo(notchW: 100, notchH: 24)  // no notch: 24pt pill at top-centre
        }
    }

    func reframe() {
        let r = Layout.rect(expanded: store.open, g: geo, jobs: store.shown)
        let f = NSRect(x: screen.frame.midX + r.dx - r.size.width / 2, y: screen.frame.maxY - r.size.height,
                       width: r.size.width, height: r.size.height)
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
            _ = store.open; _ = store.expanded; _ = store.jobs; _ = store.alert
        } onChange: {
            Task { @MainActor in self.reframe(); self.track() }
        }
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        panel.contextMenu = m
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
