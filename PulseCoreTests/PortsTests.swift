import Foundation
@testable import PulseCore
import Testing

/// IORegistry readings on the M5 Air, from `Tools/spikes/ports`, with binary data removed.
private struct PortsFixture: Decodable {
    let battery: [String: AnyCodable]
    let ports: [[String: AnyCodable]]

    static func load(_ name: String) throws -> (battery: [String: Any], ports: [[String: Any]]) {
        let fixture = try JSONDecoder().decode(PortsFixture.self, from: Fixture.data(name, "json"))
        return (fixture.battery.mapValues(\.value), fixture.ports.map { $0.mapValues(\.value) })
    }
}

/// Decodes JSON into the plain values IORegistry properties come as.
private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }
}

@Test func ugreenChargerIsReadWithEveryOffer() throws {
    let fixture = try PortsFixture.load("charger-ugreen-65w-charging")
    let charger = try #require(PortsParser.charger(fixture.battery))
    #expect(charger.state == .charging)
    #expect(charger.description == "pd charger")
    #expect(charger.advertisedWatts == 65)
    #expect(charger.selectedVolts == 20 && charger.selectedAmps == 3.25)
    #expect(charger.offers == [
        .fixed(volts: 5, amps: 3), .fixed(volts: 9, amps: 3), .fixed(volts: 12, amps: 3), .fixed(volts: 15, amps: 3),
        .fixed(volts: 20, amps: 3.25), .programmable(minVolts: 3.3, maxVolts: 21, amps: 3)
    ])
    #expect(charger.inputWatts == 59.379 && charger.inputVolts == 18.92 && charger.inputAmps == 3.138)
    #expect(charger.systemWatts == 7.73 && charger.batteryWatts == 51.649 && charger.conversionLossWatts == 1.752)
    #expect(PortAlerts.chargerShortfall(charger) == nil)
}

@Test func portsShowOnlyWhatIsConnectedNow() throws {
    let charging = try PortsFixture.load("charger-ugreen-65w-charging").ports.compactMap(PortsParser.port)
    #expect(charging.map(\.name) == ["Port-USB-C@1", "Port-USB-C@2", "Port-MagSafe 3@1"])
    #expect(charging.map(\.isConnected) == [false, true, false])
    #expect(charging[1].activeTransports == ["CC"])
    #expect(charging[0].supportedTransports == ["CC", "USB2", "USB3", "CIO", "DisplayPort"])
    #expect(charging[2].type == "MagSafe 3")

    // With nothing plugged in, USB-C@2 still had leftovers from earlier, but isn't connected.
    let empty = try PortsFixture.load("ports-nothing-plugged")
    #expect(empty.ports.compactMap(PortsParser.port).allSatisfy { !$0.isConnected })
    #expect(PortsParser.charger(empty.battery) == nil)
}

@Test func powerOffersDecodeFromRawWords() {
    #expect(PortsParser.decode(0x0A01_912C) == .fixed(volts: 5, amps: 3))
    #expect(PortsParser.decode(0x0006_4145) == .fixed(volts: 20, amps: 3.25))
    #expect(PortsParser.decode(0xC1A4_213C) == .programmable(minVolts: 3.3, maxVolts: 21, amps: 3))
    #expect(PortsParser.decode(0) == nil)
    #expect(PowerOffer.fixed(volts: 20, amps: 3.25).maxWatts == 65)
}

@Test func shortfallAlertNeedsMeasuredInputAndADrainingBattery() {
    func charger(input: Double?, battery: Double) -> ChargerSample {
        ChargerSample(
            state: .charging, description: nil, advertisedWatts: 30, offers: [], selectedVolts: 20, selectedAmps: 1.5,
            inputWatts: input, inputVolts: nil, inputAmps: nil, systemWatts: 45, batteryWatts: battery, conversionLossWatts: nil
        )
    }
    #expect(PortAlerts.chargerShortfall(charger(input: 29, battery: -16))
        == "The 30 W charger can't keep up: the Mac is using 45.0 W, so the battery is draining.")
    // Just plugged in: input not measured yet, so no alarm.
    #expect(PortAlerts.chargerShortfall(charger(input: nil, battery: -3)) == nil)
    #expect(PortAlerts.chargerShortfall(charger(input: 60, battery: 15)) == nil)
}
