/// A single metric source, driven by the `Sampler`.
///
/// Collectors fail soft: throwing hides the metric and never crashes the app.
public protocol Collector: Sendable {
    associatedtype Sample: Sendable
    var id: MetricID { get }
    func sample() async throws -> Sample
}
