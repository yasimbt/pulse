import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Uses Carbon's hot-key API, which, unlike monitoring all key
/// presses, needs no Accessibility permission: macOS delivers only this one combination.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// ⌃⌥⌘R by default. Returns nil if another app already holds the combination.
    init?(
        keyCode: UInt32 = UInt32(kVK_ANSI_R),
        modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
        action: @escaping @MainActor () -> Void
    ) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Carbon delivers hot keys on the main thread's event loop.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        // "PLSE": an identifier for Pulse's hot keys.
        let identifier = EventHotKeyID(signature: OSType(0x504C_5345), id: 1)
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard installed == noErr, registered == noErr else { return nil }
    }

    /// Runs on the main actor, like everything else that touches the hot key.
    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// How the shortcut is shown in the interface.
    static let title = "⌃⌥⌘R"
}
