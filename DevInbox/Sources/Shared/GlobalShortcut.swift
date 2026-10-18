import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as recorded in Settings.
nonisolated struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags`, device-independent.
    var modifiers: UInt
    /// The key as the keyboard layout labels it, like "K".
    var key: String

    static let openPanel = Shortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue, key: "K")

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// "⇧⌘K", in the order macOS menus use.
    var displayString: String {
        let flags = modifierFlags
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    /// The key pressed in `event`, or nil without ⌘, ⌥ or ⌃: a global shortcut would swallow typing.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let name = Self.keyNames[Int(event.keyCode)]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers.rawValue, key: name)
    }

    init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Keys whose characters don't name them.
    private static let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// A system-wide shortcut, registered with Carbon's hot key API: unlike a global key monitor, it needs
/// no Accessibility permission, and it keeps the key from the app in front.
final class GlobalShortcut {
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replaces the registered shortcut; nil turns it off. Returns false when another app already
    /// registered the same one. Registered exclusively, so no other app can take it meanwhile.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let shortcut else { return true }
        let flags = shortcut.modifierFlags
        let modifiers = (flags.contains(.command) ? cmdKey : 0) | (flags.contains(.shift) ? shiftKey : 0)
            | (flags.contains(.option) ? optionKey : 0) | (flags.contains(.control) ? controlKey : 0)
        let id = EventHotKeyID(signature: "DvIn".utf8.reduce(0) { $0 << 8 | OSType($1) }, id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard status == noErr else {
            Log.error(.app, "Couldn't register the shortcut \(shortcut.displayString): \(status)")
            hotKey = nil
            return false
        }
        Log.info(.app, "Registered the shortcut \(shortcut.displayString)")
        return true
    }
}
