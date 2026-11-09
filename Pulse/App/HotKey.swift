import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut. Uses Carbon's hot-key API, which, unlike monitoring all key
/// presses, needs no Accessibility permission: macOS delivers only the registered combinations.
@MainActor
final class HotKey {
    /// Pulse's shortcuts, each with its own identifier.
    enum Shortcut: UInt32 {
        case record = 1
        case hud = 2

        var keyCode: UInt32 {
            switch self {
            case .record: UInt32(kVK_ANSI_R)
            case .hud: UInt32(kVK_ANSI_H)
            }
        }

        /// How the shortcut is shown in the interface.
        var title: String {
            switch self {
            case .record: "⌃⌥⌘R"
            case .hud: "⌃⌥⌘H"
            }
        }
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let shortcut: Shortcut
    private let action: @MainActor () -> Void

    /// Control-Option-Command plus the shortcut's key. Returns nil if another app already holds it.
    init?(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) {
        self.shortcut = shortcut
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                // Every handler sees every hot key the app registered, so each checks it's its own.
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressedID
                )
                guard status == noErr, pressedID.id == hotKey.shortcut.rawValue else { return OSStatus(eventNotHandledErr) }
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
        let identifier = EventHotKeyID(signature: OSType(0x504C_5345), id: shortcut.rawValue)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let registered = RegisterEventHotKey(shortcut.keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard installed == noErr, registered == noErr else { return nil }
    }

    /// Runs on the main actor, like everything else that touches the hot key.
    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
