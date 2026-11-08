import Darwin
import Foundation

/// Apple's private IOReport library, loaded at run time from the dyld shared cache.
///
/// IOReport exposes the chip's internal counters: energy, performance-state residency and more.
/// The function signatures follow macmon and mactop. See `Tools/spikes/ioreport` and
/// docs/m2-findings.md.
struct IOReportLibrary: Sendable {
    typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
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

    /// `IOReportChannelGetFormat` values.
    enum Format: UInt8 {
        case simple = 1
        case state = 2
    }

    let copyChannels: CopyChannels
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createDelta: CreateDelta
    let group: GetString
    let subgroup: GetString
    let name: GetString
    let unit: GetString
    let integer: GetInteger
    let stateCount: GetCount
    let stateName: GetStateName
    let residency: GetResidency
    let format: GetFormat

    static let shared = IOReportLibrary()

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func load<T>(_ symbol: String, _: T.Type) -> T? {
            dlsym(handle, symbol).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = load("IOReportCopyChannelsInGroup", CopyChannels.self),
              let createSubscription = load("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", CreateSamples.self),
              let createDelta = load("IOReportCreateSamplesDelta", CreateDelta.self),
              let group = load("IOReportChannelGetGroup", GetString.self),
              let subgroup = load("IOReportChannelGetSubGroup", GetString.self),
              let name = load("IOReportChannelGetChannelName", GetString.self),
              let unit = load("IOReportChannelGetUnitLabel", GetString.self),
              let integer = load("IOReportSimpleGetIntegerValue", GetInteger.self),
              let stateCount = load("IOReportStateGetCount", GetCount.self),
              let stateName = load("IOReportStateGetNameForIndex", GetStateName.self),
              let residency = load("IOReportStateGetResidency", GetResidency.self),
              let format = load("IOReportChannelGetFormat", GetFormat.self) else { return nil }
        self.copyChannels = copyChannels
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.group = group
        self.subgroup = subgroup
        self.name = name
        self.unit = unit
        self.integer = integer
        self.stateCount = stateCount
        self.stateName = stateName
        self.residency = residency
        self.format = format
    }
}

/// A subscription to selected IOReport channels. Not thread-safe: own it from one actor.
final class IOReportSubscription {
    struct Selection {
        let group: String
        let subgroup: String?
        /// Channel names to keep, or nil for all. Subscribing to fewer channels costs less to sample.
        let channels: Set<String>?
    }

    private let library: IOReportLibrary
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary

    /// `extraChannels` are channel descriptions built by hand, such as `CLPCChannels`.
    init(_ selections: [Selection], extraChannels: [NSDictionary] = []) throws {
        guard let library = IOReportLibrary.shared else {
            throw CollectorError.unavailable("libIOReport could not be loaded")
        }
        var kept = extraChannels
        // Any group's dictionary serves as the template for the request's other keys.
        let template = library.copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSDictionary?
        for selection in selections {
            guard let found = library.copyChannels(
                selection.group as CFString, selection.subgroup as CFString?, 0, 0, 0
            )?.takeRetainedValue() as NSDictionary? else { continue }
            let list = found["IOReportChannels"] as? [NSDictionary] ?? []
            kept += list.filter { selection.channels?.contains(Self.string(library.name($0 as CFDictionary))) ?? true }
        }
        guard let template, !kept.isEmpty else {
            throw CollectorError.unavailable("no IOReport channels found")
        }
        // Keeps the dictionary's other keys and replaces only the channel list.
        let request = NSMutableDictionary(dictionary: template)
        request["IOReportChannels"] = kept
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = library.createSubscription(nil, request as CFMutableDictionary, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue() else {
            throw CollectorError.unavailable("IOReport subscription failed")
        }
        self.library = library
        self.subscription = subscription
        self.channels = channels
    }

    func sample() -> CFDictionary? {
        library.createSamples(subscription, channels, nil)?.takeRetainedValue()
    }

    /// Names, units and state labels never change for a subscription, and converting them to
    /// strings on every tick was a large share of the cost. They are read once, by position.
    private struct ChannelLayout {
        let group: String
        let subgroup: String
        let name: String
        let unit: String
        let format: IOReportLibrary.Format?
        let stateNames: [String]
    }

    private var layout: [ChannelLayout] = []

    /// The change between two samples, copied into plain values.
    func readings(from start: CFDictionary, to end: CFDictionary) -> [IOReportReading] {
        guard let delta = library.createDelta(start, end, nil)?.takeRetainedValue() as NSDictionary?,
              let list = delta["IOReportChannels"] as? [NSDictionary] else { return [] }
        if layout.count != list.count { layout = list.map { describe($0 as CFDictionary) } }
        return zip(list, layout.indices).compactMap { item, index in
            let channel = item as CFDictionary
            var info = layout[index]
            if info.format == .state, Int(library.stateCount(channel)) != info.stateNames.count {
                info = describe(channel)
                layout[index] = info
            }
            switch info.format {
            case .simple:
                return IOReportReading(
                    group: info.group, subgroup: info.subgroup, channel: info.name, unit: info.unit,
                    value: library.integer(channel, 0)
                )
            case .state:
                let states = info.stateNames.indices.map { state in
                    IOReportReading.State(name: info.stateNames[state], value: library.residency(channel, Int32(state)))
                }
                return IOReportReading(group: info.group, subgroup: info.subgroup, channel: info.name, unit: info.unit, states: states)
            case nil:
                return nil
            }
        }
    }

    private func describe(_ channel: CFDictionary) -> ChannelLayout {
        let format = IOReportLibrary.Format(rawValue: library.format(channel))
        let stateNames = format == .state
            ? (0..<library.stateCount(channel)).map {
                Self.string(library.stateName(channel, $0)).trimmingCharacters(in: .whitespaces)
            }
            : []
        return ChannelLayout(
            group: Self.string(library.group(channel)),
            subgroup: Self.string(library.subgroup(channel)),
            name: Self.string(library.name(channel)),
            unit: Self.string(library.unit(channel)).trimmingCharacters(in: .whitespaces),
            format: format,
            stateNames: stateNames
        )
    }

    private static func string(_ value: Unmanaged<CFString>?) -> String {
        value.map { $0.takeUnretainedValue() as String } ?? ""
    }
}
