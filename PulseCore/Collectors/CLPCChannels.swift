import Foundation
import IOKit

/// AppleCLPC's aggregate energy counters, which IOReport doesn't list and which must be described
/// by hand. They are cheap to read (about 1 ms per sample against 7.5 ms for the PMP histograms).
///
/// The channel layout and counter IDs come from macmon 0.9 (MIT licence,
/// https://github.com/vladkens/macmon, `src/clpc.rs`), where they were extracted from macOS 27.0.
/// Only chips verified against powermetrics on a real Mac are listed. See docs/m2-findings.md.
enum CLPCChannels {
    static let group = "CLPC"
    static let subgroup = "Energy Counters"

    private struct Keys {
        let cpu: UInt32
        let gpu: UInt32
        let ane: UInt32
    }

    /// Driver bundle → counter keys. M5: verified on macOS 27.2 (Mac17,3).
    private static let keys: [String: Keys] = [
        "com.apple.driver.AppleT8142CLPC": Keys(cpu: 0x4370_8744, gpu: 0x6A01_0933, ane: 0xBC5E_FDF0)
    ]

    /// Report indices for macOS 27. Other major versions are not known to use the same layout.
    private static let indices = (cpu: Int64(16), gpu: Int64(25), ane: Int64(24))

    /// Channel descriptions for this Mac, or nil when its chip or macOS version is unverified.
    static func channels(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [NSDictionary]? {
        guard osMajorVersion == 27 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var driverID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &driverID) == KERN_SUCCESS,
              let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? String,
              let keys = keys[bundle] else { return nil }
        return [
            channel(driverID: driverID, id: indices.cpu << 32 | Int64(keys.cpu), name: "CPU Energy"),
            channel(driverID: driverID, id: indices.gpu << 32 | Int64(keys.gpu), name: "GPU Energy"),
            channel(driverID: driverID, id: indices.ane << 32 | Int64(keys.ane), name: "ANE")
        ]
    }

    private static func channel(driverID: UInt64, id: Int64, name: String) -> NSDictionary {
        // A simple integer channel in the power category with one element, in nanojoules.
        let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
        let nanojoules: Int64 = (3 << 56) | (118 << 32)
        // Mutable, because IOReport caches derived fields in it.
        return NSMutableDictionary(dictionary: [
            "DriverID": NSNumber(value: Int64(bitPattern: driverID)),
            "DriverName": "AppleCLPC",
            "IOReportGroupName": group,
            "IOReportSubGroupName": subgroup,
            "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: nanojoules)],
            "LegendChannel": [NSNumber(value: id), NSNumber(value: channelType), name]
        ])
    }
}
