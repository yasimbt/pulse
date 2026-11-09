import Foundation

/// Fractions are 0...1. Rates are bytes per second. Sizes are bytes.
public struct CoreLoad: Sendable, Equatable {
    public let index: Int
    public let clusterName: String
    public let usage: Double
}

public struct ClusterLoad: Sendable, Equatable {
    public let name: String
    public let coreCount: Int
    public let usage: Double
}

public struct CPUSample: Sendable, Equatable {
    public let user: Double
    public let system: Double
    public let cores: [CoreLoad]
    public let clusters: [ClusterLoad]

    public var total: Double { user + system }
}

public struct MemorySample: Sendable, Equatable {
    public enum Pressure: Int, Sendable { case normal = 1, warning = 2, critical = 4 }

    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: Pressure?

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }
}

public struct DiskSample: Sendable, Equatable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public var usedFraction: Double {
        guard totalBytes > 0, availableBytes <= totalBytes else { return 0 }
        return Double(totalBytes - availableBytes) / Double(totalBytes)
    }
}

public struct InterfaceThroughput: Sendable, Equatable {
    public let name: String
    public let downBytesPerSecond: Double
    public let upBytesPerSecond: Double
}

public struct NetworkSample: Sendable, Equatable {
    public let interfaces: [InterfaceThroughput]
    public let downBytesPerSecond: Double
    public let upBytesPerSecond: Double
}

public struct BatterySample: Sendable, Equatable {
    public let chargeFraction: Double
    public let isCharging: Bool
    public let isExternalPowerConnected: Bool
    public let isFullyCharged: Bool
    public let cycleCount: Int?
    public let voltageVolts: Double?
    public let currentAmps: Double?
    /// Present capacity relative to design capacity. Can slightly exceed 1 on a new pack.
    public let healthFraction: Double?
    /// Not exposed on every chip; nil on the M5.
    public let temperatureCelsius: Double?
    public let timeRemainingSeconds: Double?

    /// Positive while charging, negative while discharging.
    public var powerWatts: Double? {
        guard let voltageVolts, let currentAmps else { return nil }
        return voltageVolts * currentAmps
    }
}

public struct ProcessUsage: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    /// 1.0 means one full core, matching Activity Monitor.
    public let cpuCores: Double
    public let footprintBytes: UInt64
    public let diskReadBytesPerSecond: Double
    public let diskWriteBytesPerSecond: Double
    /// Apple's per-process energy estimate, averaged over the interval.
    public let energyWatts: Double
}

public struct ProcessTable: Sendable, Equatable {
    public let byCPU: [ProcessUsage]
    public let byMemory: [ProcessUsage]
    public let byDisk: [ProcessUsage]
    public let byEnergy: [ProcessUsage]
    /// Processes owned by other users, which cannot be read without privileges.
    public let unreadableCount: Int
}

public struct NetworkProcessUsage: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let downBytesPerSecond: Double
    public let upBytesPerSecond: Double
}

public struct SelfUsage: Sendable, Equatable {
    public let cpuCores: Double
    public let averageCPUCores: Double
    public let footprintBytes: UInt64
}

public struct Snapshot: Sendable, Equatable {
    public var timestamp: Date
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var disk: DiskSample?
    public var network: NetworkSample?
    public var battery: BatterySample?
    public var processes: ProcessTable?
    public var networkProcesses: [NetworkProcessUsage]?
    public var selfUsage: SelfUsage?
    public var power: PowerSample?
    public var thermal: ThermalSample?
    public var smc: SMCSample?

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
