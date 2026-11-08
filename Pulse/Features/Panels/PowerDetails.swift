import PulseCore
import SwiftUI

/// Watts, frequencies, energy and temperatures for the Power panel.
struct PowerDetails: View {
    let sample: PowerSample?
    let thermal: ThermalSample?
    /// The model's running energy total, used for "since opened".
    let energyJoules: Double?
    /// The total when this panel appeared. Views are rebuilt each time the panel opens.
    @State private var openingJoules: Double?

    var body: some View {
        if let sample, let cpu = sample.cpuWatts {
            VStack(alignment: .leading, spacing: 4) {
                MetricRow("CPU and GPU", MetricFormat.watts(sample.totalWatts))
                MetricRow("CPU", MetricFormat.watts(cpu))
                ForEach(sample.clusters, id: \.kind) { cluster in
                    MetricRow(clusterTitle(cluster), clusterValue(cluster))
                }
                if let gpu = sample.gpuWatts {
                    MetricRow("GPU", gpuValue(gpu, sample))
                }
                if let boot = sample.energySinceBootJoules {
                    MetricRow("Energy since Mac started", MetricFormat.energy(joules: boot))
                }
                if let energyJoules, let openingJoules {
                    MetricRow("Energy since opened", MetricFormat.energy(joules: energyJoules - openingJoules))
                }
                if let thermal {
                    Text("Temperatures").font(.subheadline.weight(.semibold)).padding(.top, 6)
                    ForEach(thermal.readings) { reading in
                        MetricRow(reading.title, MetricFormat.temperature(reading.celsius))
                    }
                }
            }
            .onAppear { openingJoules = energyJoules }
            .onChange(of: energyJoules == nil) { if openingJoules == nil { openingJoules = energyJoules } }
        } else {
            Text("Power readings aren't available on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func clusterTitle(_ cluster: ClusterPower) -> String {
        switch cluster.kind {
        case .efficiency: "Efficiency cores"
        case .performance: "Performance cores"
        }
    }

    private func clusterValue(_ cluster: ClusterPower) -> String {
        guard let frequency = cluster.frequencyHz, (cluster.activeFraction ?? 0) > 0 else {
            return MetricFormat.watts(cluster.watts)
        }
        return "\(MetricFormat.watts(cluster.watts)) · \(MetricFormat.frequency(frequency))"
    }

    private func gpuValue(_ watts: Double, _ sample: PowerSample) -> String {
        guard let frequency = sample.gpuFrequencyHz, (sample.gpuActiveFraction ?? 0) > 0 else {
            return MetricFormat.watts(watts)
        }
        return "\(MetricFormat.watts(watts)) · \(MetricFormat.frequency(frequency))"
    }
}
