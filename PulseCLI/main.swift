// pulse-cli: Pulse's metrics in the terminal.
//
//   pulse-cli                 a readable summary
//   pulse-cli --json          JSON
//   pulse-cli --prometheus    Prometheus text format
//   pulse-cli --watch [N]     repeat every N seconds (default 2) until Ctrl-C
import Foundation
import PulseCore

enum Output { case text, json, prometheus }

struct Options {
    var output = Output.text
    var watch: Double?

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": options.output = .json
            case "--prometheus": options.output = .prometheus
            case "--watch":
                options.watch = 2
                if index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) {
                    options.watch = max(0.5, seconds)
                    index += 1
                }
            case "--help", "-h": return nil
            default:
                FileHandle.standardError.write(Data("pulse-cli: unknown option \(arguments[index])\n".utf8))
                return nil
            }
            index += 1
        }
        return options
    }

    static let usage = """
    usage: pulse-cli [--json | --prometheus] [--watch [seconds]]
      Prints this Mac's metrics: CPU, memory, disk, network, battery, power, temperatures.
      --json         JSON, in SI units
      --prometheus   Prometheus text format
      --watch [N]    repeat every N seconds (default 2) until Ctrl-C

    """
}

/// A readable line per metric, such as "CPU usage  25%".
func text(_ snapshot: Snapshot) -> String {
    MetricsExport.metrics(snapshot).map { metric in
        let label = metric.labels.isEmpty ? "" : " (" + metric.labels.keys.sorted().map { metric.labels[$0] ?? "" }.joined(separator: ", ") + ")"
        let name = metric.name.replacingOccurrences(of: "pulse_", with: "") + label
        let value: String = switch true {
        case metric.name.hasSuffix("_ratio"): MetricFormat.precisePercent(metric.value)
        case metric.name.hasSuffix("_bytes_per_second"): MetricFormat.rate(metric.value)
        // Memory in 1024-based units, as Activity Monitor shows it; disk in 1000-based, as Finder does.
        case metric.name.hasSuffix("_bytes") && (metric.name.contains("memory") || metric.name.contains("swap")):
            MetricFormat.memory(metric.value)
        case metric.name.hasSuffix("_bytes"): MetricFormat.bytes(metric.value)
        case metric.name.hasSuffix("_watts"): MetricFormat.watts(metric.value)
        case metric.name.hasSuffix("_celsius"): MetricFormat.temperature(metric.value)
        case metric.name.hasSuffix("_hertz"): MetricFormat.frequency(metric.value)
        // Counts, such as battery cycles.
        default: String(Int(metric.value.rounded()))
        }
        return name.padding(toLength: 40, withPad: " ", startingAt: 0) + value
    }
    .joined(separator: "\n") + "\n"
}

func render(_ snapshot: Snapshot, as output: Output) -> String {
    switch output {
    case .text: return text(snapshot)
    case .prometheus: return MetricsExport.prometheus(snapshot)
    case .json: return ((try? MetricsExport.json(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? "{}") + "\n"
    }
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data(Options.usage.utf8))
    exit(CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") ? 0 : 2)
}

// Rates need two readings, so the first result comes after one interval.
let sampler = Sampler(
    interval: options.watch ?? 1,
    demand: Sampler.Demand(modules: Set(ModuleKind.allCases), powerDetail: true)
)
await sampler.start()
for await snapshot in sampler.snapshots {
    print(render(snapshot, as: options.output), terminator: "")
    guard options.watch != nil else { break }
    if options.output == .text { print("") }
    // Output to a pipe is buffered; each update should reach the reader as it's printed.
    fflush(stdout)
}
await sampler.stop()
