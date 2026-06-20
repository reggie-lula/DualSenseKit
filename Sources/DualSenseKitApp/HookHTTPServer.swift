import Foundation
import Network

final class HookHTTPServer: @unchecked Sendable {
    static let host = "127.0.0.1"
    static let port: UInt16 = 17396

    private let hookStore: HookStore
    private let hookService: HookService
    private let queue = DispatchQueue(label: "DualSenseKitApp.HookHTTPServer")
    private var listener: NWListener?

    init(hookStore: HookStore, hookService: HookService) {
        self.hookStore = hookStore
        self.hookService = hookService
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("DualSenseKit hook server failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func url(for slug: String) -> String {
        "http://\(host):\(port)/hooks/\(HookDefinition.sanitizeSlug(slug))"
    }

    private func handle(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = HookHTTPRequest(data: data) else {
                self?.send(status: 400, json: ["ok": "false", "error": "bad_request"], connection: connection)
                return
            }
            self.route(request, connection: connection)
        }
    }

    private func route(_ request: HookHTTPRequest, connection: NWConnection) {
        guard request.method == "GET" || request.method == "POST" else {
            send(status: 405, json: ["ok": "false", "error": "method_not_allowed"], connection: connection)
            return
        }
        let prefix = "/hooks/"
        guard request.path.hasPrefix(prefix) else {
            send(status: 404, json: ["ok": "false", "error": "not_found"], connection: connection)
            return
        }
        let slug = String(request.path.dropFirst(prefix.count))
        guard let hook = hookStore.hook(slug: slug) else {
            send(status: 404, json: ["ok": "false", "error": "hook_not_found"], connection: connection)
            return
        }
        let result = hookService.execute(hook)
        send(
            status: result.ok ? 200 : 409,
            json: ["ok": result.ok ? "true" : "false", "hook": hook.slug, "message": result.message],
            connection: connection
        )
    }

    private func send(status: Int, json: [String: String], connection: NWConnection) {
        let fields = json.map { key, value in
            if value == "true" || value == "false" {
                return "\"\(key)\":\(value)"
            }
            return "\"\(key)\":\"\(Self.escape(value))\""
        }.sorted().joined(separator: ",")
        let body = "{\(fields)}"
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Error"
        let response = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.debugDescription == "127.0.0.1"
        case .ipv6(let address):
            return address.debugDescription == "::1"
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct HookHTTPRequest {
    var method: String
    var path: String

    init?(data: Data) {
        guard let raw = String(data: data, encoding: .utf8),
              let firstLine = raw.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1]).components(separatedBy: "?").first ?? "/"
    }
}
