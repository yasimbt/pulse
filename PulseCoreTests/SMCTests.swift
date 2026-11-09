@testable import PulseCore
import Testing

@Test func smcValuesDecodeByType() {
    // PSTR on the M5 at idle: 3.292 W as a little-endian float.
    let float = SMCValue(type: "flt ", bytes: [0x21, 0xB0, 0x52, 0x40])
    #expect(abs((float.number ?? 0) - 3.292) < 0.001)
    // Intel fan speeds: big-endian fixed point with two fraction bits. 0x1f40 / 4 = 2000 rpm.
    #expect(SMCValue(type: "fpe2", bytes: [0x1F, 0x40]).number == 2000)
    #expect(SMCValue(type: "ui8 ", bytes: [2]).number == 2)
    #expect(SMCValue(type: "ui16", bytes: [0x09, 0x80]).number == 2432)
    #expect(SMCValue(type: "flag", bytes: [1]).number == nil)
    #expect(SMCValue(type: "flt ", bytes: [1, 2]).number == nil)
}

@Test func smcKeyCodesRoundTrip() {
    #expect(SMCValue.code("PSTR") == 0x5053_5452)
    #expect(SMCValue.text(0x5053_5452) == "PSTR")
}

@Test func liveSMCReadsSystemPower() async throws {
    let sample = try await SMCCollector().sample()
    let watts = try #require(sample.systemWatts)
    #expect(watts > 0 && watts < 200)
}
