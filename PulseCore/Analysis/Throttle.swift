import Foundation

/// Detects thermal throttling: a busy cluster held well below its maximum frequency while the chip
/// is hot. Calibrated on the M5 MacBook Air under a sustained CPU and GPU load; see
/// docs/m4-findings.md.
public enum Throttle {
    /// A cluster counts when at least this share of its time is spent running.
    static let busyShare = 0.5
    /// All-core load runs below the single-core maximum without throttling (3140 of 4464 MHz on
    /// the M5), so only a drop below this share of the maximum counts.
    static let slowShare = 0.6
    /// The chip's hottest sensor at or above this, or macOS reporting "fair" or worse.
    static let hotCelsius = 80.0

    public struct Cluster: Sendable, Equatable {
        public let activeFraction: Double
        public let frequencyHz: Double
        public let maxFrequencyHz: Double

        public init(activeFraction: Double, frequencyHz: Double, maxFrequencyHz: Double) {
            self.activeFraction = activeFraction
            self.frequencyHz = frequencyHz
            self.maxFrequencyHz = maxFrequencyHz
        }
    }

    /// Whether one second looks throttled.
    public static func isThrottled(clusters: [Cluster], chipCelsius: Double?, state: ThermalState?) -> Bool {
        let hot = (chipCelsius ?? 0) >= hotCelsius || (state ?? .nominal) >= .fair
        let slow = clusters.contains { cluster in
            cluster.maxFrequencyHz > 0 && cluster.activeFraction >= busyShare && cluster.frequencyHz < slowShare * cluster.maxFrequencyHz
        }
        return hot && slow
    }

    /// Whether a snapshot looks throttled. Needs the Power panel's detail: frequencies and
    /// temperatures. Without them, nothing counts as throttled.
    public static func isThrottled(_ snapshot: Snapshot) -> Bool {
        let clusters = (snapshot.power?.clusters ?? []).compactMap { cluster -> Cluster? in
            guard let active = cluster.activeFraction, let frequency = cluster.frequencyHz, let maximum = cluster.maxFrequencyHz else {
                return nil
            }
            return Cluster(activeFraction: active, frequencyHz: frequency, maxFrequencyHz: maximum)
        }
        return isThrottled(clusters: clusters, chipCelsius: snapshot.thermal?.reading("chipHottest")?.celsius, state: snapshot.thermal?.state)
    }

    /// Turns per-second flags into periods: a period starts after `startAfter` throttled seconds in
    /// a row and ends after `endAfter` normal ones, so brief dips don't split it. A period still
    /// open at the end runs to the last flag.
    public static func periods(
        _ flags: [(time: Date, throttled: Bool)],
        startAfter: Int = 3,
        endAfter: Int = 10
    ) -> [ClosedRange<Date>] {
        var periods: [ClosedRange<Date>] = []
        var openedAt: Date?
        var lastThrottled: Date?
        var streak: [Date] = []
        for flag in flags {
            if flag.throttled { lastThrottled = flag.time }
            // A streak counts seconds that disagree with the current state.
            let disagrees = (openedAt == nil) == flag.throttled
            streak = disagrees ? streak + [flag.time] : []
            if openedAt == nil, streak.count >= startAfter {
                openedAt = streak.first
                streak = []
            } else if let start = openedAt, streak.count >= endAfter {
                periods.append(start...(lastThrottled ?? start))
                openedAt = nil
                streak = []
            }
        }
        if let start = openedAt { periods.append(start...(lastThrottled ?? start)) }
        return periods
    }
}
