import PulseCore
import SwiftUI

/// The Ports panel: the charger, and what's on each port.
struct PortsDetails: View {
    let sample: PortsSample?

    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 4) {
                if let charger = sample.charger {
                    ChargerRows(charger: charger, port: sample.chargerPort)
                } else {
                    MetricRow("Charger", "Not connected")
                }
                Text("Ports").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(sample.ports) { port in
                    MetricRow(title(port), status(port, chargerPort: sample.chargerPort))
                }
            }
        } else {
            Text("Port information isn't available on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// "USB-C 1", "MagSafe 3".
    private func title(_ port: PortSample) -> String {
        let number = port.name.split(separator: "@").last.map(String.init) ?? ""
        return port.type == "USB-C" ? "USB-C \(number)" : port.type
    }

    private func status(_ port: PortSample, chargerPort: String?) -> String {
        guard port.isConnected else { return "Empty" }
        if port.name == chargerPort { return "Charger" }
        var parts = port.activeTransports.filter { $0 != "CC" }.map { transport in
            switch transport {
            case "CIO": "Thunderbolt/USB4"
            case "USB3": "USB 3"
            case "USB2": "USB 2"
            default: transport
            }
        }
        if port.isActiveCable { parts.append("active cable") }
        if port.isOpticalCable { parts.append("optical cable") }
        return parts.isEmpty ? "Connected" : parts.joined(separator: ", ")
    }
}

private struct ChargerRows: View {
    let charger: ChargerSample
    let port: String?

    var body: some View {
        MetricRow("Charger", charger.advertisedWatts.map { "\(Int($0)) W" } ?? "Connected")
        MetricRow("State", state)
        if let input = charger.inputWatts {
            let detail = [charger.inputVolts.map { String(format: "%.1f V", $0) }, charger.inputAmps.map { String(format: "%.2f A", $0) }]
                .compactMap { $0 }
                .joined(separator: " × ")
            MetricRow("Drawing from charger", detail.isEmpty ? MetricFormat.watts(input) : "\(MetricFormat.watts(input)) (\(detail))")
        }
        if let system = charger.systemWatts { MetricRow("Mac is using", MetricFormat.watts(system)) }
        if let battery = charger.batteryWatts, charger.inputWatts != nil {
            MetricRow(battery >= 0 ? "Into the battery" : "From the battery", MetricFormat.watts(abs(battery)))
        }
        if let loss = charger.conversionLossWatts { MetricRow("Conversion loss", MetricFormat.watts(loss)) }
        if let volts = charger.selectedVolts, let amps = charger.selectedAmps {
            MetricRow("Agreed with charger", String(format: "%g V, %g A", volts, amps))
        }
        if !charger.offers.isEmpty {
            MetricRow("Charger offers", charger.offers.map(offer).joined(separator: ", "))
        }
        if let alert = PortAlerts.chargerShortfall(charger) {
            Label(alert, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.top, 4)
        }
    }

    private var state: String {
        switch charger.state {
        case .charging: "Charging"
        case .full: "Fully charged"
        case .notCharging(let reason): reason == 0 ? "Not charging" : "Not charging yet"
        }
    }

    private func offer(_ offer: PowerOffer) -> String {
        switch offer {
        case let .fixed(volts, _): String(format: "%g V", volts)
        case let .programmable(minVolts, maxVolts, _): String(format: "%g–%g V", minVolts, maxVolts)
        }
    }
}
