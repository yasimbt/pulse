import Foundation

/// A snapshot as named numbers, for `pulse-cli` and the local HTTP endpoint. SI units throughout:
/// ratios 0...1, bytes, bytes per second, watts, degrees Celsius, hertz.
public enum MetricsExport {
    /// One exported value. `labels` tell apart values of the same metric, such as `component=cpu`.
    public struct Metric: Sendable, Equatable {
        public let name: String
        public let help: String
        public let labels: [String: String]
        public let value: Double
    }

    /// Every value the snapshot has, in a stable order.
    public static func metrics(_ snapshot: Snapshot) -> [Metric] {
        var result: [Metric] = []
        func add(_ name: String, _ help: String, _ value: Double?, _ labels: [String: String] = [:]) {
            if let value, value.isFinite { result.append(Metric(name: name, help: help, labels: labels, value: value)) }
        }
        if let cpu = snapshot.cpu {
            add("pulse_cpu_usage_ratio", "Share of all CPU cores in use.", cpu.total)
            for cluster in cpu.clusters {
                add("pulse_cpu_cluster_usage_ratio", "Share of a core cluster in use.", cluster.usage, ["cluster": cluster.name])
            }
        }
        if let memory = snapshot.memory {
            add("pulse_memory_used_bytes", "Memory in use, as Activity Monitor counts it.", Double(memory.usedBytes))
            add("pulse_memory_total_bytes", "Installed memory.", Double(memory.totalBytes))
            add("pulse_swap_used_bytes", "Swap in use.", Double(memory.swapUsedBytes))
        }
        if let disk = snapshot.disk {
            add("pulse_disk_available_bytes", "Free space on the startup disk.", Double(disk.availableBytes))
            add("pulse_disk_total_bytes", "Size of the startup disk.", Double(disk.totalBytes))
            add("pulse_disk_bytes_per_second", "Disk throughput.", disk.readBytesPerSecond, ["direction": "read"])
            add("pulse_disk_bytes_per_second", "Disk throughput.", disk.writeBytesPerSecond, ["direction": "write"])
        }
        if let network = snapshot.network {
            add("pulse_network_bytes_per_second", "Network throughput, all interfaces.", network.downBytesPerSecond, ["direction": "down"])
            add("pulse_network_bytes_per_second", "Network throughput, all interfaces.", network.upBytesPerSecond, ["direction": "up"])
        }
        if let battery = snapshot.battery {
            add("pulse_battery_charge_ratio", "Battery charge.", battery.chargeFraction)
            add("pulse_battery_health_ratio", "Battery capacity against its design capacity.", battery.healthFraction)
            add("pulse_battery_cycles", "Battery charge cycles.", battery.cycleCount.map(Double.init))
        }
        if let power = snapshot.power {
            add("pulse_power_watts", "Power by component.", power.cpuWatts, ["component": "cpu"])
            add("pulse_power_watts", "Power by component.", power.gpuWatts, ["component": "gpu"])
            for cluster in power.clusters {
                add("pulse_power_watts", "Power by component.", cluster.watts, ["component": "cpu_\(cluster.kind.rawValue)"])
                add("pulse_cpu_frequency_hertz", "Average frequency while running.", cluster.frequencyHz, ["cluster": cluster.kind.rawValue])
            }
        }
        add("pulse_power_watts", "Power by component.", snapshot.smc?.systemWatts, ["component": "system"])
        for reading in snapshot.thermal?.readings ?? [] {
            add("pulse_temperature_celsius", "Temperature by sensor group.", reading.celsius, ["sensor": reading.id])
        }
        if let charger = snapshot.ports?.charger {
            add("pulse_charger_rated_watts", "What the connected charger advertises.", charger.advertisedWatts)
            add("pulse_charger_input_watts", "Measured power from the charger.", charger.inputWatts)
        }
        add("pulse_self_cpu_ratio", "The reporting process's own CPU use, in cores: Pulse, or pulse-cli.", snapshot.selfUsage?.cpuCores)
        return result
    }

    /// The Prometheus text exposition format, version 0.0.4.
    public static func prometheus(_ snapshot: Snapshot) -> String {
        var lines: [String] = []
        var described = Set<String>()
        for metric in metrics(snapshot) {
            if described.insert(metric.name).inserted {
                lines.append("# HELP \(metric.name) \(metric.help)")
                lines.append("# TYPE \(metric.name) gauge")
            }
            let labels = metric.labels.isEmpty ? "" : "{" + metric.labels.keys.sorted().map {
                "\($0)=\"\(escape(metric.labels[$0] ?? ""))\""
            }.joined(separator: ",") + "}"
            lines.append("\(metric.name)\(labels) \(number(metric.value))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Entry: Encodable {
        let value: Double
        let labels: [String: String]?
    }

    private struct Document: Encodable {
        let time: String
        let metrics: [String: [Entry]]
    }

    /// A JSON object: the time, then each metric as an array of its labelled values. Encoded with
    /// JSONEncoder, which writes the shortest form of each number (0.46, not 0.46000000000000002).
    public static func json(_ snapshot: Snapshot) throws -> Data {
        var grouped: [String: [Entry]] = [:]
        for metric in metrics(snapshot) {
            grouped[metric.name, default: []].append(Entry(value: metric.value, labels: metric.labels.isEmpty ? nil : metric.labels))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(time: ISO8601DateFormatter().string(from: snapshot.timestamp), metrics: grouped))
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Whole numbers without a fraction, others with enough digits to round-trip.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
