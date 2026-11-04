/// Raw per-core scheduler ticks from `host_processor_info`.
public struct CPUTicks: Sendable, Equatable, Codable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPUCalculations {
    /// Counters are 32-bit, so differences use wrapping subtraction.
    public static func sample(previous: [CPUTicks], current: [CPUTicks], clusterNames: [String]) -> CPUSample {
        var sumUser = 0.0, sumSystem = 0.0, sumTotal = 0.0
        var cores: [CoreLoad] = []
        var clusterOrder: [String] = []
        var clusterUsage: [String: (sum: Double, count: Int)] = [:]

        for (index, now) in current.enumerated() {
            let before = index < previous.count ? previous[index] : now
            let user = Double((now.user &- before.user) &+ (now.nice &- before.nice))
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let total = user + system + idle
            let usage = total > 0 ? (user + system) / total : 0

            sumUser += user
            sumSystem += system
            sumTotal += total

            let name = index < clusterNames.count ? clusterNames[index] : "CPU"
            cores.append(CoreLoad(index: index, clusterName: name, usage: usage))
            if clusterUsage[name] == nil { clusterOrder.append(name) }
            let entry = clusterUsage[name] ?? (0, 0)
            clusterUsage[name] = (entry.sum + usage, entry.count + 1)
        }

        let clusters = clusterOrder.map { name -> ClusterLoad in
            let entry = clusterUsage[name] ?? (0, 1)
            return ClusterLoad(name: name, coreCount: entry.count, usage: entry.sum / Double(entry.count))
        }
        return CPUSample(
            user: sumTotal > 0 ? sumUser / sumTotal : 0,
            system: sumTotal > 0 ? sumSystem / sumTotal : 0,
            cores: cores,
            clusters: clusters
        )
    }

    /// Names each logical CPU from its IORegistry `cluster-type` and the sysctl performance levels.
    ///
    /// `hw.perflevel0` is the fastest level, and logical CPUs are numbered slowest first, so
    /// groups are matched against the levels in reverse. On the M5, `P` cores are named "Super".
    public static func clusterNames(clusterTypes: [String], levels: [(name: String, count: Int)]) -> [String] {
        var groups: [(type: String, count: Int)] = []
        for type in clusterTypes {
            if let last = groups.last, last.type == type {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((type, 1))
            }
        }

        var unused = Array(levels.reversed())
        var names: [String] = []
        for group in groups {
            let name: String
            if let match = unused.firstIndex(where: { $0.count == group.count }) {
                name = unused.remove(at: match).name
            } else {
                name = group.type
            }
            names.append(contentsOf: repeatElement(name, count: group.count))
        }
        return names
    }

    /// Fallback when IORegistry has no CPU nodes: assume slowest level first.
    public static func clusterNames(levels: [(name: String, count: Int)]) -> [String] {
        levels.reversed().flatMap { repeatElement($0.name, count: $0.count) }
    }
}
