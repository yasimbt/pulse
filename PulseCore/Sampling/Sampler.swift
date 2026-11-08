import Foundation
import os

/// Drives every collector on a single timer and publishes one immutable `Snapshot` per tick.
public actor Sampler {
    public struct Demand: Sendable, Equatable {
        public var modules: Set<ModuleKind>
        public var processes: Bool
        public var networkProcesses: Bool
        /// The E/P split, frequencies and temperatures, which cost more to read.
        public var powerDetail: Bool

        public init(modules: Set<ModuleKind>, processes: Bool = false, networkProcesses: Bool = false, powerDetail: Bool = false) {
            self.modules = modules
            self.processes = processes
            self.networkProcesses = networkProcesses
            self.powerDetail = powerDetail
        }
    }

    public static let intervalRange: ClosedRange<Double> = 0.5...5
    private static let networkProcessInterval: Duration = .seconds(5)
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "sampler")

    public nonisolated let snapshots: AsyncStream<Snapshot>
    private let continuation: AsyncStream<Snapshot>.Continuation

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let disk = DiskCollector()
    private let network = NetworkCollector()
    private let battery = BatteryCollector()
    private let processes = ProcessCollector()
    private let networkProcesses = NetworkProcessCollector()
    private let selfUsage = SelfUsageCollector()
    private let power = PowerCollector()
    private let temperature = TemperatureCollector()

    private let clock = ContinuousClock()
    private var interval: Double
    private var demand: Demand
    private var task: Task<Void, Never>?
    private var loggedFailures: Set<MetricID> = []
    private var lastNetworkProcesses: (rows: [NetworkProcessUsage], time: ContinuousClock.Instant)?

    public init(interval: Double, demand: Demand) {
        self.interval = interval.clamped(to: Self.intervalRange)
        self.demand = demand
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            // Rates need two readings, so the first pass only sets the baselines.
            _ = await self?.collect()
            while !Task.isCancelled {
                guard let delay = await self?.sleepDelay() else { return }
                // The tolerance lets macOS group this wakeup with others, which saves energy.
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay * 0.1))
                guard let self else { return }
                await self.publish()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    public func setInterval(_ seconds: Double) {
        interval = seconds.clamped(to: Self.intervalRange)
    }

    public func setDemand(_ newDemand: Demand) async {
        let detailChanged = newDemand.powerDetail != demand.powerDetail
        demand = newDemand
        if detailChanged { await power.setDetail(newDemand.powerDetail) }
    }

    private func sleepDelay() -> Double { interval }

    private func publish() async {
        continuation.yield(await collect())
    }

    private func collect() async -> Snapshot {
        var snapshot = Snapshot(timestamp: Date())
        if demand.modules.contains(.cpu) { snapshot.cpu = await attempt(cpu) }
        if demand.modules.contains(.memory) { snapshot.memory = await attempt(memory) }
        if demand.modules.contains(.disk) { snapshot.disk = await attempt(disk) }
        if demand.modules.contains(.network) { snapshot.network = await attempt(network) }
        if demand.modules.contains(.battery) { snapshot.battery = await attempt(battery) }
        if demand.modules.contains(.power) || demand.powerDetail { snapshot.power = await attempt(power) }
        // Shown only in the Power panel for now, so read only while it is open.
        if demand.powerDetail { snapshot.thermal = await attempt(temperature) }
        if demand.processes { snapshot.processes = await attempt(processes) }
        if demand.networkProcesses { snapshot.networkProcesses = await currentNetworkProcesses() }
        snapshot.selfUsage = await attempt(selfUsage)
        return snapshot
    }

    private func currentNetworkProcesses() async -> [NetworkProcessUsage]? {
        let now = clock.now
        if let last = lastNetworkProcesses, now - last.time < Self.networkProcessInterval {
            return last.rows
        }
        guard let rows = await attempt(networkProcesses) else { return nil }
        lastNetworkProcesses = (rows, now)
        return rows
    }

    /// A failing collector returns nil, which hides its metric. Each is logged once.
    private func attempt<C: Collector>(_ collector: C) async -> C.Sample? {
        do {
            return try await collector.sample()
        } catch {
            if loggedFailures.insert(collector.id).inserted {
                Self.logger.error("\(collector.id.rawValue, privacy: .public) unavailable: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
