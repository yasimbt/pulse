public enum Rates {
    /// Bytes per second from two cumulative counters. A counter that went backwards was
    /// reset (interface restart, process replaced), so it reports 0 rather than a huge value.
    public static func perSecond(current: UInt64, previous: UInt64, seconds: Double) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    public static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

public enum MemoryCalculations {
    public struct PageCounts: Sendable, Equatable {
        public let `internal`: UInt64
        public let purgeable: UInt64
        public let wired: UInt64
        public let compressor: UInt64

        public init(internal: UInt64, purgeable: UInt64, wired: UInt64, compressor: UInt64) {
            self.internal = `internal`
            self.purgeable = purgeable
            self.wired = wired
            self.compressor = compressor
        }
    }

    /// Activity Monitor's model: Memory Used = App Memory + Wired + Compressed,
    /// where App Memory is internal pages minus purgeable pages.
    public static func breakdown(pages: PageCounts, pageSize: UInt64) -> (app: UInt64, wired: UInt64, compressed: UInt64) {
        let appPages = pages.internal > pages.purgeable ? pages.internal - pages.purgeable : 0
        return (appPages * pageSize, pages.wired * pageSize, pages.compressor * pageSize)
    }
}
