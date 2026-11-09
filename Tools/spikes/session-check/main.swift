// M4 acceptance: records a session with Pulse's own Sampler and SessionRecorder, as the app does,
// then prints the summary and checks the integrated energy against the Mac's cumulative counter.
// Usage: session-check SECONDS. run.sh adds a heavy load in the middle.
import Foundation
import PulseCore

@main
struct SessionCheck {
    static func main() async throws {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "300") ?? 300
        let sampler = Sampler(
            interval: 1,
            demand: Sampler.Demand(modules: Set(ModuleKind.allCases), processes: true, powerDetail: true)
        )
        let recorder = SessionRecorder(database: try HistoryDatabase.inMemory())
        await sampler.start()
        var firstTotal: Double?
        var lastTotal: Double?
        var sessionStart: Date?
        for await snapshot in sampler.snapshots {
            // The first published snapshot may lack detail while the collectors warm up.
            guard let total = snapshot.power?.energySinceBootJoules else { continue }
            guard let start = sessionStart else {
                await recorder.start(name: "Acceptance", at: snapshot.timestamp)
                sessionStart = snapshot.timestamp
                firstTotal = total
                continue
            }
            await recorder.record(snapshot)
            lastTotal = total
            if snapshot.timestamp.timeIntervalSince(start) >= seconds { break }
        }
        await sampler.stop()
        guard let session = try await recorder.stop() else { return }
        let summary = session.summary
        print("samples: \(session.samples.count), duration: \(MetricFormat.clock(summary.duration))")
        for row in rows(summary) { print("  \(row)") }
        print("  throttle periods:", summary.throttlePeriods.map {
            "\(Int($0.start.timeIntervalSince(summary.start)))-\(Int($0.end.timeIntervalSince(summary.start))) s"
        })
        print("  top processes:", summary.topProcesses.map { "\($0.name) \(Int($0.cpuSeconds)) CPU-s" })
        if let first = firstTotal, let last = lastTotal {
            let counter = last - first
            print(String(format: "energy check: summed %.1f J, cumulative counter %.1f J, difference %+.2f%%",
                         summary.energyJoules, counter, (summary.energyJoules / counter - 1) * 100))
        }
    }

    static func rows(_ summary: SessionSummary) -> [String] {
        func stat(_ value: Stat?, _ format: (Double) -> String) -> String {
            value.map { "\(format($0.average)) avg, \(format($0.peak)) peak" } ?? "not measured"
        }
        return [
            "CPU usage: \(stat(summary.cpuUsage, MetricFormat.percent))",
            "GPU usage: \(stat(summary.gpuUsage, MetricFormat.percent))",
            "CPU power: \(stat(summary.cpuWatts, MetricFormat.watts))",
            "GPU power: \(stat(summary.gpuWatts, MetricFormat.watts))",
            "Whole Mac: \(stat(summary.systemWatts, MetricFormat.watts))",
            "Energy CPU+GPU: \(MetricFormat.energy(joules: summary.energyJoules))",
            "Energy whole Mac: \(summary.systemEnergyJoules.map { MetricFormat.energy(joules: $0) } ?? "-")",
            "Hottest chip: \(summary.peakChipCelsius.map(MetricFormat.temperature) ?? "-")",
            "Worst thermal state: \(summary.worstThermalState.map { "\($0)" } ?? "-")",
            "Throttled: \(MetricFormat.clock(summary.throttledSeconds))"
        ]
    }
}
