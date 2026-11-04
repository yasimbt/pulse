import Foundation

public enum SeriesID: String, CaseIterable, Sendable {
    case cpuTotal, memoryUsed, diskRead, diskWrite, networkDown, networkUp, batteryCharge
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
        func add(_ id: SeriesID, _ value: Double?) {
            guard let value else { return }
            series[id, default: RingBuffer(capacity: Self.capacity)].append(TimedValue(time: snapshot.timestamp, value: value))
        }
        add(.cpuTotal, snapshot.cpu?.total)
        add(.memoryUsed, snapshot.memory?.usedFraction)
        add(.diskRead, snapshot.disk?.readBytesPerSecond)
        add(.diskWrite, snapshot.disk?.writeBytesPerSecond)
        add(.networkDown, snapshot.network?.downBytesPerSecond)
        add(.networkUp, snapshot.network?.upBytesPerSecond)
        add(.batteryCharge, snapshot.battery?.chargeFraction)
    }

    /// Points inside the ten-minute window ending at `now`, oldest first.
    public func points(_ id: SeriesID, now: Date) -> [TimedValue] {
        let cutoff = now.addingTimeInterval(-Self.window)
        return (series[id]?.elements ?? []).filter { $0.time >= cutoff }
    }

    /// The newest `count` raw values, oldest first. Cheap enough to call every sample.
    public func recentValues(_ id: SeriesID, count: Int) -> [Double] {
        (series[id]?.suffix(count) ?? []).map(\.value)
    }
}
