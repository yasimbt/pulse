// Spike: what the IORegistry says about USB-C / MagSafe ports, chargers and connected devices.
// Prints a readable summary and saves the raw properties to build/spikes/ports/<label>.plist, so
// that states (nothing plugged in, charger A, charger B, a hub) can be compared.
// Run: swiftc -O -o build/spikes/ports-spike Tools/spikes/ports/main.swift && build/spikes/ports-spike <label>
import Foundation
import IOKit

let label = CommandLine.arguments.dropFirst().first ?? "now"

/// Every service of a class with its properties.
func services(_ className: String) -> [(entry: io_registry_entry_t, properties: [String: Any])] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [(io_registry_entry_t, [String: Any])] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        var properties: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dictionary = properties?.takeRetainedValue() as? [String: Any] {
            result.append((entry, dictionary))
        }
    }
    return result
}

func describe(_ value: Any?) -> String {
    switch value {
    case nil: return "-"
    case let data as Data: return data.count <= 16 ? data.map { String(format: "%02x", $0) }.joined() : "<\(data.count) bytes>"
    case let array as [Any]: return "[" + array.map { describe($0) }.joined(separator: ", ") + "]"
    case let dictionary as [String: Any]:
        return "{" + dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0]))" }.joined(separator: ", ") + "}"
    default: return "\(value!)"
    }
}

var raw: [String: Any] = [:]

// MARK: - Ports

print("== ports")
let portKeys = [
    "PortTypeDescription", "ConnectionActive", "ConnectionCount", "TransportsActive", "TransportsProvisioned",
    "IOAccessoryUSBConnectString", "IOAccessoryUSBSuperSpeedActive", "IOAccessoryPowerCurrentLimits",
    "ActiveCable", "OpticalCable", "PlugOrientation", "Pin Configuration", "DisplayPortPinAssignment", "HPDAsserted"
]
var ports: [[String: Any]] = []
for className in ["AppleHPMInterfaceType10", "AppleHPMInterfaceType11"] {
    for service in services(className) {
        ports.append(service.properties)
        print("  \(service.properties["PortDescription"] ?? "?")")
        for key in portKeys where service.properties[key] != nil {
            print("    \(key): \(describe(service.properties[key]))")
        }
        IOObjectRelease(service.entry)
    }
}
raw["ports"] = ports

var transports: [[String: Any]] = []
for service in services("IOPortTransportState") {
    let properties = service.properties
    transports.append(properties)
    if (properties["Active"] as? Bool) == true {
        print("  active transport: \(properties["TransportDescription"] ?? "?") \(describe(properties["Metadata"]))")
    }
    IOObjectRelease(service.entry)
}
raw["transports"] = transports

// MARK: - Charger

print("== charger (AppleSmartBattery)")
if let battery = services("AppleSmartBattery").first {
    let properties = battery.properties
    for key in ["ExternalConnected", "IsCharging", "FullyCharged", "AdapterInfo", "AdapterDetails", "AppleRawAdapterDetails", "ChargerData"] {
        print("  \(key): \(describe(properties[key]))")
    }
    if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
        let keys = ["SystemPowerIn", "SystemVoltageIn", "SystemCurrentIn", "SystemLoad", "BatteryPower", "AdapterEfficiencyLoss", "WallEnergyEstimate"]
        print("  PowerTelemetryData: " + keys.map { "\($0)=\(describe(telemetry[$0]))" }.joined(separator: " "))
    }
    if let controllers = properties["PortControllerInfo"] as? [[String: Any]] {
        for (index, controller) in controllers.enumerated() {
            // Keys that look like power negotiation; the rest are diagnostics.
            let interesting = controller.keys.filter {
                $0.range(of: "PDO|Rdo|RDO|Volt|Curr|Power|Max|Src|Snk|Contract|Cable|Vid|Pid|Mode|Role", options: .regularExpression) != nil
            }
            print("  PortControllerInfo[\(index)]: " + interesting.sorted().map { "\($0)=\(describe(controller[$0]))" }.joined(separator: " "))
        }
    }
    if let fed = properties["FedDetails"] as? [[String: Any]] {
        for (index, details) in fed.enumerated() where (details["FedExternalConnected"] as? Int ?? 0) != 0 {
            print("  FedDetails[\(index)]: \(describe(details))")
        }
    }
    raw["battery"] = properties.filter { !["BatteryData", "IOReportLegend"].contains($0.key) }
    IOObjectRelease(battery.entry)
}

// MARK: - USB devices

print("== USB devices")
var usb: [[String: Any]] = []
for service in services("IOUSBHostDevice") {
    let properties = service.properties
    usb.append(properties)
    let name = properties["USB Product Name"] ?? properties["kUSBProductString"] ?? "?"
    let vendor = properties["USB Vendor Name"] ?? properties["kUSBVendorString"] ?? "?"
    // Device Speed: 0 low, 1 full, 2 high (USB 2), 3 super (5 Gb/s), 4 super+ (10 Gb/s), 5 super+ 2x2.
    let speed = properties["Device Speed"] ?? properties["UsbDeviceSpeed"] ?? "?"
    let location = (properties["locationID"] as? Int).map { String(format: "0x%08x", $0) } ?? "?"
    print("  \(name) (\(vendor)) speed=\(speed) location=\(location) power=\(properties["UsbPowerSinkAllocation"] ?? properties["kUSBCurrentConfiguration"] ?? "-")")
    IOObjectRelease(service.entry)
}
raw["usb"] = usb

// MARK: - Thunderbolt

print("== Thunderbolt")
var thunderbolt: [[String: Any]] = []
for className in ["IOThunderboltSwitch", "IOThunderboltPort"] {
    for service in services(className) {
        let properties = service.properties
        thunderbolt.append(properties)
        if className == "IOThunderboltSwitch" {
            print("  switch: \(properties["Device Model Name"] ?? "?") (\(properties["Device Vendor Name"] ?? "?")) depth=\(properties["Depth"] ?? "?")")
        } else if let speed = properties["Current Speed"] ?? properties["Link Speed"], (properties["Current Link Width"] as? Int ?? 0) > 0 {
            print("  port \(properties["Port Number"] ?? "?"): speed=\(describe(speed)) width=\(describe(properties["Current Link Width"]))")
        }
        IOObjectRelease(service.entry)
    }
}
raw["thunderbolt"] = thunderbolt

// MARK: - Save

let directory = URL(fileURLWithPath: "build/spikes/ports")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let url = directory.appending(path: "\(label).plist")
let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
try data.write(to: url)
print("saved \(url.path)")
