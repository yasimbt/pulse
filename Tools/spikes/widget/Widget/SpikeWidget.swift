// Shows what it can read from the App Group container, or why it can't.
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let message: String
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), message: "placeholder") }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Tries the localhost endpoint first, then the App Group file.
        let url = URL(string: "http://127.0.0.1:9466/metrics.json")!
        URLSession.shared.dataTask(with: url) { data, _, error in
            let message: String
            if let data, let text = String(data: data, encoding: .utf8), text.contains("pulse_cpu_usage_ratio") {
                message = "endpoint OK, \(data.count) bytes"
            } else {
                message = "endpoint: \(error?.localizedDescription ?? "no data"); " + read().message
            }
            completion(Timeline(entries: [Entry(date: Date(), message: message)], policy: .after(Date().addingTimeInterval(60))))
        }.resume()
    }

    private func read() -> Entry {
        let group = "group.com.pulse.spike"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return Entry(date: Date(), message: "no group container")
        }
        let text = (try? String(contentsOf: container.appending(path: "spike.txt"), encoding: .utf8)) ?? "file not readable"
        return Entry(date: Date(), message: text)
    }
}

struct SpikeWidgetView: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pulse spike").font(.headline)
            Text(entry.message).font(.caption)
            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct SpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PulseSpike", provider: Provider()) { SpikeWidgetView(entry: $0) }
            .configurationDisplayName("Pulse Spike")
            .description("Checks App Group sharing.")
            .supportedFamilies([.systemSmall])
    }
}
