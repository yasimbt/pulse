import Foundation
import IOKit

/// USB-C and MagSafe ports and the connected charger, from the IORegistry. Needs no root.
/// See docs/ports-findings.md.
public actor PortsCollector: Collector {
    public nonisolated let id = MetricID.ports
    /// `AppleSmartBattery`'s property set is large, and macOS updates its charger telemetry only
    /// every few tens of seconds, so it's read at most this often.
    private static let chargerInterval: Duration = .seconds(10)

    private let clock = ContinuousClock()
    private var charger: (sample: ChargerSample?, time: ContinuousClock.Instant)?

    public init() {}

    public func sample() throws -> PortsSample {
        let ports = ["AppleHPMInterfaceType10", "AppleHPMInterfaceType11"]
            .flatMap(Self.properties)
            .compactMap(PortsParser.port)
        guard !ports.isEmpty else { throw CollectorError.unavailable("no USB-C or MagSafe port services") }

        let now = clock.now
        let connectedCharger: ChargerSample?
        if let charger, now - charger.time < Self.chargerInterval {
            connectedCharger = charger.sample
        } else {
            connectedCharger = Self.properties("AppleSmartBattery").first.flatMap(PortsParser.charger)
            charger = (connectedCharger, now)
        }
        return PortsSample(ports: ports, charger: connectedCharger, chargerPort: connectedCharger.flatMap { _ in Self.chargerPort(ports) })
    }

    /// The connected port carrying power only. MagSafe carries only power; a USB-C charger shows
    /// just the CC transport, which power negotiation uses.
    static func chargerPort(_ ports: [PortSample]) -> String? {
        ports.first { $0.isConnected && ($0.type.hasPrefix("MagSafe") || $0.activeTransports == ["CC"]) }?.name
    }

    private static func properties(_ className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                result.append(dictionary)
            }
        }
        return result
    }
}
