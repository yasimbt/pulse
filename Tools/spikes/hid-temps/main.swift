// Spike: list thermal sensors through IOHIDEventSystemClient (private) and print their readings.
// Approach as in mactop and exelban/stats: match services on the Apple vendor usage page
// (0xff00) with usage 5 (temperature sensor), then copy a temperature event (type 15) from each.
// Run: swiftc -O -o build/spikes/hidtemps Tools/spikes/hid-temps/main.swift && build/spikes/hidtemps [rounds] [gap]
import Darwin
import Foundation

typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
typealias ClientSetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
typealias ClientCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
typealias ServiceCopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
typealias ServiceCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
typealias EventGetFloat = @convention(c) (AnyObject, Int32) -> Double

let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
func fn<T>(_ name: String, _: T.Type) -> T {
    guard let symbol = dlsym(iokit, name) else { fatalError("missing \(name)") }
    return unsafeBitCast(symbol, to: T.self)
}
let create = fn("IOHIDEventSystemClientCreate", ClientCreate.self)
let setMatching = fn("IOHIDEventSystemClientSetMatching", ClientSetMatching.self)
let copyServices = fn("IOHIDEventSystemClientCopyServices", ClientCopyServices.self)
let copyProperty = fn("IOHIDServiceClientCopyProperty", ServiceCopyProperty.self)
let copyEvent = fn("IOHIDServiceClientCopyEvent", ServiceCopyEvent.self)
let getFloat = fn("IOHIDEventGetFloatValue", EventGetFloat.self)

let temperatureEvent: Int64 = 15
let temperatureField = Int32(15 << 16)

guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { fatalError("client create failed") }
_ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
print("\(services.count) temperature services")

func name(_ service: AnyObject) -> String {
    copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
}
func read(_ service: AnyObject) -> Double? {
    guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
    return getFloat(event, temperatureField)
}

let names = services.map(name)
let rounds = Int(CommandLine.arguments.dropFirst().first ?? "1") ?? 1
let gap = Double(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1
var cpuNanoseconds: UInt64 = 0
var last: [Double?] = []
for round in 0..<rounds {
    if round > 0 { Thread.sleep(forTimeInterval: gap) }
    let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    last = services.map(read)
    cpuNanoseconds += clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start
}
for (sensor, value) in zip(names, last).sorted(by: { $0.0 < $1.0 }) {
    print(String(format: "  %-32@ %@", sensor as NSString, value.map { String(format: "%6.2f °C", $0) } ?? "   n/a"))
}
print(String(format: "CPU per full read of %d sensors: %.3f ms", services.count, Double(cpuNanoseconds) / Double(rounds) / 1e6))
