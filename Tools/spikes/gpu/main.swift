// Spike: GPU utilisation, memory and per-process GPU time from the IORegistry, next to Pulse's
// IOReport GPU readings. See docs/gpu-findings.md.
//   gpu-spike watch S [DUTY]  one line per second for S seconds; with DUTY (0...1), this process
//                             keeps the GPU busy that share of each 100 ms, as a known reference
//   gpu-spike bench           cost of each read, averaged
//   gpu-spike dump FILE       raw values as JSON, for test fixtures
//   gpu-spike watch S D P     the same with a P-second load period (default 0.1)
//   gpu-spike cadence [DUTY]  Device Utilization every 50 ms under a load with a 1 s period
//   gpu-spike clients [FILE]  this process's clients while it opens and closes Metal command
//                             queues, to see how per-queue counters come and go
// Built and run by run.sh.
import Foundation
import IOKit
import Metal
import PulseCore

// MARK: - IORegistry

/// The GPU's accelerator service. Released by the caller.
func accelerator() -> io_service_t? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    return service == 0 ? nil : service
}

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

struct Client {
    let id: UInt64
    let creator: String
    let usage: [[String: Any]]
    var pid: Int32? { creator.split(separator: ",").first.flatMap { Int32($0.dropFirst(4)) } }
    var name: String { creator.split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?" }
    var gpuTime: Int64 { usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.int64Value ?? 0) } }
}

/// The accelerator's user clients: one per open connection to the GPU.
func clients(_ service: io_service_t) -> [Client] {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [Client] = []
    while case let child = IOIteratorNext(iterator), child != 0 {
        defer { IOObjectRelease(child) }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(child, &id)
        guard let creator = property(child, "IOUserClientCreator") as? String else { continue }
        result.append(Client(id: id, creator: creator, usage: property(child, "AppUsage") as? [[String: Any]] ?? []))
    }
    return result
}

func statistics(_ service: io_service_t) -> [String: Any] {
    property(service, "PerformanceStatistics") as? [String: Any] ?? [:]
}

func microseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
}

// MARK: - GPU load

