import Foundation

/// Sessions as files to share or analyse elsewhere.
public enum SessionExport {
    /// Everything: name, summary, every sample and process totals. Times are ISO 8601.
    public static func json(_ session: Session) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }

    static let csvHeader = [
        "time", "cpu_usage", "gpu_usage", "cpu_watts", "gpu_watts", "system_watts",
        "efficiency_mhz", "performance_mhz", "chip_celsius", "thermal_state", "throttled"
    ]

    /// One row per second, for a spreadsheet. Empty cells mean not measured.
    public static func csv(_ session: Session) -> String {
        let iso = ISO8601DateFormatter()
        func cell(_ value: Double?, _ scale: Double = 1, digits: Int = 3) -> String {
            value.map { String(format: "%.\(digits)f", $0 * scale) } ?? ""
        }
        let rows = session.samples.map { sample in
            [
                iso.string(from: sample.time), cell(sample.cpuUsage), cell(sample.gpuUsage), cell(sample.cpuWatts), cell(sample.gpuWatts),
                cell(sample.systemWatts), cell(sample.efficiencyHz, 1e-6, digits: 0), cell(sample.performanceHz, 1e-6, digits: 0),
                cell(sample.chipCelsius, digits: 1), sample.thermalState.map { "\($0)" } ?? "", sample.throttled ? "1" : "0"
            ].joined(separator: ",")
        }
        return ([csvHeader.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
    }
}
