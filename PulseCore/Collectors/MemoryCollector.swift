import Darwin

public actor MemoryCollector: Collector {
    public nonisolated let id = MetricID.memory
    private let totalBytes: UInt64
    private let pageSize = UInt64(getpagesize())

    public init() {
        totalBytes = UInt64(SystemInfo.int64("hw.memsize") ?? 0)
    }

    public func sample() throws -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw CollectorError.unavailable("host_statistics64 returned \(status)")
        }

        let pages = MemoryCalculations.PageCounts(
            internal: UInt64(stats.internal_page_count),
            purgeable: UInt64(stats.purgeable_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count)
        )
        let breakdown = MemoryCalculations.breakdown(pages: pages, pageSize: pageSize)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        return MemorySample(
            totalBytes: totalBytes,
            usedBytes: breakdown.app + breakdown.wired + breakdown.compressed,
            appBytes: breakdown.app,
            wiredBytes: breakdown.wired,
            compressedBytes: breakdown.compressed,
            swapTotalBytes: swap.xsu_total,
            swapUsedBytes: swap.xsu_used,
            pressure: SystemInfo.int32("kern.memorystatus_vm_pressure_level").flatMap { MemorySample.Pressure(rawValue: Int($0)) }
        )
    }
}
