import Foundation
import Network
import os

/// Serves the latest snapshot over HTTP on 127.0.0.1 only, for Prometheus or scripts. Opt-in.
///   GET /metrics       Prometheus text format
///   GET /metrics.json  JSON
public actor MetricsServer {
    public static let defaultPort: UInt16 = 9466
    private static let logger = Logger(subsystem: PulseInfo.logSubsystem, category: "server")
    /// A request line plus headers never needs more than this.
    private static let maxRequestBytes = 8192

    private var listener: NWListener?
    private var latest: Snapshot?
    private let queue = DispatchQueue(label: "com.pulse.server", qos: .utility)

    public init() {}

    /// Starts listening, or restarts on a new port. Throws if the port can't be used.
    public func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        // Loopback only: nothing else on the network can connect.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 9466)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.serve(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Self.logger.error("metrics server failed: \(String(describing: error), privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func update(_ snapshot: Snapshot) {
        latest = snapshot
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, _, _ in
            Task {
                guard let self else { return connection.cancel() }
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let response = Self.response(to: request, snapshot: await self.latest)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// The full HTTP response to a request. Pure, so that routing is testable without a socket.
    public static func response(to request: String, snapshot: Snapshot?) -> Data {
        let words = request.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard words.count >= 2 else { return http(400, "Bad Request", "text/plain", "Bad request\n") }
        guard words[0] == "GET" || words[0] == "HEAD" else { return http(405, "Method Not Allowed", "text/plain", "Use GET\n") }
        let path = words[1].split(separator: "?").first.map(String.init) ?? ""
        guard path == "/metrics" || path == "/metrics.json" else {
            return http(404, "Not Found", "text/plain", "Try /metrics or /metrics.json\n")
        }
        guard let snapshot else { return http(503, "Service Unavailable", "text/plain", "No sample yet\n") }
        let body: Data
        let type: String
        if path == "/metrics.json" {
            body = (try? MetricsExport.json(snapshot)) ?? Data("{}".utf8)
            type = "application/json"
        } else {
            body = Data(MetricsExport.prometheus(snapshot).utf8)
            type = "text/plain; version=0.0.4; charset=utf-8"
        }
        return http(200, "OK", type, body, headOnly: words[0] == "HEAD")
    }

    private static func http(_ status: Int, _ reason: String, _ type: String, _ body: String) -> Data {
        http(status, reason, type, Data(body.utf8))
    }

    private static func http(_ status: Int, _ reason: String, _ type: String, _ body: Data, headOnly: Bool = false) -> Data {
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + (headOnly ? Data() : body)
    }
}
