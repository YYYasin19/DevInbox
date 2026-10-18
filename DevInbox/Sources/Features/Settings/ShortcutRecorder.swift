import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows a shortcut and records a new one: click, then press the keys. ⌫ turns it off, Esc keeps the
/// current one.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    /// While true, the app doesn't react to the current shortcut, so it can be recorded again.
    @Binding var isRecording: Bool

    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { stop() } else { start() }
        } label: {
            Text(isRecording ? "Type shortcut…" : shortcut?.displayString ?? "None")
                .foregroundStyle(isRecording ? Color.accentColor : .primary)
                .frame(minWidth: 96)
        }
        .tooltip(isRecording
            ? "Press the new shortcut, with ⌘, ⌥ or ⌃. ⌫ turns it off, Esc keeps the current one."
            : "Click, then press a new shortcut")
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            stop()
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            shortcut = nil
            stop()
        default:
            // Keys without ⌘, ⌥ or ⌃ would take over typing everywhere.
            guard let recorded = Shortcut(event: event) else {
                NSSound.beep()
                return
            }
            shortcut = recorded
            stop()
        }
    }
}
