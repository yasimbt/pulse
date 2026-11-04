import Darwin

public actor NetworkCollector: Collector {
    public nonisolated let id = MetricID.network
    private let clock = ContinuousClock()
    private var previous: (counters: [InterfaceCounters], time: ContinuousClock.Instant)?

    public init() {}

    public func sample() throws -> NetworkSample {
        let now = clock.now
        let counters = try Self.readCounters()
        defer { previous = (counters, now) }
        guard let previous else {
            return NetworkCalculations.sample(previous: counters, current: counters, seconds: 0)
        }
        return NetworkCalculations.sample(previous: previous.counters, current: counters, seconds: Rates.seconds(now - previous.time))
    }

    /// `NET_RT_IFLIST2` has 64-bit counters, unlike the 32-bit `if_data` from `getifaddrs`.
    private static func readCounters() throws -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
            throw CollectorError.unavailable("NET_RT_IFLIST2 size failed")
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            throw CollectorError.unavailable("NET_RT_IFLIST2 read failed")
        }
        return buffer.withUnsafeBytes { raw in
            RouteMessageParser.parse(UnsafeRawBufferPointer(rebasing: raw[..<length])) { index in
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                return if_indextoname(UInt32(index), &name) == nil ? nil : String(cString: name)
            }
        }
    }
}
