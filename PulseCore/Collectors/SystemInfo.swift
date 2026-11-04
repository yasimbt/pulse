@preconcurrency import Darwin
import Foundation

/// `mach_task_self()` reads a C global, which Swift 6 cannot prove is safe. It never changes.
func machTaskSelf() -> mach_port_t {
    mach_task_self_
}

enum SystemInfo {
    static func int64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Fastest level first, as `hw.perflevel0` is the highest-performance tier.
    static func performanceLevels() -> [(name: String, count: Int)] {
        let levelCount = int32("hw.nperflevels") ?? 0
        return (0..<levelCount).compactMap { level in
            guard let count = int32("hw.perflevel\(level).logicalcpu") else { return nil }
            return (string("hw.perflevel\(level).name") ?? "Level \(level)", Int(count))
        }
    }

    static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()
}

/// Reads `proc_pid_rusage`. Returns nil for processes owned by other users.
func readRusage(pid: pid_t) -> rusage_info_v6? {
    var usage = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return status == 0 ? usage : nil
}
