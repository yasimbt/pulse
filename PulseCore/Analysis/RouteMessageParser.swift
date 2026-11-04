import Darwin

public struct InterfaceCounters: Sendable, Equatable {
    public let name: String
    public let isUp: Bool
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(name: String, isUp: Bool, receivedBytes: UInt64, sentBytes: UInt64) {
        self.name = name
        self.isUp = isUp
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public enum RouteMessageParser {
    /// Parses a `NET_RT_IFLIST2` buffer.
    ///
    /// Every routing message begins with a u16 length, u8 version, and u8 type. Other message
    /// types can be shorter than `if_msghdr2`, so only the common header is read before the
    /// type is known.
    public static func parse(_ bytes: UnsafeRawBufferPointer, nameForIndex: (UInt16) -> String?) -> [InterfaceCounters] {
        var result: [InterfaceCounters] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length > 0, offset + length <= bytes.count else { break }

            if Int32(bytes[offset + 3]) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if let name = nameForIndex(message.ifm_index) {
                    result.append(InterfaceCounters(
                        name: name,
                        isUp: message.ifm_flags & IFF_UP != 0,
                        receivedBytes: message.ifm_data.ifi_ibytes,
                        sentBytes: message.ifm_data.ifi_obytes
                    ))
                }
            }
            offset += length
        }
        return result
    }
}

public enum NetworkCalculations {
    /// Totals count `en*` only. Loopback carries no real traffic, and tunnels such as `utun`
    /// would count VPN traffic twice because it also crosses the physical interface.
    public static func isCountedInTotal(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    public static func sample(previous: [InterfaceCounters], current: [InterfaceCounters], seconds: Double) -> NetworkSample {
        let before = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var interfaces: [InterfaceThroughput] = []
        var down = 0.0, up = 0.0

        for now in current where now.isUp && now.name != "lo0" {
            guard let old = before[now.name] else { continue }
            let rateDown = Rates.perSecond(current: now.receivedBytes, previous: old.receivedBytes, seconds: seconds)
            let rateUp = Rates.perSecond(current: now.sentBytes, previous: old.sentBytes, seconds: seconds)
            if now.receivedBytes + now.sentBytes > 0 {
                interfaces.append(InterfaceThroughput(name: now.name, downBytesPerSecond: rateDown, upBytesPerSecond: rateUp))
            }
            if isCountedInTotal(now.name) {
                down += rateDown
                up += rateUp
            }
        }
        return NetworkSample(interfaces: interfaces, downBytesPerSecond: down, upBytesPerSecond: up)
    }
}
