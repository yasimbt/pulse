// Spike: resolve questions raised by m1-sources.
// Run: swiftc -o /tmp/m1d Tools/spikes/m1-details/main.swift && /tmp/m1d
import Darwin
import Foundation
import IOKit

setbuf(stdout, nil)

// Q1: which logical CPU belongs to which cluster?
print("== IODeviceTree cpu nodes")
var iter: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPlatformDevice"), &iter)
while case let svc = IOIteratorNext(iter), svc != 0 {
    defer { IOObjectRelease(svc) }
    var cname = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(svc, &cname)
    let name = String(cString: cname)
    guard name.hasPrefix("cpu"), name.dropFirst(3).allSatisfy(\.isNumber) else { continue }
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
    let dict = props?.takeRetainedValue() as? [String: Any] ?? [:]
    func text(_ key: String) -> String {
        guard let data = dict[key] as? Data else { return "\(dict[key] ?? "-")" }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
    func num(_ key: String) -> UInt32 {
        guard let data = dict[key] as? Data, data.count >= 4 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
    print(name, "logical-cpu-id", num("logical-cpu-id"), "cluster-type", text("cluster-type"),
          "cluster-id", num("logical-cluster-id"), "compatible", text("compatible"))
}
IOObjectRelease(iter)

// Q2: are ri_user_time values nanoseconds or Mach ticks? Burn ~1 s of CPU and compare.
print("== rusage time unit")
func selfCPU() -> UInt64 {
    var usage = rusage_info_v6()
    _ = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    return usage.ri_user_time + usage.ri_system_time
}
let start = selfCPU()
let begin = Date()
var sink = 0.0
while Date().timeIntervalSince(begin) < 1 { sink += sin(sink + 1) }
print("delta for ~1.0 s burn:", selfCPU() - start, "sink", sink != 0)

// Q3: NET_RT_IFLIST2 64-bit counters vs. getifaddrs.
print("== NET_RT_IFLIST2")
var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
var len = 0
sysctl(&mib, 6, nil, &len, nil, 0)
var buf = [UInt8](repeating: 0, count: len)
sysctl(&mib, 6, &buf, &len, nil, 0)
buf.withUnsafeBytes { raw in
    var offset = 0
    while offset < len {
        // Every routing message starts with: u16 length, u8 version, u8 type. Some are shorter than if_msghdr.
        let msgLen = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        let msgType = raw[offset + 3]
        if Int32(msgType) == RTM_IFINFO2 {
            let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if_indextoname(UInt32(msg.ifm_index), &name)
            if msg.ifm_data.ifi_ibytes + msg.ifm_data.ifi_obytes > 0 {
                print(String(cString: name), "in", msg.ifm_data.ifi_ibytes, "out", msg.ifm_data.ifi_obytes,
                      "type", msg.ifm_data.ifi_type, "up", msg.ifm_flags & IFF_UP != 0)
            }
        }
        offset += Int(msgLen)
    }
}

// Q4: where do battery health values live? Numbers only, so no serials are printed.
print("== AppleSmartBattery")
let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
if battery != 0 {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(battery, &props, kCFAllocatorDefault, 0)
    let dict = props?.takeRetainedValue() as? [String: Any] ?? [:]
    print(dict.keys.sorted().joined(separator: " "))
    for (key, value) in dict.sorted(by: { $0.key < $1.key }) where value is NSNumber { print(" ", key, "=", value) }
    if let data = dict["BatteryData"] as? [String: Any] {
        print("BatteryData:")
        for (key, value) in data.sorted(by: { $0.key < $1.key }) where value is NSNumber { print(" ", key, "=", value) }
    }
    IOObjectRelease(battery)
}

// Q5: which processes are unreadable?
print("== denied pids")
let count = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(count) * 2)
let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
var denied: [String] = []
for pid in pids.prefix(Int(got)) where pid >= 0 {
    var usage = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    if rc != 0 {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, 256)
        denied.append("\(pid):\(String(cString: name))")
    }
}
print(denied.count, "denied; sample:", denied.prefix(12).joined(separator: " "))
