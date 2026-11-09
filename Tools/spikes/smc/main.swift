// Spike: read the SMC (System Management Controller) through the AppleSMC driver, without root.
// Prints the fan count and fan keys, total system power (PSTR), and every key matching a prefix.
// The SMCKeyData layout and selector follow the long-standing open-source SMC tools (smcFanControl,
// exelban/stats), which mirror Apple's AppleSMC user client.
// Run: swiftc -O -o build/spikes/smc Tools/spikes/smc/main.swift && build/spikes/smc [prefix...]
import Foundation
import IOKit

/// Matches the C struct SMCKeyData_t (80 bytes) that the AppleSMC user client expects.
struct SMCKeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    // Padded by hand: C rounds this struct to 12 bytes, but Swift places the next field right
    // after the last byte, which put `result` at offset 37 instead of 40.
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }

    var key: UInt32 = 0
    var version = Version()
    var limitData = LimitData()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

enum Command: UInt8 {
    case readKey = 5
    case keyFromIndex = 8
    case keyInfo = 9
}

func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func text(_ code: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "????"
}

setvbuf(stdout, nil, _IONBF, 0)
let debug = ProcessInfo.processInfo.environment["SMC_DEBUG"] != nil
print("offsets: keyInfo \(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.keyInfo)!) result \(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.result)!) data8 \(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data8)!) data32 \(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.data32)!) bytes \(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.bytes)!)")
precondition(MemoryLayout<SMCKeyData>.offset(of: \SMCKeyData.result) == 40, "result must be at offset 40")
precondition(MemoryLayout<SMCKeyData>.size == 80, "SMCKeyData is \(MemoryLayout<SMCKeyData>.size) bytes, not 80")

let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0 else { fatalError("no AppleSMC service") }
var connection: io_connect_t = 0
let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
IOObjectRelease(service)
guard opened == KERN_SUCCESS else { fatalError("IOServiceOpen failed: \(opened)") }

func call(_ input: SMCKeyData) -> SMCKeyData? {
    var input = input
    var output = SMCKeyData()
    var size = MemoryLayout<SMCKeyData>.stride
    // Selector 2 is the user client's single struct method (kSMCHandleYPCEvent).
    let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
    if debug { print("call \(text(input.key)) cmd \(input.data8): kern \(String(result, radix: 16)) smc result \(output.result) size \(size)") }
    return result == KERN_SUCCESS && output.result == 0 ? output : nil
}

/// A key's type (such as "flt " or "ui8 ") and raw bytes.
func read(_ key: String) -> (type: String, bytes: [UInt8])? {
    var request = SMCKeyData()
    request.key = fourCC(key)
    request.data8 = Command.keyInfo.rawValue
    guard let info = call(request) else { return nil }
    request.keyInfo.dataSize = info.keyInfo.dataSize
    request.data8 = Command.readKey.rawValue
    guard var value = call(request) else { return nil }
    let bytes = withUnsafeBytes(of: &value.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
    return (text(info.keyInfo.dataType), bytes)
}

func decode(_ type: String, _ bytes: [UInt8]) -> String {
    switch type {
    case "flt " where bytes.count == 4:
        return String(format: "%.3f", bytes.withUnsafeBytes { $0.load(as: Float32.self) })
    case "ui8 ", "si8 ", "ui16", "ui32":
        return String(bytes.reduce(0) { $0 << 8 | UInt64($1) })
    case "fpe2" where bytes.count == 2:
        return String(format: "%.2f", Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4)
    default:
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

func show(_ key: String) {
    guard let value = read(key) else { print("  \(key): not present"); return }
    print("  \(key) [\(value.type)] = \(decode(value.type, value.bytes))")
}

// `smc watch N`: PSTR once a second, to compare with other power sources under load.
if CommandLine.arguments.dropFirst().first == "watch" {
    let count = Int(CommandLine.arguments.dropFirst(2).first ?? "10") ?? 10
    for second in 0..<count {
        let values = ["PSTR", "PPBR", "PDTR", "PHPS"].map { key in
            "\(key) \(read(key).map { decode($0.type, $0.bytes) } ?? "-")"
        }
        print("\(second)  " + values.joined(separator: "  "))
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

print("== fans")
show("FNum")
let fans = read("FNum").map { Int($0.bytes.first ?? 0) } ?? 0
for fan in 0..<fans {
    for suffix in ["Ac", "Mn", "Mx", "Tg", "md"] { show("F\(fan)\(suffix)") }
}

print("== system power")
for key in ["PSTR", "PDTR", "PPBR", "PHPC", "PZ0E"] { show(key) }

// Enumerate every key, then print those matching the prefixes given (default: F and P).
let prefixes = CommandLine.arguments.dropFirst().isEmpty ? ["F", "P"] : Array(CommandLine.arguments.dropFirst())
guard let countValue = read("#KEY") else { fatalError("no #KEY") }
let keyCount = countValue.bytes.reduce(0) { $0 << 8 | Int($1) }
print("== \(keyCount) keys; matching \(prefixes.joined(separator: ", "))")
let clock = ContinuousClock()
let start = clock.now
var matching: [String] = []
for index in 0..<keyCount {
    var request = SMCKeyData()
    request.data8 = Command.keyFromIndex.rawValue
    request.data32 = UInt32(index)
    guard let result = call(request) else { continue }
    let key = text(result.key)
    if prefixes.contains(where: key.hasPrefix) { matching.append(key) }
}
print("enumerated in \(clock.now - start)")
for key in matching { show(key) }

let timing = clock.now
for _ in 0..<100 { _ = read("PSTR") }
print("one PSTR read: \((clock.now - timing) / 100)")
IOServiceClose(connection)
