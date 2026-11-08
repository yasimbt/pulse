import Foundation

/// One named temperature sensor, as reported by the HID event system.
public struct SensorValue: Sendable, Equatable, Codable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// Which sensors make up each displayed temperature, per Mac model. Loaded from
/// `TemperatureSensors.json`, so a new chip needs a data change rather than a code change.
public struct SensorMap: Sendable, Decodable {
    /// How a rule combines its sensors.
    public enum Reduce: String, Sendable, Decodable {
        case max
        case mean
    }

    public struct Rule: Sendable, Decodable, Equatable {
        public let id: String
        public let title: String
        public let prefix: String
        public let reduce: Reduce
    }

    let fallback: [Rule]
    let models: [String: [Rule]]

    private enum CodingKeys: String, CodingKey {
        case fallback = "default"
        case models
    }

    public func rules(forModel model: String) -> [Rule] {
        models[model] ?? fallback
    }

    public static func bundled() throws -> SensorMap {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "TemperatureSensors", withExtension: "json") else {
            throw CollectorError.unavailable("TemperatureSensors.json missing from the framework")
        }
        return try JSONDecoder().decode(SensorMap.self, from: Data(contentsOf: url))
    }

    private final class BundleToken {}
}

public enum TemperatureCalculations {
    /// Readings outside this range are faulty, such as the M5's "tdev1", which sits at -22 °C.
    static let plausible = 0.0...130.0

    public static func readings(_ sensors: [SensorValue], rules: [SensorMap.Rule]) -> [TemperatureReading] {
        rules.compactMap { rule in
            let values = sensors
                .filter { $0.name.hasPrefix(rule.prefix) && plausible.contains($0.celsius) }
                .map(\.celsius)
            guard let highest = values.max() else { return nil }
            let value = switch rule.reduce {
            case .max: highest
            case .mean: values.reduce(0, +) / Double(values.count)
            }
            return TemperatureReading(id: rule.id, title: rule.title, celsius: value)
        }
    }

    /// Whether a sensor feeds any rule, so that others need not be read.
    public static func isUsed(_ name: String, by rules: [SensorMap.Rule]) -> Bool {
        rules.contains { name.hasPrefix($0.prefix) }
    }
}
