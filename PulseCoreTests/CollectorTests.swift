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
    #expect(MetricID.cpu == MetricID(rawValue: "cpu"))
    #expect(MetricID.cpu != MetricID.memory)
}

@Test func liveCollectorsReadThisMachine() async throws {
    let cpu = CPUCollector()
    _ = try await cpu.sample()
    try await Task.sleep(for: .milliseconds(100))
    let sample = try await cpu.sample()
    #expect(!sample.cores.isEmpty)
    #expect((0...1).contains(sample.total))

    let memory = try await MemoryCollector().sample()
    #expect(memory.totalBytes > 0)
    #expect(memory.usedBytes <= memory.totalBytes)

    let disk = try await DiskCollector().sample()
    #expect(disk.totalBytes > 0)

    #expect(try await NetworkCollector().sample().downBytesPerSecond >= 0)
    #expect(try await ProcessCollector().sample().unreadableCount >= 0)
}
