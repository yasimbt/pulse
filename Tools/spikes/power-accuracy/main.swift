// Accuracy check helper: reads Pulse's own PowerCollector, or runs a GPU load.
//   pulse-power measure S   average CPU, GPU and cluster watts over S one-second samples
//   pulse-power gpu-load S  keep the GPU busy with a Metal compute kernel for S seconds
// Built and run by run.sh.
import Foundation
import Metal
import PulseCore

@main
struct PulsePower {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let seconds = Double(arguments.dropFirst().first ?? "15") ?? 15
        switch arguments.first {
        case "measure": try await measure(seconds: Int(seconds))
        case "gpu-load": try gpuLoad(seconds: seconds)
        default: print("usage: pulse-power measure|gpu-load SECONDS")
        }
    }

    /// Detail on, as when the Power panel is open: every sample is a fresh one-second reading.
    static func measure(seconds: Int) async throws {
        let collector = PowerCollector()
        await collector.setDetail(true)
        _ = try await collector.sample()
        var cpu: [Double] = [], gpu: [Double] = [], efficiency: [Double] = [], performance: [Double] = []
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            let sample = try await collector.sample()
            cpu.append(sample.cpuWatts ?? .nan)
            gpu.append(sample.gpuWatts ?? .nan)
            efficiency.append(sample.cluster(.efficiency)?.watts ?? .nan)
            performance.append(sample.cluster(.performance)?.watts ?? .nan)
        }
        func mean(_ values: [Double]) -> String { String(format: "%.3f", values.reduce(0, +) / Double(values.count)) }
        print("pulse_cpu=\(mean(cpu)) pulse_gpu=\(mean(gpu)) pulse_e=\(mean(efficiency)) pulse_p=\(mean(performance))")
    }

    /// A long arithmetic loop per thread, dispatched repeatedly until time runs out.
    static func gpuLoad(seconds: Double) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id);
            for (int i = 0; i < 20000; i++) { x = fma(x, 1.000001f, 0.5f); x = sin(x); }
            out[id] = x;
        }
        """
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "pulse-power", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "spin")!)
        let count = 1 << 20
        let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModePrivate)!
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let commands = queue.makeCommandBuffer()!
            let encoder = commands.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
            )
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
    }
}
