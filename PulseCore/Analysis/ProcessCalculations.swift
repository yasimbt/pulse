public struct ProcessCounters: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// User plus system time, in nanoseconds.
    public let cpuNanoseconds: UInt64
    public let footprintBytes: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64

    public init(pid: Int32, name: String, cpuNanoseconds: UInt64, footprintBytes: UInt64, diskReadBytes: UInt64, diskWriteBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuNanoseconds = cpuNanoseconds
        self.footprintBytes = footprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

public enum ProcessCalculations {
    /// `proc_pid_rusage` times are Mach ticks on Apple Silicon (24 MHz, timebase 125/3), not
    /// nanoseconds. Goes through `Double` because `ticks * 125` could overflow for old processes.
    public static func nanoseconds(ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0 else { return ticks }
        return UInt64(Double(ticks) * Double(numer) / Double(denom))
    }

    /// A pid with no earlier reading has no measurable rate yet, so it is skipped for this sample.
    public static func usages(previous: [Int32: ProcessCounters], current: [ProcessCounters], seconds: Double) -> [ProcessUsage] {
        guard seconds > 0 else { return [] }
        return current.compactMap { now in
            guard let old = previous[now.pid] else { return nil }
            let cpu = Rates.perSecond(current: now.cpuNanoseconds, previous: old.cpuNanoseconds, seconds: seconds) / 1e9
            return ProcessUsage(
                pid: now.pid,
                name: now.name,
                cpuCores: cpu,
                footprintBytes: now.footprintBytes,
                diskReadBytesPerSecond: Rates.perSecond(current: now.diskReadBytes, previous: old.diskReadBytes, seconds: seconds),
                diskWriteBytesPerSecond: Rates.perSecond(current: now.diskWriteBytes, previous: old.diskWriteBytes, seconds: seconds)
            )
        }
    }

    public static func table(usages: [ProcessUsage], unreadableCount: Int, limit: Int = 5) -> ProcessTable {
        func top(_ value: (ProcessUsage) -> Double) -> [ProcessUsage] {
            Array(usages.sorted { value($0) > value($1) }.prefix(limit))
        }
        return ProcessTable(
            byCPU: top(\.cpuCores),
            byMemory: top { Double($0.footprintBytes) },
            byDisk: top { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond },
            unreadableCount: unreadableCount
        )
    }
}

public struct NettopRow: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
}

public enum NettopParser {
    /// Parses `nettop -P -L 1 -x -J bytes_in,bytes_out -n`, whose rows look like
    /// `apsd.393,1575609,1206301,`. Process names can contain dots, so the pid follows the last one.
    public static func parse(_ text: String) -> [NettopRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let received = UInt64(fields[1]),
                  let sent = UInt64(fields[2]) else {
                return nil
            }
            return NettopRow(pid: pid, name: String(fields[0][..<dot]), receivedBytes: received, sentBytes: sent)
        }
    }

    public static func usages(previous: [NettopRow], current: [NettopRow], seconds: Double, limit: Int = 5) -> [NetworkProcessUsage] {
        let before = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = current.compactMap { now -> NetworkProcessUsage? in
            guard let old = before[now.pid] else { return nil }
            return NetworkProcessUsage(
                pid: now.pid,
                name: now.name,
                downBytesPerSecond: Rates.perSecond(current: now.receivedBytes, previous: old.receivedBytes, seconds: seconds),
                upBytesPerSecond: Rates.perSecond(current: now.sentBytes, previous: old.sentBytes, seconds: seconds)
            )
        }
        return Array(rows.sorted {
            $0.downBytesPerSecond + $0.upBytesPerSecond > $1.downBytesPerSecond + $1.upBytesPerSecond
        }.prefix(limit))
    }
}
