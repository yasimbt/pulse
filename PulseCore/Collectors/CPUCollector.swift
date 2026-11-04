import Foundation
import Darwin
import IOKit

public actor CPUCollector: Collector {
    public nonisolated let id = MetricID.cpu
    private let clusterNames: [String]
    private var previous: [CPUTicks] = []

    public init() {
        clusterNames = Self.discoverClusterNames()
    }

    public func sample() throws -> CPUSample {
        let current = try Self.readTicks()
        defer { previous = current }
        return CPUCalculations.sample(previous: previous, current: current, clusterNames: clusterNames)
    }

    static func readTicks() throws -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else {
            throw CollectorError.unavailable("host_processor_info returned \(status)")
        }
        defer {
            vm_deallocate(machTaskSelf(), vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    private static func discoverClusterNames() -> [String] {
        let levels = SystemInfo.performanceLevels()
        let types = clusterTypesFromRegistry()
        return types.isEmpty
            ? CPUCalculations.clusterNames(levels: levels)
            : CPUCalculations.clusterNames(clusterTypes: types, levels: levels)
    }

    /// Reads `cluster-type` from the `cpuN` device-tree nodes, ordered by N.
    private static func clusterTypesFromRegistry() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [(index: Int, type: String)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuffer)
            let name = String(cString: nameBuffer)
            guard name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)),
                  let property = IORegistryEntryCreateCFProperty(service, "cluster-type" as CFString, kCFAllocatorDefault, 0),
                  let data = property.takeRetainedValue() as? Data else {
                continue
            }
            found.append((index, String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)))
        }
        return found.sorted { $0.index < $1.index }.map(\.type)
    }
}
