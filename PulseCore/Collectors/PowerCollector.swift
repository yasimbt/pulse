import Foundation
import IOKit

/// CPU, GPU and Neural Engine watts, plus cluster detail and frequencies, from IOReport. Needs no
/// root. See docs/m2-findings.md for why each source is used.
///
/// - Always: AppleCLPC's aggregate counters on verified chips, about 1.5 ms per sample, read at
///   most every 2 s. Elsewhere, the PMP energy histograms plus the Energy Model GPU counter, which
///   cost about 7.5 ms per sample, so they are read at most every 5 s.
/// - With detail on, such as while the Power panel is open: the PMP histograms for the E/P split,
///   and performance-state residency for frequencies, every sample.
public actor PowerCollector: Collector {
    public nonisolated let id = MetricID.power

    private static let histograms = IOReportSubscription.Selection(group: "PMP", subgroup: "Energy", channels: nil)
    private static let modelGPU = IOReportSubscription.Selection(group: "Energy Model", subgroup: nil, channels: ["GPU Energy"])
    private static let residency = [
        IOReportSubscription.Selection(group: "CPU Stats", subgroup: "CPU Core Performance States", channels: nil),
        IOReportSubscription.Selection(group: "GPU Stats", subgroup: "GPU Performance States", channels: ["GPUPH"])
    ]
    /// Without detail, power is read at most this often. Each read averages the whole interval,
    /// so no energy is missed. At 1 s, the Power item put Pulse over its 0.5% CPU budget.
    private static let summaryInterval: Duration = .seconds(2)
    private static let fallbackInterval: Duration = .seconds(5)

    /// One subscription and its previous sample.
    private final class Feed {
        let subscription: IOReportSubscription
        var previous: (sample: CFDictionary, time: ContinuousClock.Instant)?
        var latestTotals: [IOReportReading] { previous.map { subscription.readings(in: $0.sample) } ?? [] }

        init(_ selections: [IOReportSubscription.Selection], extraChannels: [NSDictionary] = []) throws {
            subscription = try IOReportSubscription(selections, extraChannels: extraChannels)
        }

        /// The change since the previous call, or nil on the first.
        func advance(at now: ContinuousClock.Instant) throws -> (readings: [IOReportReading], seconds: Double)? {
            guard let current = subscription.sample() else {
                throw CollectorError.unavailable("IOReport sample failed")
            }
            defer { previous = (current, now) }
            guard let previous else { return nil }
            return (subscription.readings(from: previous.sample, to: current), Rates.seconds(now - previous.time))
        }
    }

    private let clock = ContinuousClock()
    private var base: Feed?
    private var usesCLPC = false
    private var detailFeed: Feed?
    private var detail = false
    private var tables: FrequencyTables?
    private var last: (sample: PowerSample, time: ContinuousClock.Instant)?

    public init() {}

    /// Adds the E/P cluster split and frequencies, at extra cost.
    public func setDetail(_ include: Bool) {
        detail = include
        if !include { detailFeed = nil }
    }

    public func sample() throws -> PowerSample {
        let base = try self.base ?? makeBase()
        self.base = base
        let tables = self.tables ?? Self.readFrequencyTables()
        self.tables = tables
        let now = clock.now

        // Between reads, the last sample is repeated.
        let interval = usesCLPC ? Self.summaryInterval : Self.fallbackInterval
        if !detail, let last, now - last.time < interval {
            return last.sample
        }
        var extra: [IOReportReading] = []
        if detail {
            // Detail is optional, so a failure here leaves watts working.
            if detailFeed == nil {
                detailFeed = try? Feed(usesCLPC ? [Self.histograms] + Self.residency : Self.residency)
            }
            extra = (try? detailFeed?.advance(at: now))??.readings ?? []
        }
        guard let change = try base.advance(at: now) else {
            return .empty
        }
        var sample = PowerCalculations.sample(change.readings + extra, seconds: change.seconds, tables: tables)
        // Only the panel shows it, so it isn't read while the panel is closed.
        if usesCLPC, detail { sample.energySinceBootJoules = PowerCalculations.cumulativeJoules(base.latestTotals) }
        last = (sample, now)
        return sample
    }

    private func makeBase() throws -> Feed {
        if let clpc = CLPCChannels.channels(), let feed = try? Feed([], extraChannels: clpc) {
            usesCLPC = true
            return feed
        }
        usesCLPC = false
        return try Feed([Self.histograms, Self.modelGPU])
    }

    /// Read once: the tables are fixed for the chip.
    private static func readFrequencyTables() -> FrequencyTables {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return FrequencyTables(voltageStates: [:]) }
        defer { IOObjectRelease(service) }
        let keys = FrequencyTables.keys
        var words: [String: [UInt32]] = [:]
        for key in [keys.efficiency, keys.performance, keys.gpu] {
            guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
                  let data = property.takeRetainedValue() as? Data else { continue }
            words[key] = FrequencyTables.words(data)
        }
        return FrequencyTables(voltageStates: words)
    }
}
