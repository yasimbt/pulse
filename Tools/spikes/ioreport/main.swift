// Spike: print raw IOReport energy and residency channels, and the DVFS frequency tables.
// IOReport is a private library in the dyld shared cache, loaded with dlopen. Signatures follow
// what macmon and mactop use.
// Run: swiftc -o build/spikes/ior Tools/spikes/ioreport/main.swift && build/spikes/ior [seconds | watch N | list [group]]
import Darwin
import Foundation
import IOKit

typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
typealias CreateSubscription = @convention(c) (
    UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
) -> OpaquePointer?
typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
typealias GetCount = @convention(c) (CFDictionary) -> Int32
typealias GetStateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
typealias GetResidency = @convention(c) (CFDictionary, Int32) -> Int64
typealias GetFormat = @convention(c) (CFDictionary) -> UInt8

let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
func fn<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let copyChannels = fn("IOReportCopyChannelsInGroup", CopyChannels.self)
let mergeChannels = fn("IOReportMergeChannels", MergeChannels.self)
let createSubscription = fn("IOReportCreateSubscription", CreateSubscription.self)
let createSamples = fn("IOReportCreateSamples", CreateSamples.self)
let createDelta = fn("IOReportCreateSamplesDelta", CreateDelta.self)
let getGroup = fn("IOReportChannelGetGroup", GetString.self)
let getSubGroup = fn("IOReportChannelGetSubGroup", GetString.self)
let getName = fn("IOReportChannelGetChannelName", GetString.self)
let getUnit = fn("IOReportChannelGetUnitLabel", GetString.self)
let getInteger = fn("IOReportSimpleGetIntegerValue", GetInteger.self)
let getStateCount = fn("IOReportStateGetCount", GetCount.self)
let getStateName = fn("IOReportStateGetNameForIndex", GetStateName.self)
let getResidency = fn("IOReportStateGetResidency", GetResidency.self)
let getFormat = fn("IOReportChannelGetFormat", GetFormat.self)

func str(_ value: Unmanaged<CFString>?) -> String { value.map { $0.takeUnretainedValue() as String } ?? "-" }

// MARK: - DVFS tables from the power manager node in the IORegistry

