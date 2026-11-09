import Foundation
import IOKit

/// A read-only connection to the SMC (System Management Controller) through the AppleSMC driver.
/// Needs no root for reads. Not thread-safe: own it from one actor. See `Tools/spikes/smc`.
final class SMCConnection {
    /// Matches the C struct `SMCKeyData_t` (80 bytes) that the AppleSMC user client expects.
    private struct KeyData {
        var key: UInt32 = 0
        var version = SMCVersion()
        var limitData = SMCLimitData()
        var keyInfo = SMCKeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case keyInfo = 9
    }

    /// The user client's struct method (`kSMCHandleYPCEvent`).
    private static let selector: UInt32 = 2

    private let connection: io_connect_t

    init() throws {
        guard MemoryLayout<KeyData>.size == 80, MemoryLayout<KeyData>.offset(of: \KeyData.result) == 40 else {
            throw CollectorError.unavailable("SMC struct layout mismatch")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw CollectorError.unavailable("no AppleSMC service") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, machTaskSelf(), 0, &connection) == KERN_SUCCESS else {
            throw CollectorError.unavailable("AppleSMC could not be opened")
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// The key's value, or nil when this Mac doesn't have the key.
    func read(_ key: String) -> SMCValue? {
        var request = KeyData()
        request.key = SMCValue.code(key)
        request.command = Command.keyInfo.rawValue
        guard let info = call(request) else { return nil }
        request.keyInfo.dataSize = info.keyInfo.dataSize
        request.command = Command.readKey.rawValue
        guard var value = call(request) else { return nil }
        let size = min(Int(info.keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: &value.bytes) { Array($0.prefix(size)) }
        return SMCValue(type: SMCValue.text(info.keyInfo.dataType), bytes: bytes)
    }

    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, Self.selector, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }
}

private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
private struct SMCLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }

/// Padded by hand: C rounds this to 12 bytes, but Swift would place the next field straight after
/// its last byte, and the driver then rejects the call as a bad argument.
private struct SMCKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// An SMC key's raw value and its four-character type, such as "flt " or "ui8 ".
public struct SMCValue: Sendable, Equatable {
    public let type: String
    public let bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) {
        self.type = type
        self.bytes = bytes
    }

    /// The value as a number, for the types Pulse reads. Apple Silicon uses little-endian floats;
    /// Intel Macs used big-endian fixed point (`fpe2`) for fan speeds.
    public var number: Double? {
        switch type {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ", "ui16", "ui32":
            return Double(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            return nil
        }
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func text(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "????"
    }
}
