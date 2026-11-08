import Foundation
@testable import PulseCore
import Testing

/// Recorded on the M5 (Mac17,3) after 25 s of 4 busy loops, with `Tools/spikes/hid-temps`.
private struct TemperatureFixture: Decodable {
    let sensors: [SensorValue]

    static func load() throws -> [SensorValue] {
        try JSONDecoder().decode(TemperatureFixture.self, from: Fixture.data("hid-temperatures-m5-load", "json")).sensors
    }
}

@Test func bundledSensorMapHasRulesForTheM5AndAFallback() throws {
    let map = try SensorMap.bundled()
    #expect(map.rules(forModel: "Mac17,3").map(\.id) == ["chipHottest", "chipAverage", "ssd", "battery"])
    #expect(!map.rules(forModel: "UnknownModel1,1").isEmpty)
}

@Test func m5LoadFixtureGivesChipSSDAndBatteryTemperatures() throws {
    let rules = try SensorMap.bundled().rules(forModel: "Mac17,3")
    let sample = ThermalSample(readings: TemperatureCalculations.readings(try TemperatureFixture.load(), rules: rules))
    // PMU tdie1 was the hottest die sensor. The 14 PMU tdie sensors average 61.32 °C.
    #expect(sample.reading("chipHottest")?.celsius == 76.03)
    let average = try #require(sample.reading("chipAverage")?.celsius)
    #expect(abs(average - 61.3236) < 0.001)
    #expect(sample.reading("ssd")?.celsius == 40.0)
    #expect(sample.reading("battery") != nil)
}

@Test func faultySensorsAreIgnored() {
    let rule = SensorMap.Rule(id: "board", title: "Board", prefix: "PMU tdev", reduce: .mean)
    let sensors = [SensorValue(name: "PMU tdev1", celsius: -22.2), SensorValue(name: "PMU tdev2", celsius: 46)]
    #expect(TemperatureCalculations.readings(sensors, rules: [rule]).first?.celsius == 46)
    #expect(TemperatureCalculations.readings([sensors[0]], rules: [rule]).isEmpty)
}

@Test func onlySensorsInTheMapAreRead() {
    let rule = SensorMap.Rule(id: "chip", title: "Chip", prefix: "PMU tdie", reduce: .max)
    #expect(TemperatureCalculations.isUsed("PMU tdie3", by: [rule]))
    #expect(!TemperatureCalculations.isUsed("PMU2 tdie3", by: [rule]))
}

@Test func liveTemperatureCollectorReadsThisMachine() async throws {
    let sample = try await TemperatureCollector().sample()
    let chip = try #require(sample.reading("chipHottest"))
    #expect((10...110).contains(chip.celsius))
}