func printFrequencyTables() {
    print("== pmgr voltage-states (frequency tables)")
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
    guard service != 0 else { print("no pmgr service"); return }
    defer { IOObjectRelease(service) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { print("no properties"); return }
    for key in dict.keys.sorted() where key.hasPrefix("voltage-states") {
        guard let data = dict[key] as? Data else { continue }
        // Pairs of UInt32: frequency, voltage. Units vary by chip, so print raw.
        let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let freqs = stride(from: 0, to: words.count - 1, by: 2).map { words[$0] }
        print("  \(key) [\(freqs.count)]: \(freqs.prefix(24).map(String.init).joined(separator: " "))")
    }
}

// MARK: - IOReport subscription

// `ior list [group]`: every channel's group, format and unit; with a group, each channel name.
typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
if CommandLine.arguments.dropFirst().first == "list" {
    let group = CommandLine.arguments.dropFirst(2).first
    let all: NSDictionary = if let group {
        copyChannels(group as CFString, nil, 0, 0, 0)!.takeRetainedValue()
    } else {
        fn("IOReportCopyAllChannels", CopyAll.self)(0, 0)!.takeRetainedValue()
    }
    var counts: [String: Int] = [:]
    for item in all["IOReportChannels"] as? [NSDictionary] ?? [] {
        let channel = item as CFDictionary
        let unit = str(getUnit(channel)).trimmingCharacters(in: .whitespaces)
        let key = "\(str(getGroup(channel))) / \(str(getSubGroup(channel))) format=\(getFormat(channel)) unit=\(unit)"
        if group != nil { print(key, "|", str(getName(channel))) } else { counts[key, default: 0] += 1 }
    }
    for (key, count) in counts.sorted(by: { $0.key < $1.key }) { print(count, key) }
    exit(0)
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "1") ?? 1
let groups: [(String, String?)] = [
    ("Energy Model", nil),
    ("CPU Stats", "CPU Core Performance States"),
    ("GPU Stats", "GPU Performance States"),
    // Per-cluster energy histograms, reported to keep updating on macOS 27 when Energy Model stalls.
    ("PMP", "Energy"),
]
var merged: CFMutableDictionary?
for (group, subgroup) in groups {
    guard let channels = copyChannels(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() else {
        print("group missing: \(group) / \(subgroup ?? "-")"); continue
    }
    if let existing = merged { mergeChannels(existing, channels, nil) } else { merged = channels }
}
guard let channels = merged else { fatalError("no channels") }
var subscribed: Unmanaged<CFMutableDictionary>?
guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil),
      let subscribedChannels = subscribed?.takeRetainedValue() else { fatalError("subscription failed") }

// `ior watch N`: print raw energy counters once a second for N seconds, to see how often they move.
if CommandLine.arguments.dropFirst().first == "watch" {
    let count = Int(CommandLine.arguments.dropFirst(2).first ?? "30") ?? 30
    let names = ["CPU Energy", "ECPU", "PCPU", "DRAM", "ANE", "GPU Energy"]
    print("t  " + names.joined(separator: " | "))
    for second in 0..<count {
        let sample = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
        let list = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []
        var values: [String: Int64] = [:]
        for item in list where getFormat(item as CFDictionary) == 1 {
            values[str(getName(item as CFDictionary))] = getInteger(item as CFDictionary, 0)
        }
        print("\(second)  " + names.map { values[$0].map(String.init) ?? "-" }.joined(separator: " | "))
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

// `ior time`: cost of IOReportCreateSamples and the delta for each group on its own.
// `ior time [gap] [count]` waits `gap` seconds between samples, as Pulse would.
if CommandLine.arguments.dropFirst().first == "time" {
    let clock = ContinuousClock()
    let gap = Double(CommandLine.arguments.dropFirst(2).first ?? "0") ?? 0
    let rounds = Int(CommandLine.arguments.dropFirst(3).first ?? "50") ?? 50
    for (group, subgroup) in groups {
        guard let found = copyChannels(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, found, &subbed, 0, nil), let chans = subbed?.takeRetainedValue() else { continue }
        var previous = createSamples(sub, chans, nil)!.takeRetainedValue()
        var sampleTime = Duration.zero, deltaTime = Duration.zero
        let cpu0 = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for _ in 0..<rounds {
            if gap > 0 { Thread.sleep(forTimeInterval: gap) }
            let t0 = clock.now
            let next = createSamples(sub, chans, nil)!.takeRetainedValue()
            let t1 = clock.now
            _ = createDelta(previous, next, nil)
            deltaTime += clock.now - t1
            sampleTime += t1 - t0
            previous = next
        }
        let count = ((found as NSDictionary)["IOReportChannels"] as? [Any])?.count ?? 0
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu0) / Double(rounds) / 1e6
        print("\(group) / \(subgroup ?? "-") [\(count) channels]: wall sample \(sampleTime / rounds), delta \(deltaTime / rounds),"
            + String(format: " CPU %.3f ms per sample+delta", cpuMs))
    }
    exit(0)
}

// `ior calibrate S`: over S seconds, print Energy Model energy (J) next to the PMP histogram sums
// (sum of bucket watts x event count). Run with powermetrics active so Energy Model counts.
if CommandLine.arguments.dropFirst().first == "calibrate" {
    let span = Double(CommandLine.arguments.dropFirst(2).first ?? "10") ?? 10
    let start = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
    Thread.sleep(forTimeInterval: span)
    let end = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
    let change = createDelta(start, end, nil)!.takeRetainedValue() as NSDictionary
    var model: [String: Double] = [:], histogram: [String: Double] = [:], events: [String: Double] = [:]
    // Midpoint model: a bucket label is the top of its range, and each event lasts about 227.3 us
    // (the P cluster records at most ~4399 events per second when fully busy).
    let eventSeconds = 12.0 / 52790.0
    var estimate: [String: Double] = [:]
    for item in change["IOReportChannels"] as? [NSDictionary] ?? [] {
        let channel = item as CFDictionary
        let name = str(getName(channel))
        if getFormat(channel) == 1, ["ECPU", "PCPU", "GPU Energy"].contains(name) {
            let unit = str(getUnit(channel)).trimmingCharacters(in: .whitespaces)
            model[name] = Double(getInteger(channel, 0)) * (unit == "nJ" ? 1e-9 : 1e-3)
        } else if getFormat(channel) == 2, str(getSubGroup(channel)) == "Energy" {
            let buckets = (0..<getStateCount(channel)).map { index in
                (watts: Double(str(getStateName(channel, index)).trimmingCharacters(in: .whitespaces).dropLast()) ?? 0,
                 count: Double(getResidency(channel, index)))
            }
            let levels = buckets.map(\.watts).filter { $0 > 0 }.sorted()
            let step = zip(levels.dropFirst(), levels).map { $0 - $1 }.filter { $0 > 0 }.min() ?? 0
            for bucket in buckets {
                histogram[name, default: 0] += bucket.watts * bucket.count
                events[name, default: 0] += bucket.count
                estimate[name, default: 0] += max(0, bucket.watts - step / 2) * bucket.count * eventSeconds
            }
        }
    }
    func fmt(_ value: Double?) -> String { String(format: "%.3f", value ?? .nan) }
    let e = (histogram["EACC0"] ?? 0) + (histogram["EACC0 SRAM"] ?? 0)
    let p = (histogram["PACC0"] ?? 0) + (histogram["PACC0 SRAM"] ?? 0)
    let g = (histogram["AGX"] ?? 0) + (histogram["AGX SRAM"] ?? 0)
    print("span_s=\(span) ECPU_J=\(fmt(model["ECPU"])) PCPU_J=\(fmt(model["PCPU"])) GPU_J=\(fmt(model["GPU Energy"]))"
        + " E_hist=\(fmt(e)) P_hist=\(fmt(p)) G_hist=\(fmt(g))"
        + " E_events=\(Int(events["EACC0"] ?? 0)) P_events=\(Int(events["PACC0"] ?? 0)) G_events=\(Int(events["AGX"] ?? 0))"
        + " E_sram_events=\(Int(events["EACC0 SRAM"] ?? 0)) P_sram_events=\(Int(events["PACC0 SRAM"] ?? 0))")
    let estE = (estimate["EACC0"] ?? 0) + (estimate["EACC0 SRAM"] ?? 0)
    let estP = (estimate["PACC0"] ?? 0) + (estimate["PACC0 SRAM"] ?? 0)
    func error(_ est: Double, _ ref: Double?) -> String {
        guard let ref, ref > 0 else { return "n/a" }
        return String(format: "%+.1f%%", (est / ref - 1) * 100)
    }
    print("  estimate: E=\(fmt(estE / span)) W (\(error(estE, model["ECPU"]))) P=\(fmt(estP / span)) W (\(error(estP, model["PCPU"])))"
        + " CPU=\(fmt((estE + estP) / span)) W (\(error(estE + estP, (model["ECPU"] ?? 0) + (model["PCPU"] ?? 0))))")
    exit(0)
}

// `ior dump S`: one delta over S seconds as JSON, in PulseCore's IOReportReading format, plus the
// pmgr frequency tables. Used to record test fixtures.
if CommandLine.arguments.dropFirst().first == "dump" {
    let span = Double(CommandLine.arguments.dropFirst(2).first ?? "2") ?? 2
    let start = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
    Thread.sleep(forTimeInterval: span)
    let end = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
    let change = createDelta(start, end, nil)!.takeRetainedValue() as NSDictionary
    var readings: [[String: Any]] = []
    for item in change["IOReportChannels"] as? [NSDictionary] ?? [] {
        let channel = item as CFDictionary
        let name = str(getName(channel))
        let group = str(getGroup(channel))
        // Keep what the power collector reads; Energy Model has ~160 other channels.
        if group == "Energy Model", name != "GPU Energy" { continue }
        var reading: [String: Any] = [
            "group": group, "subgroup": getSubGroup(channel).map { $0.takeUnretainedValue() as String } ?? "", "channel": name,
            "unit": str(getUnit(channel)).trimmingCharacters(in: .whitespaces),
        ]
        switch getFormat(channel) {
        case 1: reading["value"] = getInteger(channel, 0)
        case 2:
            reading["states"] = (0..<getStateCount(channel)).map { index in
                ["name": str(getStateName(channel, index)).trimmingCharacters(in: .whitespaces),
                 "value": getResidency(channel, index)] as [String: Any]
            }
        default: continue
        }
        readings.append(reading)
    }
    var tables: [String: [UInt32]] = [:]
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
    var props: Unmanaged<CFMutableDictionary>?
    if service != 0, IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let dict = props?.takeRetainedValue() as? [String: Any] {
        for key in ["voltage-states1-sram", "voltage-states5-sram", "voltage-states9"] {
            guard let data = dict[key] as? Data else { continue }
            tables[key] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        }
        IOObjectRelease(service)
    }
    let output: [String: Any] = ["seconds": span, "readings": readings, "voltageStates": tables]
    let json = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(json)
    exit(0)
}

printFrequencyTables()

let first = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
let start = Date()
Thread.sleep(forTimeInterval: seconds)
let second = createSamples(subscription, subscribedChannels, nil)!.takeRetainedValue()
let elapsed = Date().timeIntervalSince(start)
let delta = createDelta(first, second, nil)!.takeRetainedValue() as NSDictionary

// Raw counters, to tell a counter that never moves from a delta that comes out as zero.
func rawValues(_ sample: CFDictionary, _ names: Set<String>) -> [String: Int64] {
    let list = (sample as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []
    var values: [String: Int64] = [:]
    for item in list where getFormat(item as CFDictionary) == 1 {
        let name = str(getName(item as CFDictionary))
        if names.contains(name) { values[name] = getInteger(item as CFDictionary, 0) }
    }
    return values
}
let rawNames: Set<String> = ["CPU Energy", "ECPU", "PCPU", "PCPU0", "GPU Energy", "DRAM", "ANE"]
let rawFirst = rawValues(first, rawNames), rawSecond = rawValues(second, rawNames)
print("== raw counters (first -> second)")
for name in rawNames.sorted() { print("  \(name): \(rawFirst[name].map(String.init) ?? "-") -> \(rawSecond[name].map(String.init) ?? "-")") }
let items = delta["IOReportChannels"] as? [NSDictionary] ?? []
print(String(format: "== %d channels over %.3f s", items.count, elapsed))

var lastGroup = ""
for item in items {
    let channel = item as CFDictionary
    let group = "\(str(getGroup(channel))) / \(str(getSubGroup(channel)))"
    if group != lastGroup { print("-- \(group)"); lastGroup = group }
    let name = str(getName(channel))
    let format = getFormat(channel)
    if format == 1 {
        // Simple: an energy counter. Print watts from the delta.
        let value = getInteger(channel, 0)
        let unit = str(getUnit(channel)).trimmingCharacters(in: .whitespaces)
        let scale: Double = switch unit { case "mJ": 1e-3; case "uJ": 1e-6; case "nJ": 1e-9; default: .nan }
        // Totals are always shown, even at zero; per-core and detail channels only when non-zero.
        let isTotal = ["CPU Energy", "GPU Energy", "ANE", "DRAM", "ECPU", "PCPU", "GPU"].contains(name) || name.hasPrefix("ANE") || name.hasPrefix("DRAM")
        guard value != 0 || isTotal else { continue }
        guard !name.contains("DTL") else { continue }
        print(String(format: "  %-28@ %12lld %-3@ = %8.3f W", name as NSString, value, unit as NSString, Double(value) * scale / elapsed))
    } else if format == 2 {
        // State: residency per performance state. Print non-zero states only.
        let count = getStateCount(channel)
        let states = (0..<count).compactMap { index -> String? in
            let residency = getResidency(channel, index)
            return residency > 0 ? "\(str(getStateName(channel, index)))=\(residency)" : nil
        }
        print("  \(name) [\(count) states]: \(states.joined(separator: " "))")
    } else {
        print("  \(name): format \(format)")
    }
}
