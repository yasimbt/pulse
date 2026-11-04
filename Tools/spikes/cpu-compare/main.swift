// Spike: compare CPUCollector with `top` over the same 5 s windows.
// Build: swiftc -parse-as-library -o /tmp/cpucmp Tools/spikes/cpu-compare/main.swift \
//   PulseCore/Analysis/*.swift PulseCore/Collectors/*.swift PulseCore/Models/*.swift PulseCore/Sampling/*.swift
import Foundation

func topBusy() throws -> Double {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    process.arguments = ["-l", "2", "-n", "0", "-s", "5"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let line = text.split(separator: "\n").last { $0.hasPrefix("CPU usage") } ?? ""
    let idle = line.split(separator: ",").last?.split(separator: "%").first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? "0"
    return 100 - (Double(idle) ?? 0)
}

@main
struct Compare {
    static func main() async throws {
        let cpu = CPUCollector()
        for _ in 0..<3 {
            _ = try await cpu.sample()
            let top = try topBusy()
            let sample = try await cpu.sample()
            let clusters = sample.clusters.map { "\($0.name)=\(String(format: "%.0f", $0.usage * 100))%" }.joined(separator: " ")
            print(String(format: "pulse %5.1f%%  top %5.1f%%  diff %+.1f  ", sample.total * 100, top, sample.total * 100 - top) + clusters)
        }
    }
}
