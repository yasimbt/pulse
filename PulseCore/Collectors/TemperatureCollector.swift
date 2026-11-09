import Darwin
import Foundation

/// Temperatures from the HID event system, a private IOKit API that also serves the chip's
/// thermal sensors. Needs no root. Approach as in mactop and exelban/stats; see
/// `Tools/spikes/hid-temps` and docs/m2-findings.md.
public actor TemperatureCollector: Collector {
    public nonisolated let id = MetricID.temperature

    private var sensors: HIDTemperatureSensors?
    private var rules: [SensorMap.Rule] = []

    public init() {}

    public func sample() throws -> ThermalSample {
        let sensors = try self.sensors ?? open()
        self.sensors = sensors
        let readings = TemperatureCalculations.readings(sensors.read(), rules: rules)
        guard !readings.isEmpty else { throw CollectorError.unavailable("no known temperature sensors") }
        return ThermalSample(readings: readings, state: ThermalState(ProcessInfo.processInfo.thermalState))
    }

    private func open() throws -> HIDTemperatureSensors {
        rules = try SensorMap.bundled().rules(forModel: SystemInfo.string("hw.model") ?? "")
        let rules = rules
        // Only sensors the map uses are kept, which halves the cost of a read on the M5.
        return try HIDTemperatureSensors { TemperatureCalculations.isUsed($0, by: rules) }
    }
}

/// The HID event system's temperature services, loaded at run time. Not thread-safe: own it from
/// one actor.
final class HIDTemperatureSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ClientSetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias ServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventGetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    /// `IOHIDEventFieldBase(kIOHIDEventTypeTemperature)`.
    private static let temperatureField = Int32(15 << 16)

    private let copyEvent: ServiceCopyEvent
    private let getFloat: EventGetFloat
    /// Kept alive, since the services belong to it.
    private let client: AnyObject
    private let services: [(name: String, service: AnyObject)]

    init(keeping include: (String) -> Bool) throws {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            throw CollectorError.unavailable("IOKit could not be loaded")
        }
        func load<T>(_ symbol: String, _: T.Type) -> T? {
            dlsym(iokit, symbol).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = load("IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", ClientSetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", ClientCopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", ServiceCopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", ServiceCopyEvent.self),
              let getFloat = load("IOHIDEventGetFloatValue", EventGetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            throw CollectorError.unavailable("HID event system unavailable")
        }
        // Apple's vendor usage page, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let all = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
        services = all.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  include(name) else { return nil }
            return (name, service)
        }
        guard !services.isEmpty else { throw CollectorError.unavailable("no temperature sensors") }
        self.client = client
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    func read() -> [SensorValue] {
        services.compactMap { entry in
            guard let event = copyEvent(entry.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return SensorValue(name: entry.name, celsius: getFloat(event, Self.temperatureField))
        }
    }
}
