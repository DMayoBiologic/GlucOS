import AppKit
import Carbon.HIToolbox
import Combine
import os

/// The optional "open the log window from anywhere" shortcut (Settings → Logging, off by default;
/// docs/KeyboardLogging.md). A Carbon hot key: it needs no Accessibility permission, and macOS
/// hands GlucOS only that one key combination, never other keystrokes.
///
/// Pressing it opens the quick-log window on a new entry, or brings it to the front if it's
/// already open (an entry being typed is kept).
@MainActor
final class GlobalLogShortcut: ObservableObject {
    static let shared = GlobalLogShortcut()

    /// Why the shortcut isn't working, for Settings: another app already has it, say. Nil when
    /// it's registered or turned off.
    @Published private(set) var failure: String?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observation: AnyCancellable?
    /// Held while Settings records a new combination, so pressing the current one there records
    /// it rather than opening the log window.
    private var paused = false

    nonisolated private static let signature: OSType = 0x474C_4F47   // 'GLOG'
    nonisolated private static let log = Logger(subsystem: "au.com.declanmayo.glucos", category: "hotkey")

    func start(settings: AppSettings = .shared) {
        guard observation == nil else { return }
        installHandler()
        observation = settings.$globalLogShortcutEnabled
            .combineLatest(settings.$globalLogShortcut)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, key in
                MainActor.assumeIsolated { self?.apply(enabled ? key : nil) }
            }
    }

    /// Stops the shortcut while Settings is recording one, and restores it after.
    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        apply(AppSettings.shared.activeGlobalLogShortcut)
    }

    private func apply(_ key: LogHotKey?) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let key, !paused else { failure = nil; return }
        guard key.problem == nil else { failure = key.problem; return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(key.keyCode), Self.carbonModifiers(key.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKey = ref
            failure = nil
        } else {
            failure = status == OSStatus(eventHotKeyExistsErr)
                ? "Another app already uses \(key.display). Pick another shortcut."
                : "macOS didn't accept \(key.display) (error \(status)). Pick another shortcut."
            Self.log.error("RegisterEventHotKey failed: \(status)")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalLogShortcut.signature else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in GlobalLogShortcut.pressed() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Opens the quick-log window. The menu bar label opens it (it can reach SwiftUI's openWindow);
    /// the window's target is already a new entry unless it's open on something, which is kept.
    private static func pressed() {
        // Closed with its close button, the window can keep an old target (a low being treated).
        let isOpen = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(LogWindow.id + "-") == true }
            || NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == LogWindow.id }
        if !isOpen { LogWindowRequest.shared.open(.new, from: .keyboardShortcut) }
        NotificationCenter.default.post(name: .glucosOpenLogWindow, object: nil)
        NSApp.activate()
    }

    private static func carbonModifiers(_ m: LogHotKey.Modifiers) -> UInt32 {
        var out: UInt32 = 0
        if m.contains(.command) { out |= UInt32(cmdKey) }
        if m.contains(.option) { out |= UInt32(optionKey) }
        if m.contains(.control) { out |= UInt32(controlKey) }
        if m.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }
}

extension LogHotKey {
    /// The combination an AppKit key-down event typed, or nil for a key with no modifiers.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        guard !m.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: m, key: Self.name(for: event))
    }

    private static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "Return"
        case kVK_Delete: return "Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // The key as typed without ⌥ or ⇧ turning it into another character (⌥L is "¬", ⇧3 "#").
        let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").uppercased()
        if let c = chars.first, !c.isWhitespace, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return String(c)
        }
        return "Key \(event.keyCode)"
    }
}
