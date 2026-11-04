// Spike: print raw values for every M1 data source on this machine.
// Run: swiftc -o /tmp/m1 Tools/spikes/m1-sources/main.swift && /tmp/m1
import Darwin
import Foundation
import IOKit

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

print("== sysctl: CPU topology")
print("hw.nperflevels", sysctlInt("hw.nperflevels") ?? -1)
for level in 0..<(sysctlInt("hw.nperflevels") ?? 0) {
    var buf = [CChar](repeating: 0, count: 64)
    var size = buf.count
    sysctlbyname("hw.perflevel\(level).name", &buf, &size, nil, 0)
    let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    print("perflevel\(level)", name, "logical", sysctlInt("hw.perflevel\(level).logicalcpu") ?? -1)
}

print("== host_processor_info")
var count: natural_t = 0
var info: processor_info_array_t?
var infoCount: mach_msg_type_number_t = 0
let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
print("result", result, "cpus", count)
if let info {
    for cpu in 0..<Int(count) {
        let base = cpu * Int(CPU_STATE_MAX)
        print("cpu\(cpu) user", info[base + Int(CPU_STATE_USER)], "sys", info[base + Int(CPU_STATE_SYSTEM)],
              "idle", info[base + Int(CPU_STATE_IDLE)], "nice", info[base + Int(CPU_STATE_NICE)])
    }
}

print("== host_statistics64 VM")
var vm = vm_statistics64()
var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
_ = withUnsafeMutablePointer(to: &vm) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
    }
}
print("pagesize", vm_kernel_page_size, "free", vm.free_count, "active", vm.active_count, "inactive", vm.inactive_count,
      "wired", vm.wire_count, "compressor", vm.compressor_page_count, "internal", vm.internal_page_count,
      "purgeable", vm.purgeable_count, "external", vm.external_page_count)
print("hw.memsize", sysctlInt("hw.memsize") ?? -1)
var swap = xsw_usage()
var swapSize = MemoryLayout<xsw_usage>.size
sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
print("swap total", swap.xsu_total, "used", swap.xsu_used)
var level: Int32 = 0
var levelSize = MemoryLayout<Int32>.size
sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0)
print("memorystatus_level", level)

print("== IOBlockStorageDriver")
var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
while case let service = IOIteratorNext(iterator), service != 0 {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
    let dict = props?.takeRetainedValue() as? [String: Any] ?? [:]
    print("driver stats:", dict["Statistics"] ?? "none")
    IOObjectRelease(service)
}
IOObjectRelease(iterator)

print("== AppleSmartBattery (keys and non-identifying values)")
let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
print("service", battery)
if battery != 0 {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(battery, &props, kCFAllocatorDefault, 0)
    let dict = props?.takeRetainedValue() as? [String: Any] ?? [:]
    let wanted = ["AppleRawCurrentCapacity", "AppleRawMaxCapacity", "CurrentCapacity", "MaxCapacity", "DesignCapacity",
                  "NominalChargeCapacity", "CycleCount", "Temperature", "Voltage", "Amperage", "InstantAmperage",
                  "IsCharging", "ExternalConnected", "FullyCharged", "TimeRemaining", "AvgTimeToEmpty", "AvgTimeToFull"]
    print("all keys:", dict.keys.sorted().joined(separator: " "))
    for key in wanted { print(key, "=", dict[key] ?? "MISSING") }
    IOObjectRelease(battery)
}

print("== getifaddrs AF_LINK")
var addrs: UnsafeMutablePointer<ifaddrs>?
getifaddrs(&addrs)
var cursor = addrs
while let entry = cursor {
    if entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let raw = entry.pointee.ifa_data {
        let data = raw.assumingMemoryBound(to: if_data.self).pointee
        if data.ifi_ibytes + data.ifi_obytes > 0 {
            print(String(cString: entry.pointee.ifa_name), "in", data.ifi_ibytes, "out", data.ifi_obytes,
                  "type", data.ifi_type, "up", entry.pointee.ifa_flags & UInt32(IFF_UP) != 0)
        }
    }
    cursor = entry.pointee.ifa_next
}
freeifaddrs(addrs)

print("== proc_pid_rusage (top by lifetime CPU)")
let bytes = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(bytes) * 2)
let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
var readable = 0, denied = 0
var rows: [(String, UInt64, UInt64, UInt64)] = []
for pid in pids.prefix(Int(n)) where pid > 0 {
    var usage = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    if rc != 0 { denied += 1; continue }
    readable += 1
    var name = [CChar](repeating: 0, count: 256)
    proc_name(pid, &name, 256)
    rows.append((String(cString: name), usage.ri_user_time + usage.ri_system_time, usage.ri_phys_footprint, usage.ri_energy_nj))
}
print("pids", n, "readable", readable, "denied", denied)
var tb = mach_timebase_info()
mach_timebase_info(&tb)
print("timebase", tb.numer, "/", tb.denom)
for row in rows.sorted(by: { $0.1 > $1.1 }).prefix(5) { print(row) }

print("== volume")
let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
print("total", values?.volumeTotalCapacity ?? -1, "important", values?.volumeAvailableCapacityForImportantUsage ?? -1, "avail", values?.volumeAvailableCapacity ?? -1)
