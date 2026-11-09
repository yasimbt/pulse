// Spike: what throttling looks like on this Mac. Prints one CSV row per second with load,
// cluster frequencies and watts, chip temperature and macOS's thermal state, through idle, a
// sustained all-core load, and cool-down. Run by run.sh.
import Foundation
import PulseCore

@main
struct Throttle {
    static func main() async throws {
        let seconds = Int(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
        let cpu = CPUCollector(), power = PowerCollector(), temperature = TemperatureCollector()
        await power.setDetail(true)
        _ = try await cpu.sample()
        _ = try await power.sample()
        print("t,cpu,e_active,p_active,e_mhz,p_mhz,e_w,p_w,cpu_w,chip_hot_c,chip_avg_c,thermal_state")
        let start = Date()
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            let load = try await cpu.sample()
            let watts = try await power.sample()
            let heat = try? await temperature.sample()
            let e = watts.cluster(.efficiency), p = watts.cluster(.performance)
            func number(_ value: Double?, _ digits: Int = 2) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "" }
            let state = switch ProcessInfo.processInfo.thermalState {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious"
            case .critical: "critical"
            @unknown default: "unknown"
            }
            print([
                String(Int(Date().timeIntervalSince(start))), number(load.total), number(e?.activeFraction), number(p?.activeFraction),
                number(e?.frequencyHz.map { $0 / 1e6 }, 0), number(p?.frequencyHz.map { $0 / 1e6 }, 0),
                number(e?.watts), number(p?.watts), number(watts.cpuWatts),
                number(heat?.reading("chipHottest")?.celsius, 1), number(heat?.reading("chipAverage")?.celsius, 1), state
            ].joined(separator: ","))
        }
    }
}
