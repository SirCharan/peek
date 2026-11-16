// Portions adapted from Coucou (github.com/Louis-CFM/coucou, NotchBuddy/Sources/App/HotKeyCenter.swift@0d7fe58), © 2026 Louis Raillé, MIT. See THIRD_PARTY_NOTICES.md.
import AppKit
import Carbon.HIToolbox
import Observation
import PeekCore

// Carbon needs a top-level C function; events arrive on the main thread.
private nonisolated(unsafe) var gHandler: EventHandlerRef?
private nonisolated(unsafe) var gTable: [UInt32: HotkeyAction] = [:]
private nonisolated(unsafe) var gOnAction: ((HotkeyAction) -> Void)?

private func peekHotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard err == noErr, let a = gTable[id.id] else { return OSStatus(eventNotHandledErr) }
    MainActor.assumeIsolated { gOnAction?(a) }
    return noErr
}

/// Global hotkeys through Carbon `RegisterEventHotKey`: no Accessibility permission, no key monitor.
/// Bindings live in UserDefaults (`hotkey.<action>`); a failed registration is kept in `failures` for the Settings row.
@MainActor @Observable final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private(set) var bindings: [HotkeyAction: Shortcut] = [:]
    private(set) var failures: [HotkeyAction: String] = [:]
    @ObservationIgnored private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private let signature = OSType(0x5045454B)  // "PEEK"

    func binding(_ a: HotkeyAction) -> Shortcut? { a.resolve(UserDefaults.standard.string(forKey: a.defaultsKey)) }

    func start(_ onAction: @escaping (HotkeyAction) -> Void) {
        gOnAction = onAction
        if gHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), peekHotKeyHandler, 1, &spec, nil, &gHandler)
        }
        registerAll()
    }

    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs = [:]; gTable = [:]; failures = [:]; bindings = [:]
    }
    func registerAll() { unregisterAll(); for a in HotkeyAction.allCases { register(a) } }

    /// nil clears the binding.
    func set(_ a: HotkeyAction, _ s: Shortcut?) {
        UserDefaults.standard.set(s?.stored ?? "", forKey: a.defaultsKey)
        registerAll()
    }

    private func register(_ a: HotkeyAction) {
        guard let s = binding(a) else { return }
        bindings[a] = s
        let idx = UInt32(HotkeyAction.allCases.firstIndex(of: a) ?? 0)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(s.keyCode), s.carbonModifiers, EventHotKeyID(signature: signature, id: idx), GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref { refs[a] = ref; gTable[idx] = a }
        else { failures[a] = st == OSStatus(eventHotKeyExistsErr) ? "Already taken by another app or shortcut" : "Could not register (error \(st))" }
    }
}

extension Store {
    /// What each hotkey does. Allow/Deny answer only when it is unambiguous; AskUserQuestion cards are never answered here.
    func hotkey(_ a: HotkeyAction) {
        switch a {
        case .mute: Sounds.muted.toggle()
        case .toggle: toggleCard()
        case .jump:
            let j = jobs.filter(\.needsYou).min { $0.lastT < $1.lastT } ?? jobs.max { $0.lastT < $1.lastT }
            if let j { Focus.jump(j, store: self) } else { toggleCard() }
        case .allow, .deny:
            guard let j = jobs.first(where: { $0.perm != nil }), let p = j.perm else { return }
            let visible = open && shown.prefix(Layout.maxRows).contains { $0.id == j.id }
            if p.ask != nil { if !open { toggleCard() }; return }
            if visible || pendingCount == 1 { reply(j, a == .allow ? "allow" : "deny") }
            else if !open { toggleCard() }
        }
    }
}
