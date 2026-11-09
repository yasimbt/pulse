import Foundation
@testable import PulseCore
import Testing

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(_ second: TimeInterval, chip: Double? = nil, state: ThermalState? = nil, swap: UInt64? = nil) -> Snapshot {
    var snapshot = Snapshot(timestamp: start.addingTimeInterval(second))
    if chip != nil || state != nil {
        let readings = chip.map { [TemperatureReading(id: "chipHottest", title: "Chip, hottest", celsius: $0)] } ?? []
        snapshot.thermal = ThermalSample(readings: readings, state: state)
    }
    if let swap {
        snapshot.memory = MemorySample(
            totalBytes: 24 << 30, usedBytes: 16 << 30, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
            swapTotalBytes: 8 << 30, swapUsedBytes: swap, pressure: .normal
        )
    }
    return snapshot
}

private func settings(_ kinds: AlertKind...) -> AlertSettings {
    var settings = AlertSettings.default
    settings.enabled = Set(kinds)
    return settings
}

@Test func hotChipAlertsAfterAMinuteThenStaysQuiet() {
    var engine = AlertEngine()
    let enabled = settings(.chipTemperature)
    var fired: [TimeInterval] = []
    for second in stride(from: 0.0, through: 1900, by: 10) where !engine.evaluate(snapshot(second, chip: 97), settings: enabled).isEmpty {
        fired.append(second)
    }
    // Held for 60 s, then 30 minutes' quiet.
    #expect(fired == [60, 1860])
}

@Test func coolingDownResetsTheSustainTimer() {
    var engine = AlertEngine()
    let enabled = settings(.chipTemperature)
    #expect(engine.evaluate(snapshot(0, chip: 97), settings: enabled).isEmpty)
    #expect(engine.evaluate(snapshot(50, chip: 80), settings: enabled).isEmpty)
    // Hot again: the minute starts over.
    #expect(engine.evaluate(snapshot(60, chip: 97), settings: enabled).isEmpty)
    #expect(engine.evaluate(snapshot(120, chip: 97), settings: enabled).first?.kind == .chipTemperature)
}

@Test func disabledAlertsNeverFire() {
    var engine = AlertEngine()
    for second in stride(from: 0.0, through: 300, by: 10) {
        #expect(engine.evaluate(snapshot(second, chip: 105, state: .critical), settings: settings()).isEmpty)
    }
}

@Test func swapGrowthLooksAtTheLastTenMinutes() {
    var engine = AlertEngine()
    let enabled = settings(.swapGrowth)
    #expect(engine.evaluate(snapshot(0, swap: 1 << 30), settings: enabled).isEmpty)
    #expect(engine.evaluate(snapshot(300, swap: 2 << 30), settings: enabled).isEmpty)
    let event = engine.evaluate(snapshot(500, swap: 3 << 30 + 100_000_000), settings: enabled).first
    #expect(event?.kind == .swapGrowth)
    // Slow growth over more than ten minutes doesn't count.
    var slow = AlertEngine()
    for minute in 0...30 {
        #expect(slow.evaluate(snapshot(Double(minute) * 60, swap: UInt64(minute) * 100_000_000), settings: enabled).isEmpty)
    }
}

@Test func thermalPressureNeedsToLast() {
    var engine = AlertEngine()
    let enabled = settings(.thermalPressure)
    // Fair: three minutes.
    #expect(engine.evaluate(snapshot(0, chip: 80, state: .fair), settings: enabled).isEmpty)
    #expect(engine.evaluate(snapshot(170, chip: 80, state: .fair), settings: enabled).isEmpty)
    #expect(engine.evaluate(snapshot(180, chip: 80, state: .fair), settings: enabled).first?.kind == .thermalPressure)
    // Serious: thirty seconds.
    var serious = AlertEngine()
    #expect(serious.evaluate(snapshot(0, chip: 90, state: .serious), settings: enabled).isEmpty)
    #expect(serious.evaluate(snapshot(30, chip: 90, state: .serious), settings: enabled).first?.body.contains("heavy") == true)
}

@Test func lowDiskAndBatteryHealthFireAtOnce() {
    var engine = AlertEngine()
    var low = Snapshot(timestamp: start)
    low.disk = DiskSample(totalBytes: 500_000_000_000, availableBytes: 8_000_000_000, readBytesPerSecond: 0, writeBytesPerSecond: 0)
    low.battery = BatterySample(
        chargeFraction: 0.5, isCharging: false, isExternalPowerConnected: false, isFullyCharged: false, cycleCount: 900,
        voltageVolts: nil, currentAmps: nil, healthFraction: 0.78, temperatureCelsius: nil, timeRemainingSeconds: nil
    )
    let kinds = engine.evaluate(low, settings: settings(.lowDiskSpace, .batteryHealth)).map(\.kind)
    #expect(Set(kinds) == [.lowDiskSpace, .batteryHealth])
}

@Test func alertSettingsSurviveOlderSavedSettings() throws {
    // Settings saved before alerts existed still load, with alerts off.
    let old = Data(#"{"modules":[],"sampleInterval":1,"isCombined":false}"#.utf8)
    let decoded = try JSONDecoder().decode(PulseSettings.self, from: old)
    #expect(decoded.alerts == nil)
    #expect((decoded.alerts ?? .default).enabled.isEmpty)
}

@Test func snapshotsWithoutAReadingDontResetTheTimer() {
    var engine = AlertEngine()
    let enabled = settings(.chipTemperature)
    // Temperatures arrive every 10 s; the snapshots between them have none.
    for second in stride(from: 0.0, to: 60, by: 1) {
        let reading = second.truncatingRemainder(dividingBy: 10) == 0 ? 97.0 : nil
        #expect(engine.evaluate(snapshot(second, chip: reading), settings: enabled).isEmpty)
    }
    #expect(engine.evaluate(snapshot(60, chip: 97), settings: enabled).first?.kind == .chipTemperature)
}
