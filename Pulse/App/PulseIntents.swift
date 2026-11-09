import AppIntents
import Foundation
import PulseCore

/// Lets App Intents reach the running app. Intents run inside Pulse's own process, so they read
/// the same snapshot and session recorder as the menu bar.
@MainActor
enum IntentBridge {
    static weak var controller: AppController?
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noHistory
    case notRecording

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Pulse isn't running yet."
        case .noHistory: "Sessions aren't available: Pulse couldn't open its history file."
        case .notRecording: "No session is recording."
        }
    }
}

/// "Get Current Metrics": a sentence such as "CPU 12%, memory 76%, power 3.2 W, chip 45 °C."
struct GetCurrentMetricsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Metrics"
    static let description = IntentDescription("Returns this Mac's CPU, memory, power, temperature, battery and disk readings from Pulse.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let controller = IntentBridge.controller else { throw IntentFailure.notRunning }
        let text = controller.currentSummary()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Pulse Session"
    static let description = IntentDescription("Starts recording a workload session in Pulse, as the Record button does.")

    @Parameter(title: "Name", description: "Leave empty to name it after the start time.")
    var name: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = IntentBridge.controller else { throw IntentFailure.notRunning }
        guard await controller.startRecording(name: name) else { throw IntentFailure.noHistory }
        return .result(dialog: "Recording a session.")
    }
}

struct StopSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Pulse Session"
    static let description = IntentDescription("Stops the current session and returns its summary.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let controller = IntentBridge.controller else { throw IntentFailure.notRunning }
        guard let session = await controller.stopRecording() else { throw IntentFailure.notRecording }
        let text = MetricsExport.summary(session)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Makes the actions appear in Shortcuts and Spotlight without setup.
struct PulseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetCurrentMetricsIntent(), phrases: ["Get metrics from \(.applicationName)"],
                    shortTitle: "Current Metrics", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: StartSessionIntent(), phrases: ["Start a \(.applicationName) session"],
                    shortTitle: "Start Session", systemImageName: "record.circle")
        AppShortcut(intent: StopSessionIntent(), phrases: ["Stop the \(.applicationName) session"],
                    shortTitle: "Stop Session", systemImageName: "stop.circle")
    }
}
