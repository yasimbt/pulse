import Foundation
@testable import PulseCore
import Testing

// MARK: - Rates and memory

@Test func rateFromCounters() {
    #expect(Rates.perSecond(current: 3000, previous: 1000, seconds: 2) == 1000)
}

@Test func resetCounterReadsZero() {
    #expect(Rates.perSecond(current: 10, previous: 1000, seconds: 1) == 0)
}

@Test func zeroElapsedReadsZero() {
    #expect(Rates.perSecond(current: 3000, previous: 1000, seconds: 0) == 0)
}

@Test func durationConvertsToSeconds() {
    #expect(Rates.seconds(.milliseconds(1500)) == 1.5)
}

/// Page counts recorded from `host_statistics64` on the M5.
@Test func memoryBreakdownFromRecordedPages() {
    let pages = MemoryCalculations.PageCounts(internal: 640_291, purgeable: 36960, wired: 188_256, compressor: 305_726)
    let result = MemoryCalculations.breakdown(pages: pages, pageSize: 16384)
    #expect(result.app == 603_331 * 16384)
    #expect(result.wired == 188_256 * 16384)
    #expect(result.compressed == 305_726 * 16384)
}

@Test func purgeableAboveInternalDoesNotUnderflow() {
    let pages = MemoryCalculations.PageCounts(internal: 1, purgeable: 5, wired: 0, compressor: 0)
    #expect(MemoryCalculations.breakdown(pages: pages, pageSize: 16384).app == 0)
}

// MARK: - Network

private func counters(_ name: String, _ received: UInt64, _ sent: UInt64, up: Bool = true) -> InterfaceCounters {
    InterfaceCounters(name: name, isUp: up, receivedBytes: received, sentBytes: sent)
}

@Test func networkTotalsExcludeLoopbackAndTunnels() {
    let before = [counters("en0", 1000, 1000), counters("utun4", 0, 0), counters("lo0", 0, 0)]
    let after = [counters("en0", 3000, 2000), counters("utun4", 2000, 1000), counters("lo0", 9000, 9000)]
    let sample = NetworkCalculations.sample(previous: before, current: after, seconds: 2)
    #expect(sample.downBytesPerSecond == 1000)
    #expect(sample.upBytesPerSecond == 500)
    #expect(sample.interfaces.map(\.name) == ["en0", "utun4"], "tunnels are listed but not totalled")
}

@Test func networkSkipsDownAndNewInterfaces() {
    let before = [counters("en0", 0, 0), counters("en1", 0, 0)]
    let after = [counters("en0", 100, 100, up: false), counters("en1", 100, 100), counters("en2", 500, 500)]
    let sample = NetworkCalculations.sample(previous: before, current: after, seconds: 1)
    #expect(sample.interfaces.map(\.name) == ["en1"])
}

// MARK: - Processes

/// 23,991,310 ticks is what a 1 s CPU burn recorded on the M5.
@Test func rusageTicksScaleToNanoseconds() {
    let nanoseconds = ProcessCalculations.nanoseconds(ticks: 23_991_310, numer: 125, denom: 3)
    #expect(abs(Double(nanoseconds) / 1e9 - 1.0) < 0.01)
}

private func process(_ pid: Int32, cpu: UInt64, footprint: UInt64 = 0, read: UInt64 = 0, energy: UInt64 = 0) -> ProcessCounters {
    ProcessCounters(
        pid: pid, name: "p\(pid)", cpuNanoseconds: cpu, footprintBytes: footprint, diskReadBytes: read, diskWriteBytes: 0,
        energyNanojoules: energy
    )
}

@Test func processEnergyBecomesWattsAndIsRanked() {
    let previous: [Int32: ProcessCounters] = [1: process(1, cpu: 0, energy: 1_000), 2: process(2, cpu: 0, energy: 0)]
    let current = [process(1, cpu: 0, energy: 4_000_001_000), process(2, cpu: 0, energy: 500_000_000)]
    let usages = ProcessCalculations.usages(previous: previous, current: current, seconds: 2)
    #expect(usages.first { $0.pid == 1 }?.energyWatts == 2)
    let table = ProcessCalculations.table(usages: usages, unreadableCount: 0)
    #expect(table.byEnergy.map(\.pid) == [1, 2])
}

@Test func processCPURateAndNewPidSkipped() {
    let previous: [Int32: ProcessCounters] = [1: process(1, cpu: 0)]
    let usages = ProcessCalculations.usages(previous: previous, current: [process(1, cpu: 2_000_000_000), process(2, cpu: 5)], seconds: 2)
    #expect(usages.map(\.pid) == [1])
    #expect(usages[0].cpuCores == 1, "one full core")
}

@Test func processTableRanksEachMetricAndLimits() {
    var previous: [Int32: ProcessCounters] = [:]
    var current: [ProcessCounters] = []
    for pid in Int32(1)...Int32(7) {
        previous[pid] = process(pid, cpu: 0)
        current.append(process(pid, cpu: UInt64(pid) * 1_000_000, footprint: UInt64(8 - pid), read: pid == 3 ? 500 : 0))
    }
    let usages = ProcessCalculations.usages(previous: previous, current: current, seconds: 1)
    let table = ProcessCalculations.table(usages: usages, unreadableCount: 337)
    #expect(table.byCPU.map(\.pid) == [7, 6, 5, 4, 3])
    #expect(table.byMemory.first?.pid == 1)
    #expect(table.byDisk.first?.pid == 3)
    #expect(table.unreadableCount == 337)
}

