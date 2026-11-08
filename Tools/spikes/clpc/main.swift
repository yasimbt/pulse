// Spike: read AppleCLPC's hidden aggregate energy counters (CPU, GPU, ANE) through IOReport.
//
// These channels aren't listed by IOReportCopyAllChannels, so they're described by hand. The
// channel layout and the M5 (AppleT8142CLPC) counter keys come from macmon 0.9 (MIT,
// github.com/vladkens/macmon, src/clpc.rs and src/sources.rs), extracted there from macOS 27.0.
//
// Run: swiftc -O -o build/spikes/clpc Tools/spikes/clpc/main.swift && build/spikes/clpc [seconds] [gap]
import Darwin
import Foundation
import IOKit

typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
typealias CreateSubscription = @convention(c) (
    UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
) -> OpaquePointer?
typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64

let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
func fn<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let copyChannels = fn("IOReportCopyChannelsInGroup", CopyChannels.self)
let createSubscription = fn("IOReportCreateSubscription", CreateSubscription.self)
let createSamples = fn("IOReportCreateSamples", CreateSamples.self)
let createDelta = fn("IOReportCreateSamplesDelta", CreateDelta.self)
let getName = fn("IOReportChannelGetChannelName", GetString.self)
let getUnit = fn("IOReportChannelGetUnitLabel", GetString.self)
let getInteger = fn("IOReportSimpleGetIntegerValue", GetInteger.self)

// M5 keys from macmon; macOS 27 report indices: CPU 16, GPU 25, ANE 24.
let counters: [(name: String, id: Int64)] = [
    ("CPU Energy", (16 << 32) | 0x4370_8744),
    ("GPU Energy", (25 << 32) | 0x6A01_0933),
    ("ANE", (24 << 32) | 0xBC5E_FDF0),
]

// The AppleCLPC service's registry entry ID identifies the driver.
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
guard service != 0 else { fatalError("no AppleCLPC service") }
var driverID: UInt64 = 0
IORegistryEntryGetRegistryEntryID(service, &driverID)
let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? String ?? "?"
IOObjectRelease(service)
print("AppleCLPC driver 0x\(String(driverID, radix: 16)), bundle \(bundle), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

// Simple integer, power category, one element; unit nJ.
let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
let unit: Int64 = (3 << 56) | (118 << 32)
let channels: [NSDictionary] = counters.map { counter in
    NSMutableDictionary(dictionary: [
        "DriverID": NSNumber(value: Int64(bitPattern: driverID)),
        "DriverName": "AppleCLPC",
        "IOReportGroupName": "CLPC",
        "IOReportSubGroupName": "Energy Counters",
        "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
        "LegendChannel": [NSNumber(value: counter.id), NSNumber(value: channelType), counter.name],
    ])
}
guard let template = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSDictionary? else {
    fatalError("no Energy Model template")
}
let request = NSMutableDictionary(dictionary: template)
request["IOReportChannels"] = channels
var subscribed: Unmanaged<CFMutableDictionary>?
guard let subscription = createSubscription(nil, request as CFMutableDictionary, &subscribed, 0, nil),
      let subscribedChannels = subscribed?.takeRetainedValue() else { fatalError("subscription failed") }
let subscribedCount = ((subscribedChannels as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? 0
print("subscribed \(subscribedCount) of \(channels.count) channels")

let seconds = Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let gap = Double(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1
var previous = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
// Raw values: if these are totals since boot, they give energy since boot directly.
for item in (previous as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? [] {
    let channel = item as CFDictionary
    let name = getName(channel).map { $0.takeUnretainedValue() as String } ?? "?"
    let value = getInteger(channel, 0)
    print(String(format: "raw %@: %lld nJ = %.2f Wh", name, value, Double(value) / 1e9 / 3600))
}
var previousTime = Date()
var sampleCPU: UInt64 = 0
for _ in 0..<seconds {
    Thread.sleep(forTimeInterval: gap)
    let cpu0 = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    let current = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
    let delta = createDelta(previous, current, nil)!.takeRetainedValue() as NSDictionary
    sampleCPU += clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu0
    let now = Date()
    let elapsed = now.timeIntervalSince(previousTime)
    let parts = (delta["IOReportChannels"] as? [NSDictionary] ?? []).map { item -> String in
        let channel = item as CFDictionary
        let name = getName(channel).map { $0.takeUnretainedValue() as String } ?? "?"
        let unitLabel = getUnit(channel).map { $0.takeUnretainedValue() as String } ?? "?"
        let value = getInteger(channel, 0)
        return String(format: "%@ %.3f W (%lld %@)", name, Double(value) / 1e9 / elapsed, value, unitLabel)
    }
    print(parts.joined(separator: " | "))
    previous = current
    previousTime = now
}
print(String(format: "CPU per sample+delta: %.3f ms", Double(sampleCPU) / Double(seconds) / 1e6))
