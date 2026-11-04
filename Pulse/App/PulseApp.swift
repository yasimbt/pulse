import PulseCore
import SwiftUI

@main
struct PulseApp: App {
    var body: some Scene {
        MenuBarExtra(PulseInfo.appName, systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 12) {
                Text(PulseInfo.appName)
                    .font(.headline)
                Button("Quit \(PulseInfo.appName)") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding()
            .frame(width: 200, alignment: .leading)
        }
        .menuBarExtraStyle(.window)
    }
}
