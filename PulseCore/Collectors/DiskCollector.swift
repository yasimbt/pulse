import Foundation
import IOKit

public actor DiskCollector: Collector {
    public nonisolated let id = MetricID.disk
    private static let spaceRefreshInterval: Duration = .seconds(30)

    private let clock = ContinuousClock()
    private var previous: (read: UInt64, write: UInt64, time: ContinuousClock.Instant)?
    private var space: (total: UInt64, available: UInt64, time: ContinuousClock.Instant)?

    public init() {}

    public func sample() throws -> DiskSample {
        let now = clock.now
        let counters = Self.readIOCounters()
        let seconds = previous.map { Rates.seconds(now - $0.time) } ?? 0
        let readRate = Rates.perSecond(current: counters.read, previous: previous?.read ?? counters.read, seconds: seconds)
        let writeRate = Rates.perSecond(current: counters.write, previous: previous?.write ?? counters.write, seconds: seconds)
        previous = (counters.read, counters.write, now)

        if space == nil || now - (space?.time ?? now) >= Self.spaceRefreshInterval {
            space = try Self.readSpace(at: now)
        }
        return DiskSample(
            totalBytes: space?.total ?? 0,
            availableBytes: space?.available ?? 0,
            readBytesPerSecond: readRate,
            writeBytesPerSecond: writeRate
        )
    }

    /// Sums every block storage driver, so external drives are included.
    private static func readIOCounters() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any] else {
                continue
            }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    private static func readSpace(at time: ContinuousClock.Instant) throws -> (total: UInt64, available: UInt64, time: ContinuousClock.Instant) {
        // A fresh URL each time, because URL caches resource values.
        let values = try URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            throw CollectorError.unavailable("volume capacity not reported")
        }
        return (UInt64(total), UInt64(available), time)
    }
}
