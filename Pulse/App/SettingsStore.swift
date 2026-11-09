import Foundation
import Observation
import os
import PulseCore

@MainActor
@Observable
final class SettingsStore {
    private static let key = "settings"
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "settings")

    var settings: PulseSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(settings)
        }
    }

    @ObservationIgnored var onChange: ((PulseSettings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults` other than standard keep previews and tests away from the real settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let text = defaults.string(forKey: Self.key),
           let saved = try? JSONDecoder().decode(PulseSettings.self, from: Data(text.utf8)) {
            settings = saved.normalized()
        } else {
            settings = .default
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
        } catch {
            Self.logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
