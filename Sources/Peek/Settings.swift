import AppKit
import SwiftUI
import PeekCore

/// Plain system Form in a regular window. Keys: `screen` (same as the right-click menu), `muted`, `hotkey.<action>`.
struct SettingsView: View {
    static let size = CGSize(width: 580, height: 700)
    static let version = "0.1.0"
    let onScreenChange: () -> Void
    var flat = false  // ImageRenderer cannot draw the grouped (table-backed) Form
    let center = HotkeyCenter.shared
    @State private var screen = ScreenChoice(UserDefaults.standard.string(forKey: "screen")).stored

    private var displays: [(String, String)] {
        let live = NSScreen.screens.compactMap { s in AppDelegate.uuid(s).map { ($0, s.localizedName) } }
        let base = [("notch", "Notch display"), ("main", "Main display"), ("mouse", "Follow mouse")]
        let known = Set((base + live).map(\.0))
        return base + live + (known.contains(screen) ? [] : [(screen, "Disconnected display")])
    }

    private var launchAgent: String {
        FileManager.default.fileExists(atPath: PeekPaths.home + "/Library/LaunchAgents/com.sircharan.peek.plist")
            ? "On (LaunchAgent from install.sh)" : "Off (run install.sh to turn it on)"
    }

    var body: some View {
        if flat { form.formStyle(.columns).padding(24).frame(width: Self.size.width, height: Self.size.height, alignment: .top) }
        else { form.formStyle(.grouped).frame(width: Self.size.width, height: Self.size.height) }
    }

    private var form: some View {
        let muted = Sounds.muted
        return Form {
            Section("General") {
                Picker("Show Peek on", selection: $screen) {
                    ForEach(displays, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: screen) { _, v in UserDefaults.standard.set(v, forKey: "screen"); onScreenChange() }
                LabeledContent("Launch at login", value: launchAgent)
                Text("Peek runs as a plain binary, so macOS has no login-item switch for it. install.sh sets up the LaunchAgent; this row only reports it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Sounds") {
                Toggle("Mute all sounds", isOn: Binding(get: { muted }, set: { Sounds.muted = $0 }))
                ForEach([("needs", "Needs you"), ("done", "Done"), ("fail", "Failed")], id: \.0) { e, label in
                    LabeledContent(label) {
                        HStack(spacing: 8) {
                            Text(Sounds.customURL(e).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Built-in")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button { Sounds.play(e, preview: true) } label: { Image(systemName: "play.fill") }
                                .accessibilityLabel("Play the \(label) sound")
                        }
                    }
                }
                Button("Open sounds folder") {
                    try? FileManager.default.createDirectory(atPath: PeekPaths.sounds, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: PeekPaths.sounds))
                }
                Text("Put needs, done or fail (wav, aiff, caf, m4a, mp3) there to replace a sound.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { ShortcutRow(action: $0, center: center) }
            }
            Section("About") {
                LabeledContent("Peek", value: "Version \(Self.version)")
                Text("Not affiliated with Anthropic.").foregroundStyle(.secondary)
                Text("Some code is adapted from Coucou (MIT, \u{00A9} 2026 Louis Raill\u{00E9}). See THIRD_PARTY_NOTICES.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Click-to-record field. Recording uses a local key monitor (this window only) and pauses the global hotkeys meanwhile.
struct ShortcutRow: View {
    let action: HotkeyAction
    let center: HotkeyCenter
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let s = center.bindings[action] ?? center.binding(action)
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(action.title) {
                HStack(spacing: 8) {
                    Button(recording ? "Press keys\u{2026}" : (s?.display ?? "Not set")) { recording ? cancel() : start() }
                        .accessibilityLabel("Shortcut for \(action.title): \(s?.display ?? "not set")")
                        .accessibilityHint("Click, then press the new keys. Escape cancels.")
                    Button { center.set(action, nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).disabled(s == nil)
                        .accessibilityLabel("Clear shortcut for \(action.title)")
                }
            }
            if let f = center.failures[action] { Text(f).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { if recording { cancel() } }
    }

    private func start() {
        center.unregisterAll()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = e.keyCode, f = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue & Shortcut.mask
            MainActor.assumeIsolated { capture(code, f) }
            return nil
        }
    }
    private func capture(_ code: UInt16, _ f: UInt) {
        if code == 53 { cancel(); return }  // Escape
        guard f & (Shortcut.ctrl | Shortcut.opt | Shortcut.cmd) != 0 else { NSSound.beep(); return }
        finish()
        center.set(action, Shortcut(keyCode: code, flags: f))
    }
    private func finish() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil; recording = false }
    private func cancel() { finish(); center.registerAll() }
}

@MainActor enum SettingsWindow {
    private static var window: NSWindow?
    /// Works for an `.accessory` app: activates it first so the window comes to the front.
    static func show(onScreenChange: @escaping () -> Void) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(onScreenChange: onScreenChange)))
            w.title = "Peek Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// `PEEK_RENDER_SETTINGS=<dir>`: settings.png at 2x, for review without a screen.
@MainActor func renderSettings(to dir: String) {
    let view = SettingsView(onScreenChange: {}, flat: true).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
    let r = ImageRenderer(content: view); r.scale = 2
    guard let img = r.cgImage, let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { print("render failed"); return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings.png"))
}
