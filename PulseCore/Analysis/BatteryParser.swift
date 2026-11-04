import Foundation

/// Parses `AppleSmartBattery` IORegistry properties.
///
/// On Apple Silicon, top-level `CurrentCapacity` and `MaxCapacity` are percentages, and the
/// mAh values live under `BatteryData`. See docs/m1-findings.md.
public enum BatteryParser {
    private static let unknownTime = 65535

    public static func parse(_ properties: [String: Any]) -> BatterySample? {
        guard let current = int(properties["CurrentCapacity"]),
              let maximum = int(properties["MaxCapacity"]), maximum > 0 else {
            return nil
        }
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        return BatterySample(
            chargeFraction: min(1, max(0, Double(current) / Double(maximum))),
            isCharging: bool(properties["IsCharging"]),
            isExternalPowerConnected: bool(properties["ExternalConnected"]),
            isFullyCharged: bool(properties["FullyCharged"]),
            cycleCount: int(properties["CycleCount"]),
            voltageVolts: int(properties["Voltage"]).map { Double($0) / 1000 },
            currentAmps: int(properties["Amperage"]).map { Double($0) / 1000 },
            healthFraction: health(data: data),
            temperatureCelsius: int(properties["Temperature"]).map { Double($0) / 100 },
            timeRemainingSeconds: timeRemaining(properties)
        )
    }

    private static func health(data: [String: Any]) -> Double? {
        guard let design = int(data["DesignCapacity"]), design > 0,
              let present = int(data["AppleRawMaxCapacity"]) ?? int(data["FullChargeCapacity"]) else {
            return nil
        }
        return Double(present) / Double(design)
    }

    private static func timeRemaining(_ properties: [String: Any]) -> Double? {
        guard let minutes = int(properties["TimeRemaining"]), minutes > 0, minutes != unknownTime else {
            return nil
        }
        return Double(minutes) * 60
    }

    /// Goes through `Int64` so that a current stored as a wrapped unsigned value reads as negative.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }
}
