import Foundation
import os
import PulseCore
import UserNotifications

/// Turns alert events into macOS notifications. Asks for permission when alerts are first turned
/// on, not at launch.
@MainActor
final class AlertNotifier {
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "alerts")

    private var engine = AlertEngine()
    private var askedForPermission = false

    func check(_ snapshot: Snapshot, settings: AlertSettings) {
        guard !settings.enabled.isEmpty else { return }
        for event in engine.evaluate(snapshot, settings: settings) {
            post(event)
        }
    }

    /// Called when the alert settings change, so that the permission prompt appears right after
    /// the person turns an alert on.
    func settingsChanged(_ settings: AlertSettings) {
        guard !settings.enabled.isEmpty, !askedForPermission else { return }
        askedForPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("notification permission failed: \(String(describing: error), privacy: .public)")
            } else if !granted {
                Self.logger.info("notifications not allowed; alerts won't show")
            }
        }
    }

    private func post(_ event: AlertEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        // One identifier per kind, so that a new alert replaces an older one of the same kind.
        let request = UNNotificationRequest(identifier: "pulse.alert.\(event.kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.logger.error("notification failed: \(String(describing: error), privacy: .public)") }
        }
    }
}
