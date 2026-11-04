import Foundation

/// Runs `nettop`, so the `Sampler` calls this only while the network panel is open.
public actor NetworkProcessCollector: Collector {
    public nonisolated let id = MetricID.networkProcesses
    private let clock = ContinuousClock()
    private var previous: (rows: [NettopRow], time: ContinuousClock.Instant)?

    public init() {}

    public func sample() throws -> [NetworkProcessUsage] {
        let now = clock.now
        let rows = NettopParser.parse(try Self.runNettop())
        defer { previous = (rows, now) }
        guard let previous else { return [] }
        return NettopParser.usages(previous: previous.rows, current: rows, seconds: Rates.seconds(now - previous.time))
    }

    private static func runNettop() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-n"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CollectorError.unavailable("nettop exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
