import Darwin

/// Only processes owned by the current user are readable without privileges.
/// See docs/m1-findings.md.
public actor ProcessCollector: Collector {
    public nonisolated let id = MetricID.processes
    private let clock = ContinuousClock()
    private var previous: [Int32: ProcessCounters] = [:]
    private var previousTime: ContinuousClock.Instant?

    public init() {}

    public func sample() throws -> ProcessTable {
        let now = clock.now
        let (counters, unreadable) = try readAll()
        let seconds = previousTime.map { Rates.seconds(now - $0) } ?? 0
        let usages = ProcessCalculations.usages(previous: previous, current: counters, seconds: seconds)
        previous = Dictionary(counters.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        previousTime = now
        return ProcessCalculations.table(usages: usages, unreadableCount: unreadable)
    }

    private func readAll() throws -> ([ProcessCounters], Int) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw CollectorError.unavailable("proc_listallpids failed") }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { throw CollectorError.unavailable("proc_listallpids failed") }

        let timebase = SystemInfo.timebase
        var counters: [ProcessCounters] = []
        var unreadable = 0
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let usage = readRusage(pid: pid) else {
                unreadable += 1
                continue
            }
            counters.append(ProcessCounters(
                pid: pid,
                name: previous[pid]?.name ?? Self.name(of: pid),
                cpuNanoseconds: ProcessCalculations.nanoseconds(
                    ticks: usage.ri_user_time + usage.ri_system_time,
                    numer: timebase.numer,
                    denom: timebase.denom
                ),
                footprintBytes: usage.ri_phys_footprint,
                diskReadBytes: usage.ri_diskio_bytesread,
                diskWriteBytes: usage.ri_diskio_byteswritten
            ))
        }
        return (counters, unreadable)
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "pid \(pid)"
    }
}
