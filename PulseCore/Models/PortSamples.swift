import Foundation

/// One physical port: USB-C or MagSafe.
public struct PortSample: Sendable, Equatable, Identifiable {
    public let name: String
    /// "USB-C" or "MagSafe 3".
    public let type: String
    /// Whether something is plugged in now. The only port flag that isn't left over from an
    /// earlier connection; see docs/ports-findings.md.
    public let isConnected: Bool
    /// In use, such as "CC" for a charger, "USB3" or "CIO" for Thunderbolt or USB4.
    public let activeTransports: [String]
    public let supportedTransports: [String]
    public let isActiveCable: Bool
    public let isOpticalCable: Bool

    public var id: String { name }

    public init(
        name: String, type: String, isConnected: Bool, activeTransports: [String], supportedTransports: [String],
        isActiveCable: Bool, isOpticalCable: Bool
    ) {
        self.name = name
        self.type = type
        self.isConnected = isConnected
        self.activeTransports = activeTransports
        self.supportedTransports = supportedTransports
        self.isActiveCable = isActiveCable
        self.isOpticalCable = isOpticalCable
    }
}

/// One power offer from a USB Power Delivery charger (a PDO).
public enum PowerOffer: Sendable, Equatable {
    case fixed(volts: Double, amps: Double)
    /// Programmable Power Supply: any voltage in the range, up to the current.
    case programmable(minVolts: Double, maxVolts: Double, amps: Double)

    public var maxWatts: Double {
        switch self {
        case let .fixed(volts, amps): volts * amps
        case let .programmable(_, maxVolts, amps): maxVolts * amps
        }
    }
}

public struct ChargerSample: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case charging
        case full
        /// Connected but not charging. Right after plugging in, this is brief.
        case notCharging(reason: Int)
    }

    public let state: State
    /// As the charger describes itself, such as "pd charger".
    public let description: String?
    /// What the charger says it can deliver.
    public let advertisedWatts: Double?
    public let offers: [PowerOffer]
    /// The offer in use.
    public let selectedVolts: Double?
    public let selectedAmps: Double?
    /// From the charger, measured. Updated every few tens of seconds by macOS.
    public let inputWatts: Double?
    public let inputVolts: Double?
    public let inputAmps: Double?
    /// The Mac's own use.
    public let systemWatts: Double?
    /// Positive into the battery, negative out of it.
    public let batteryWatts: Double?
    /// Lost converting the charger's voltage.
    public let conversionLossWatts: Double?

    public init(
        state: State, description: String?, advertisedWatts: Double?, offers: [PowerOffer], selectedVolts: Double?,
        selectedAmps: Double?, inputWatts: Double?, inputVolts: Double?, inputAmps: Double?, systemWatts: Double?,
        batteryWatts: Double?, conversionLossWatts: Double?
    ) {
        self.state = state
        self.description = description
        self.advertisedWatts = advertisedWatts
        self.offers = offers
        self.selectedVolts = selectedVolts
        self.selectedAmps = selectedAmps
        self.inputWatts = inputWatts
        self.inputVolts = inputVolts
        self.inputAmps = inputAmps
        self.systemWatts = systemWatts
        self.batteryWatts = batteryWatts
        self.conversionLossWatts = conversionLossWatts
    }
}

public struct PortsSample: Sendable, Equatable {
    public let ports: [PortSample]
    /// Nil when no charger is connected.
    public let charger: ChargerSample?
    /// The port the charger is on, when it can be told.
    public let chargerPort: String?

    public init(ports: [PortSample], charger: ChargerSample?, chargerPort: String?) {
        self.ports = ports
        self.charger = charger
        self.chargerPort = chargerPort
    }
}
