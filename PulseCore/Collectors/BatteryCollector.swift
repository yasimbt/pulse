import Foundation
import IOKit

/// Throws on Macs with no battery, so the module stays hidden on desktops.
public actor BatteryCollector: Collector {
    public nonisolated let id = MetricID.battery
    /// The registry only updates periodically, and its property set is large.
    private static let refreshInterval: Duration = .seconds(10)

    private let clock = ContinuousClock()
    private var cached: (sample: BatterySample, time: ContinuousClock.Instant)?

    public init() {}

    public func sample() throws -> BatterySample {
        let now = clock.now
        if let cached, now - cached.time < Self.refreshInterval {
            return cached.sample
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            throw CollectorError.unavailable("no AppleSmartBattery service")
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let sample = BatteryParser.parse(dictionary) else {
            throw CollectorError.unavailable("AppleSmartBattery properties unreadable")
        }
        cached = (sample, now)
        return sample
    }
}
