/// Stable identifier for a metric source.
public struct MetricID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let cpu = MetricID(rawValue: "cpu")
    public static let memory = MetricID(rawValue: "memory")
    public static let disk = MetricID(rawValue: "disk")
    public static let network = MetricID(rawValue: "network")
    public static let battery = MetricID(rawValue: "battery")
    public static let processes = MetricID(rawValue: "processes")
    public static let networkProcesses = MetricID(rawValue: "networkProcesses")
    public static let selfUsage = MetricID(rawValue: "selfUsage")
    public static let power = MetricID(rawValue: "power")
    public static let temperature = MetricID(rawValue: "temperature")
    public static let smc = MetricID(rawValue: "smc")
}
