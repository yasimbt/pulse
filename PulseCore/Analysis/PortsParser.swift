import Foundation

/// Turns IORegistry properties into port and charger samples. See docs/ports-findings.md.
public enum PortsParser {
    /// One `AppleHPMInterfaceType*` service's properties.
    public static func port(_ properties: [String: Any]) -> PortSample? {
        guard let name = properties["PortDescription"] as? String else { return nil }
        return PortSample(
            name: name,
            type: properties["PortTypeDescription"] as? String ?? "Port",
            isConnected: flag(properties["ConnectionActive"]),
            activeTransports: properties["TransportsActive"] as? [String] ?? [],
            supportedTransports: properties["TransportsSupported"] as? [String] ?? [],
            isActiveCable: flag(properties["ActiveCable"]),
            isOpticalCable: flag(properties["OpticalCable"])
        )
    }

    /// The charger from `AppleSmartBattery`'s properties, or nil when none is connected.
    public static func charger(_ battery: [String: Any]) -> ChargerSample? {
        guard flag(battery["ExternalConnected"]) else { return nil }
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        let chargerData = battery["ChargerData"] as? [String: Any] ?? [:]
        let state: ChargerSample.State = if flag(battery["FullyCharged"]) {
            .full
        } else if flag(battery["IsCharging"]) {
            .charging
        } else {
            .notCharging(reason: int(chargerData["NotChargingReason"]) ?? 0)
        }
        func milli(_ value: Any?) -> Double? { int(value).map { Double($0) / 1000 } }
        // Telemetry reads zero until macOS first updates it after plugging in.
        let inputWatts = milli(telemetry["SystemPowerIn"])
        let measured = (inputWatts ?? 0) > 0
        return ChargerSample(
            state: state,
            description: adapter["Description"] as? String,
            advertisedWatts: int(adapter["Watts"]).map(Double.init),
            offers: offers(battery),
            selectedVolts: milli(adapter["AdapterVoltage"]),
            selectedAmps: milli(adapter["Current"]),
            inputWatts: measured ? inputWatts : nil,
            inputVolts: measured ? milli(telemetry["SystemVoltageIn"]) : nil,
            inputAmps: measured ? milli(telemetry["SystemCurrentIn"]) : nil,
            systemWatts: milli(telemetry["SystemLoad"]),
            batteryWatts: milli(telemetry["BatteryPower"]),
            conversionLossWatts: measured ? milli(telemetry["AdapterEfficiencyLoss"]) : nil
        )
    }

    /// The raw PD offers from the port controller that has any, which also include programmable
    /// ranges. Falls back to `AdapterDetails.UsbHvcMenu`, which lists fixed offers only.
    static func offers(_ battery: [String: Any]) -> [PowerOffer] {
        let controllers = battery["PortControllerInfo"] as? [[String: Any]] ?? []
        // `PortControllerNPDOs` counts fixed offers only (5 on the UGREEN, which also sends a PPS
        // range), so every non-zero word is decoded instead.
        for controller in controllers where (int(controller["PortControllerNPDOs"]) ?? 0) > 0 {
            let words = (controller["PortControllerPortPDO"] as? [Any] ?? []).compactMap(int)
            let decoded = words.compactMap { decode(UInt32(truncatingIfNeeded: $0)) }
            if !decoded.isEmpty { return decoded }
        }
        let menu = (battery["AdapterDetails"] as? [String: Any])?["UsbHvcMenu"] as? [[String: Any]] ?? []
        return menu.compactMap { item in
            guard let volts = int(item["MaxVoltage"]), let amps = int(item["MaxCurrent"]) else { return nil }
            return .fixed(volts: Double(volts) / 1000, amps: Double(amps) / 1000)
        }
    }

    /// Decodes one USB Power Delivery offer (PDO). Fixed supplies: voltage in 50 mV units in bits
    /// 19-10, current in 10 mA units in bits 9-0. Programmable (PPS): maximum voltage in 100 mV units
    /// in bits 24-17, minimum in bits 15-8, current in 50 mA units in bits 6-0. Zero is no offer.
    public static func decode(_ word: UInt32) -> PowerOffer? {
        guard word != 0 else { return nil }
        switch word >> 30 {
        case 0:
            // Divided rather than multiplied by 0.05 and 0.01, so that 3.3 V comes out as exactly 3.3.
            return .fixed(volts: Double((word >> 10) & 0x3FF) / 20, amps: Double(word & 0x3FF) / 100)
        case 3 where (word >> 28) & 0x3 == 0:
            return .programmable(
                minVolts: Double((word >> 8) & 0xFF) / 10,
                maxVolts: Double((word >> 17) & 0xFF) / 10,
                amps: Double(word & 0x7F) / 20
            )
        default:
            // Battery, variable or other augmented supplies: not seen yet, so not shown.
            return nil
        }
    }

    static func flag(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? false)
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}

/// Plain-language warnings about power and ports.
public enum PortAlerts {
    /// Shown when the Mac runs partly on battery although a charger is connected, for example
    /// "The 30 W charger can't keep up: the Mac is using 45 W, so the battery is draining."
    public static func chargerShortfall(_ charger: ChargerSample) -> String? {
        // Only once input is measured: right after plugging in, the battery still reads as
        // draining while input reads zero.
        guard charger.inputWatts != nil, let battery = charger.batteryWatts, battery < -0.5, let system = charger.systemWatts else {
            return nil
        }
        let rating = charger.advertisedWatts.map { "The \(Int($0)) W charger" } ?? "The charger"
        return "\(rating) can't keep up: the Mac is using \(MetricFormat.watts(system)), so the battery is draining."
    }
}
