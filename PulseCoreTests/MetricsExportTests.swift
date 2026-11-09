import Foundation
@testable import PulseCore
import Testing

private func snapshot() -> Snapshot {
    var snapshot = Snapshot(timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    snapshot.cpu = CPUSample(user: 0.2, system: 0.05, cores: [], clusters: [ClusterLoad(name: "Super", coreCount: 4, usage: 0.5)])
    snapshot.power = PowerSample(cpuWatts: 12.5, clusters: [], gpuWatts: 0.25, aneWatts: nil, gpuActiveFraction: nil, gpuFrequencyHz: nil)
    snapshot.thermal = ThermalSample(readings: [TemperatureReading(id: "chipHottest", title: "Chip, hottest", celsius: 61)])
    return snapshot
}

@Test func prometheusTextHasHelpTypeAndLabels() {
    let text = MetricsExport.prometheus(snapshot())
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.contains("# TYPE pulse_cpu_usage_ratio gauge"))
    #expect(lines.contains("pulse_cpu_usage_ratio 0.25"))
    #expect(lines.contains("pulse_cpu_cluster_usage_ratio{cluster=\"Super\"} 0.5"))
    #expect(lines.contains("pulse_power_watts{component=\"cpu\"} 12.5"))
    #expect(lines.contains("pulse_temperature_celsius{sensor=\"chipHottest\"} 61"))
    // HELP and TYPE once per metric, even with several labelled values.
    #expect(lines.filter { $0 == "# TYPE pulse_power_watts gauge" }.count == 1)
    // Nothing for metrics the snapshot doesn't have.
    #expect(!text.contains("pulse_memory"))
}

@Test func jsonGroupsValuesByMetric() throws {
    let object = try #require(try JSONSerialization.jsonObject(with: MetricsExport.json(snapshot())) as? [String: Any])
    #expect(object["time"] as? String == "2027-01-15T08:00:00Z")
    let metrics = try #require(object["metrics"] as? [String: [[String: Any]]])
    #expect(metrics["pulse_cpu_usage_ratio"]?.first?["value"] as? Double == 0.25)
    #expect(metrics["pulse_power_watts"]?.count == 2)
}

@Test func labelValuesAreEscaped() {
    #expect(MetricsExport.escape("a\"b\\c") == "a\\\"b\\\\c")
    #expect(MetricsExport.number(61) == "61")
    #expect(MetricsExport.number(0.25) == "0.25")
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func serverRoutesRequests() {
    let prometheus = text(MetricsServer.response(to: "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n", snapshot: snapshot()))
    #expect(prometheus.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4"))
    #expect(prometheus.contains("pulse_cpu_usage_ratio 0.25"))
    let json = text(MetricsServer.response(to: "GET /metrics.json?pretty HTTP/1.1\r\n\r\n", snapshot: snapshot()))
    #expect(json.contains("Content-Type: application/json") && json.contains("\"pulse_cpu_usage_ratio\""))
    #expect(text(MetricsServer.response(to: "GET / HTTP/1.1\r\n\r\n", snapshot: snapshot())).hasPrefix("HTTP/1.1 404"))
    #expect(text(MetricsServer.response(to: "POST /metrics HTTP/1.1\r\n\r\n", snapshot: snapshot())).hasPrefix("HTTP/1.1 405"))
    #expect(text(MetricsServer.response(to: "garbage", snapshot: snapshot())).hasPrefix("HTTP/1.1 400"))
    #expect(text(MetricsServer.response(to: "GET /metrics HTTP/1.1\r\n\r\n", snapshot: nil)).hasPrefix("HTTP/1.1 503"))
    // HEAD: headers with the body's length, but no body.
    let head = text(MetricsServer.response(to: "HEAD /metrics HTTP/1.1\r\n\r\n", snapshot: snapshot()))
    #expect(head.hasSuffix("\r\n\r\n") && !head.contains("pulse_cpu"))
}

@Test func serverAnswersOnLoopback() async throws {
    let server = MetricsServer()
    let port: UInt16 = 19466
    try await server.start(port: port)
    await server.update(snapshot())
    try await Task.sleep(for: .milliseconds(200))
    let (data, response) = try await URLSession.shared.data(from: try #require(URL(string: "http://127.0.0.1:\(port)/metrics")))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(text(data).contains("pulse_power_watts{component=\"cpu\"} 12.5"))
    await server.stop()
}
