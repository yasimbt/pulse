import Foundation

/// A recorded metric. Raw values double as the history database's column names, so a case must
/// never be renamed; adding one needs a migration that adds its column.
public enum SeriesID: String, CaseIterable, Sendable {
    case cpuTotal, memoryUsed, diskRead, diskWrite, networkDown, networkUp, batteryCharge
    case powerCPU, powerGPU, powerTotal

    /// The value in SI units, or nil when the snapshot doesn't have it.
    public func value(in snapshot: Snapshot) -> Double? {
        switch self {
        case .cpuTotal: snapshot.cpu?.total
        case .memoryUsed: snapshot.memory?.usedFraction
        case .diskRead: snapshot.disk?.readBytesPerSecond
        case .diskWrite: snapshot.disk?.writeBytesPerSecond
        case .networkDown: snapshot.network?.downBytesPerSecond
        case .networkUp: snapshot.network?.upBytesPerSecond
        case .batteryCharge: snapshot.battery?.chargeFraction
        case .powerCPU: snapshot.power?.cpuWatts
        case .powerGPU: snapshot.power?.gpuWatts
        case .powerTotal: snapshot.power.flatMap { $0.cpuWatts == nil ? nil : $0.totalWatts }
        }
    }
}

public struct TimedValue: Sendable, Equatable {
    public let time: Date
    public let value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

/// The in-memory history behind sparklines and panel charts.
public struct MetricHistory: Sendable {
    public static let window: TimeInterval = 600
    /// Ten minutes at the fastest sample rate, 0.5 s.
    public static let capacity = 1200

    private var series: [SeriesID: RingBuffer<TimedValue>] = [:]

    public init() {}

    public mutating func record(_ snapshot: Snapshot) {
        for id in SeriesID.allCases {
            guard let value = id.value(in: snapshot) else { continue }
            series[id, default: RingBuffer(capacity: Self.capacity)].append(TimedValue(time: snapshot.timestamp, value: value))
        }
    }

    /// Points inside the ten-minute window ending at `now`, oldest first.
    public func points(_ id: SeriesID, now: Date) -> [TimedValue] {
        let cutoff = now.addingTimeInterval(-Self.window)
        return (series[id]?.elements ?? []).filter { $0.time >= cutoff }
    }

    /// Reduces points to at most `maxCount`, keeping each bucket's highest value so that a short
    /// spike stays visible on the chart.
    public static func downsampled(_ points: [TimedValue], maxCount: Int) -> [TimedValue] {
        guard maxCount > 0, points.count > maxCount else { return points }
        let bucketSize = Double(points.count) / Double(maxCount)
        return (0..<maxCount).compactMap { bucket in
            let range = Int(Double(bucket) * bucketSize)..<Int(Double(bucket + 1) * bucketSize)
            return points[range].max { $0.value < $1.value }
        }
    }

    /// The newest `count` raw values, oldest first. Cheap enough to call every sample.
    public func recentValues(_ id: SeriesID, count: Int) -> [Double] {
        (series[id]?.suffix(count) ?? []).map(\.value)
    }
}
