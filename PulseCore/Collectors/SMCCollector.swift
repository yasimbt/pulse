import Foundation

/// Whole-system power and fan speeds from the SMC. A fanless Mac, such as the MacBook Air, has no
/// fan keys at all, so its fan list is empty. See docs/m2-findings.md.
public actor SMCCollector: Collector {
    public nonisolated let id = MetricID.smc

    private var connection: SMCConnection?
    private var fanCount: Int?

    public init() {}

    public func sample() throws -> SMCSample {
        let connection = try self.connection ?? SMCConnection()
        self.connection = connection
        // Fixed for the machine, so read once.
        let fanCount = self.fanCount ?? Int(connection.read("FNum")?.number ?? 0)
        self.fanCount = fanCount
        let fans = (0..<fanCount).compactMap { index -> FanReading? in
            guard let speed = connection.read("F\(index)Ac")?.number else { return nil }
            return FanReading(
                index: index,
                rpm: speed,
                minimumRPM: connection.read("F\(index)Mn")?.number,
                maximumRPM: connection.read("F\(index)Mx")?.number
            )
        }
        return SMCSample(systemWatts: connection.read("PSTR")?.number, fans: fans)
    }
}