/// Keeps the GPU busy for `duty` of every 100 ms by submitting short kernels back to back.
final class GPULoad: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer

    init(device: MTLDevice) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id);
            for (int i = 0; i < 400; i++) { x = fma(x, 1.000001f, 0.5f); x = sin(x); }
            out[id] = x;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "spin")!)
        queue = device.makeCommandQueue()!
        buffer = device.makeBuffer(length: 1 << 22, options: .storageModePrivate)!
    }

    func run(duty: Double, period: Double = 0.1, until end: Date) {
        while Date() < end {
            let start = Date()
            while Date().timeIntervalSince(start) < period * duty {
                let commands = queue.makeCommandBuffer()!
                let encoder = commands.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(MTLSize(width: 1 << 20, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
            }
            let rest = period - Date().timeIntervalSince(start)
            if rest > 0 { Thread.sleep(forTimeInterval: rest) }
        }
    }
}

// MARK: - Commands

@main
struct GPUSpike {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let service = accelerator() else { print("no IOAccelerator"); exit(1) }
        defer { IOObjectRelease(service) }
        switch arguments.first {
        case "watch":
            try await watch(
                service, seconds: Int(arguments.dropFirst().first ?? "10") ?? 10, duty: arguments.dropFirst(2).first.flatMap(Double.init),
                period: arguments.dropFirst(3).first.flatMap(Double.init) ?? 0.1
            )
        case "bench": bench(service)
        case "cadence": cadence(service, duty: arguments.dropFirst().first.flatMap(Double.init) ?? 0.5)
        case "dump": try dump(service, to: arguments.dropFirst().first ?? "gpu.json")
        case "clients": try clientChurn(service, to: arguments.dropFirst().first)
        default: print("usage: gpu-spike watch S [DUTY [PERIOD]] | cadence [DUTY] | bench | dump FILE | clients [FILE]")
        }
    }

    static func watch(_ service: io_service_t, seconds: Int, duty: Double?, period: Double) async throws {
        print("model \(property(service, "model") ?? "?"), \(property(service, "gpu-core-count") ?? "?") cores")
        if let duty, let device = MTLCreateSystemDefaultDevice() {
            let load = try GPULoad(device: device)
            let end = Date().addingTimeInterval(Double(seconds) + 2)
            Thread.detachNewThread { load.run(duty: duty, period: period, until: end) }
            print("load: this process, duty \(duty), period \(period) s")
        }
        let power = PowerCollector()
        await power.setDetail(true)
        _ = try await power.sample()
        let me = ProcessInfo.processInfo.processIdentifier
        let clock = ContinuousClock()
        var previous = Dictionary(uniqueKeysWithValues: clients(service).map { ($0.id, $0.gpuTime) })
        var last = clock.now
        print("  dev  rend tiler | inuseMB allocMB | GPUPH  MHz    W | self   sum  | top")
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            let stats = statistics(service)
            let current = clients(service)
            let now = clock.now
            let wall = microseconds(now - last) * 1000 // ns
            last = now
            var perPID: [Int32: (name: String, ns: Double)] = [:]
            for client in current {
                // A client seen for the first time contributes nothing.
                let delta = previous[client.id].map { Double(client.gpuTime - $0) } ?? 0
                guard let pid = client.pid else { continue }
                perPID[pid, default: (client.name, 0)].ns += max(0, delta)
            }
            previous = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.gpuTime) })
            let sample = try await power.sample()
            func percent(_ key: String) -> String { String(format: "%4d", (stats[key] as? NSNumber)?.intValue ?? -1) }
            func megabytes(_ key: String) -> String { String(format: "%7.0f", ((stats[key] as? NSNumber)?.doubleValue ?? 0) / 1e6) }
            let top = perPID.sorted { $0.value.ns > $1.value.ns }.prefix(3)
                .map { String(format: "%@ %.3f", $0.value.name, $0.value.ns / wall) }.joined(separator: ", ")
            print(String(
                format: "%@ %@ %@ | %@ %@ | %5.3f %4.0f %5.2f | %.3f %.3f | %@",
                percent("Device Utilization %"), percent("Renderer Utilization %"), percent("Tiler Utilization %"),
                megabytes("In use system memory"), megabytes("Alloc system memory"),
                sample.gpuActiveFraction ?? -1, (sample.gpuFrequencyHz ?? 0) / 1e6, sample.gpuWatts ?? -1,
                (perPID[me]?.ns ?? 0) / wall, perPID.values.reduce(0) { $0 + $1.ns } / wall, top
            ))
        }
    }

    /// Device Utilization every 50 ms for 4 s under a load with a 1 s period, to see how often the
    /// driver updates it and how it rises and decays.
    static func cadence(_ service: io_service_t, duty: Double) {
        let load = try! GPULoad(device: MTLCreateSystemDefaultDevice()!)
        let end = Date().addingTimeInterval(4.5)
        Thread.detachNewThread { load.run(duty: duty, period: 1, until: end) }
        let start = Date()
        var line: [String] = []
        while Date() < end {
            line.append("\((statistics(service)["Device Utilization %"] as? NSNumber)?.intValue ?? -1)")
            if line.count == 20 {
                print(String(format: "%4.1fs ", Date().timeIntervalSince(start) - 1) + line.joined(separator: " "))
                line = []
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func bench(_ service: io_service_t) {
        let clock = ContinuousClock()
        let count = 200
        var cost = clock.measure { for _ in 0..<count { _ = statistics(service) } }
        print(String(format: "PerformanceStatistics, one property: %.1f µs", microseconds(cost) / Double(count)))
        cost = clock.measure {
            for _ in 0..<count {
                var properties: Unmanaged<CFMutableDictionary>?
                IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                properties?.release()
            }
        }
        print(String(format: "all accelerator properties: %.1f µs", microseconds(cost) / Double(count)))
        cost = clock.measure { for _ in 0..<count { _ = accelerator().map(IOObjectRelease) } }
        print(String(format: "matching the service: %.1f µs", microseconds(cost) / Double(count)))
        let walk = clock.measure { for _ in 0..<20 { _ = clients(service) } }
        print(String(format: "user-client walk (%d clients): %.1f µs", clients(service).count, microseconds(walk) / 20))
    }

    static func dump(_ service: io_service_t, to path: String) throws {
        let object: [String: Any] = [
            "model": property(service, "model") ?? NSNull(),
            "gpu-core-count": property(service, "gpu-core-count") ?? NSNull(),
            "PerformanceStatistics": statistics(service),
            "clients": clients(service).map(json)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    /// This process's clients at each step while Metal objects are created and released. Prints
    /// them and, with a path, writes the steps as JSON for a fixture.
    static func clientChurn(_ service: io_service_t, to path: String?) throws {
        let me = ProcessInfo.processInfo.processIdentifier
        var steps: [[String: Any]] = []
        func step(_ name: String) {
            let mine = clients(service).filter { $0.pid == me }
            print(name.padding(toLength: 16, withPad: " ", startingAt: 0) + mine.map { "\($0.id): \($0.usage.count) queues, \($0.gpuTime) ns" }.joined(separator: "; "))
            steps.append(["step": name, "clients": mine.map(json)])
        }
        step("start")
        var device: MTLDevice? = MTLCreateSystemDefaultDevice()
        step("device")
        var load: GPULoad? = try GPULoad(device: device!)
        load?.run(duty: 1, until: Date().addingTimeInterval(1))
        step("queue + work")
        var second: GPULoad? = try GPULoad(device: device!)
        second?.run(duty: 1, until: Date().addingTimeInterval(1))
        step("second queue")
        second = nil
        Thread.sleep(forTimeInterval: 0.5)
        step("second freed")
        load = nil
        device = nil
        Thread.sleep(forTimeInterval: 0.5)
        step("all freed")
        if let path {
            let data = try JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }

    static func json(_ client: Client) -> [String: Any] {
        ["id": client.id, "IOUserClientCreator": client.creator, "AppUsage": client.usage]
    }
}
