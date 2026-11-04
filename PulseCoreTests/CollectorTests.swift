import PulseCore
import Testing

private struct StubCollector: Collector {
    let id = MetricID(rawValue: "stub")
    let value: Double

    func sample() async throws -> Double {
        value
    }
}

@Test func collectorReturnsItsSample() async throws {
    let collector = StubCollector(value: 1.5)
    #expect(collector.id == MetricID(rawValue: "stub"))
    #expect(try await collector.sample() == 1.5)
}

@Test func metricIDsCompareByRawValue() {
    #expect(MetricID(rawValue: "cpu") == MetricID(rawValue: "cpu"))
    #expect(MetricID(rawValue: "cpu") != MetricID(rawValue: "gpu"))
}