// MARK: - Ring buffer and history

@Test func ringBufferOverwritesOldest() {
    var buffer = RingBuffer<Int>(capacity: 3)
    (1...5).forEach { buffer.append($0) }
    #expect(buffer.elements == [3, 4, 5])
    #expect(buffer.last == 5)
    #expect(buffer.suffix(2) == [4, 5])
    #expect(buffer.suffix(10) == [3, 4, 5])
}

@Test func ringBufferBeforeFull() {
    var buffer = RingBuffer<Int>(capacity: 3)
    buffer.append(1)
    #expect(buffer.elements == [1])
    #expect(buffer.suffix(1) == [1])
}

@Test func historyKeepsOnlyTheTenMinuteWindow() {
    var history = MetricHistory()
    let now = Date(timeIntervalSince1970: 10000)
    for offset in [700.0, 599.0, 0.0] {
        var snapshot = Snapshot(timestamp: now.addingTimeInterval(-offset))
        snapshot.battery = BatterySample(
            chargeFraction: offset / 1000, isCharging: false, isExternalPowerConnected: false, isFullyCharged: false,
            cycleCount: nil, voltageVolts: nil, currentAmps: nil, healthFraction: nil, temperatureCelsius: nil, timeRemainingSeconds: nil
        )
        history.record(snapshot)
    }
    #expect(history.points(.batteryCharge, now: now).map(\.value) == [0.599, 0])
    #expect(history.recentValues(.batteryCharge, count: 1) == [0])
    #expect(history.points(.cpuTotal, now: now).isEmpty)
}

// MARK: - Settings

@Test func defaultSettingsAreAlreadyNormal() {
    #expect(PulseSettings.default.normalized() == PulseSettings.default)
}

@Test func normalizeRepairsSavedSettings() {
    let saved = PulseSettings(
        modules: [ModuleConfig(kind: .disk, isEnabled: true), ModuleConfig(kind: .disk, isEnabled: false)],
        sampleInterval: 60,
        isCombined: false
    ).normalized()
    #expect(saved.modules.first == ModuleConfig(kind: .disk, isEnabled: true), "order and first duplicate are kept")
    #expect(saved.modules.count == ModuleKind.allCases.count)
    #expect(saved.enabledModules.map(\.kind) == [.disk], "new modules start disabled")
    #expect(saved.sampleInterval == 5)
}

@Test func settingsRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(PulseSettings.default)
    #expect(try JSONDecoder().decode(PulseSettings.self, from: data) == PulseSettings.default)
}

// MARK: - Formatting

@Test func formatting() {
    #expect(MetricFormat.percent(0.236) == "24%")
    #expect(MetricFormat.bytes(1_500_000) == "1.5 MB")
    #expect(MetricFormat.bytes(999) == "999 B")
    #expect(MetricFormat.memory(25_769_803_776) == "24.0 GB")
    #expect(MetricFormat.rate(2000) == "2.0 KB/s")
    #expect(MetricFormat.compactRate(1_234_000) == "1.2M")
    #expect(MetricFormat.compactRate(999_600) == "1.0M", "does not read 1000K")
    #expect(MetricFormat.compactRate(12) == "12B")
    #expect(MetricFormat.cores(1.25) == "125.00%")
    #expect(MetricFormat.precisePercent(0.1234) == "12.34%")
    #expect(MetricFormat.duration(1500) == "25m")
    #expect(MetricFormat.duration(7500) == "2h 05m")
}

// MARK: - Module readings

@Test func networkFractionScalesToRecentPeakWithFloor() throws {
    var snapshot = Snapshot(timestamp: Date())
    snapshot.network = NetworkSample(interfaces: [], downBytesPerSecond: 500_000, upBytesPerSecond: 1000)
    let idle = try #require(ModuleReading.make(.network, snapshot: snapshot, recentPeak: 10))
    #expect(idle.fraction == 0.5, "uses the 1 MB/s floor")
    let busy = try #require(ModuleReading.make(.network, snapshot: snapshot, recentPeak: 5_000_000))
    #expect(busy.fraction == 0.1)
    #expect(busy.text == "↓500K ↑1.0K")
}

@Test func missingSampleHidesReading() {
    #expect(ModuleReading.make(.battery, snapshot: Snapshot(timestamp: Date()), recentPeak: 0) == nil)
}

// MARK: - Chart downsampling

private func timed(_ values: [Double]) -> [TimedValue] {
    values.enumerated().map { TimedValue(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element) }
}

@Test func downsamplingKeepsShortSpikes() {
    var values = Array(repeating: 0.1, count: 600)
    values[333] = 0.9
    let reduced = MetricHistory.downsampled(timed(values), maxCount: 120)
    #expect(reduced.count == 120)
    #expect(reduced.map(\.value).max() == 0.9)
    #expect(reduced.map(\.time) == reduced.map(\.time).sorted())
}

@Test func downsamplingLeavesShortSeriesAlone() {
    let points = timed([1, 2, 3])
    #expect(MetricHistory.downsampled(points, maxCount: 120) == points)
    #expect(MetricHistory.downsampled([], maxCount: 120).isEmpty)
}

@Test func downsamplingCoversEveryPointWithUnevenBuckets() {
    let reduced = MetricHistory.downsampled(timed((0..<1199).map(Double.init)), maxCount: 120)
    #expect(reduced.count == 120)
    #expect(reduced.last?.value == 1198)
}
