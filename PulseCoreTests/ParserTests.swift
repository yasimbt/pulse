import Darwin
import Foundation
@testable import PulseCore
import Testing

// MARK: - Battery

private func batteryFixture() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Fixture.data("battery-m5", "json")) as? [String: Any] ?? [:]
}

@Test func parsesRecordedM5Battery() throws {
    let sample = try #require(BatteryParser.parse(batteryFixture()))
    #expect(sample.chargeFraction == 0.95)
    #expect(sample.cycleCount == 3)
    #expect(sample.voltageVolts == 13.107)
    #expect(sample.isExternalPowerConnected)
    #expect(!sample.isCharging)
    #expect(abs((sample.healthFraction ?? 0) - 4645.0 / 4629.0) < 1e-9)
}

@Test func m5BatteryHasNoTemperatureOrTime() throws {
    let sample = try #require(BatteryParser.parse(batteryFixture()))
    #expect(sample.temperatureCelsius == nil)
    #expect(sample.timeRemainingSeconds == nil, "65535 means unknown")
}

@Test func batteryCurrentWrappedAsUnsignedReadsNegative() throws {
    var properties = try batteryFixture()
    properties["Amperage"] = NSNumber(value: UInt64(bitPattern: -1500))
    let sample = try #require(BatteryParser.parse(properties))
    #expect(sample.currentAmps == -1.5)
    #expect(abs((sample.powerWatts ?? 0) - (13.107 * -1.5)) < 1e-9)
}

@Test func batteryOptionalFieldsParseWhenPresent() throws {
    var properties = try batteryFixture()
    properties["Temperature"] = 3050
    properties["TimeRemaining"] = 90
    let sample = try #require(BatteryParser.parse(properties))
    #expect(sample.temperatureCelsius == 30.5)
    #expect(sample.timeRemainingSeconds == 5400)
}

@Test func batteryWithoutCapacityIsNil() {
    #expect(BatteryParser.parse([:]) == nil)
    #expect(BatteryParser.parse(["CurrentCapacity": 50, "MaxCapacity": 0]) == nil)
}

// MARK: - nettop

@Test func parsesRecordedNettop() throws {
    let text = String(decoding: try Fixture.data("nettop-before", "csv"), as: UTF8.self)
    let rows = NettopParser.parse(text)
    #expect(rows.count == 5, "the header row is skipped")
    #expect(rows[1] == NettopRow(pid: 393, name: "apsd", receivedBytes: 1_575_609, sentBytes: 1_206_301))
}

@Test func nettopNamesMayContainDots() {
    let rows = NettopParser.parse("com.apple.WebKit.Networking.812,10,20,\n")
    #expect(rows.first?.name == "com.apple.WebKit.Networking")
    #expect(rows.first?.pid == 812)
}

@Test func nettopRanksByDeltaNotLifetimeTotal() {
    let before = [
        NettopRow(pid: 1, name: "old", receivedBytes: 1_000_000, sentBytes: 0),
        NettopRow(pid: 2, name: "busy", receivedBytes: 0, sentBytes: 0)
    ]
    let after = [
        NettopRow(pid: 1, name: "old", receivedBytes: 1_000_000, sentBytes: 0),
        NettopRow(pid: 2, name: "busy", receivedBytes: 500, sentBytes: 500),
        NettopRow(pid: 3, name: "new", receivedBytes: 9_999_999, sentBytes: 0)
    ]
    let usages = NettopParser.usages(previous: before, current: after, seconds: 5)
    #expect(usages.map(\.name) == ["busy", "old"], "a new pid has no delta yet")
    #expect(usages[0].downBytesPerSecond == 100)
}

// MARK: - Routing messages

private func routeMessage(index: UInt16, flags: Int32, received: UInt64, sent: UInt64) -> [UInt8] {
    var message = if_msghdr2()
    message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    message.ifm_type = UInt8(RTM_IFINFO2)
    message.ifm_index = index
    message.ifm_flags = flags
    message.ifm_data.ifi_ibytes = received
    message.ifm_data.ifi_obytes = sent
    return withUnsafeBytes(of: message) { Array($0) }
}

/// Built from the real struct layout, because a recorded buffer would contain MAC addresses.
@Test func parsesInterfaceCountersAboveFourGiB() {
    let bytes = routeMessage(index: 7, flags: IFF_UP, received: 5_000_000_000, sent: 42)
    let parsed = bytes.withUnsafeBytes { RouteMessageParser.parse($0) { $0 == 7 ? "en0" : nil } }
    #expect(parsed == [InterfaceCounters(name: "en0", isUp: true, receivedBytes: 5_000_000_000, sentBytes: 42)])
}

/// Regression test: the spike crashed loading a full struct from a short trailing message.
@Test func shortAndTruncatedRouteMessagesDoNotCrash() {
    let short: [UInt8] = [8, 0, 5, UInt8(RTM_NEWMADDR2), 0, 0, 0, 0]
    var bytes = routeMessage(index: 1, flags: IFF_UP, received: 1, sent: 2) + short
    bytes += [200, 0, 5, UInt8(RTM_IFINFO2)]
    let parsed = bytes.withUnsafeBytes { RouteMessageParser.parse($0) { _ in "en0" } }
    #expect(parsed.count == 1)

    let zeroLength: [UInt8] = [0, 0, 5, 0]
    #expect(zeroLength.withUnsafeBytes { RouteMessageParser.parse($0) { _ in "en0" } }.isEmpty)
}
