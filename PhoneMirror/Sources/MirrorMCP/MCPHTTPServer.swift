// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import os

/// Minimal HTTP/1.1 server for MCP “Streamable HTTP”: `POST /mcp` with JSON-RPC, response as JSON.
/// Listens only on 127.0.0.1, requires a bearer token and rejects foreign `Origin`s (DNS rebinding).
public final class MCPHTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let token: String
    private let server: MCPServer
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PhoneMirror.mcp")
    private static let logger = Logger(subsystem: "PhoneMirror", category: "mcp")
    /// Reported on every accepted tool call (for the indicator in the window).
    public var onRequest: (@Sendable () -> Void)?

    public init(port: UInt16, token: String, server: MCPServer) throws {
        self.port = port
        self.token = token
        self.server = server
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Self.logger.error("MCP server: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        Self.logger.notice("MCP server listening on http://127.0.0.1:\(self.port)/mcp")
    }

    public func stop() {
        listener.cancel()
    }

    /// Reads requests (keep-alive) and answers them one after another.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 16 << 20 {
                connection.cancel()
                return
            }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            case .invalid:
                self.send(.init(status: 400, body: Data()), on: connection, close: true)
            case .complete(let request, let consumed):
                let rest = buffer.dropFirst(consumed)
                Task {
                    let response = await self.respond(to: request)
                    self.send(response, on: connection, close: request.wantsClose)
                    if !request.wantsClose { self.receive(on: connection, buffer: Data(rest)) }
                }
            }
        }
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.headers["origin"], !Self.isLocalOrigin(origin) {
            return HTTPResponse(status: 403, body: Data("Forbidden origin".utf8))
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return HTTPResponse(status: 401, body: Data("Unauthorized".utf8), extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        guard request.path == "/mcp" else { return HTTPResponse(status: 404, body: Data()) }
        switch request.method {
        case "POST":
            onRequest?()
            guard let reply = await server.handle(request.body) else { return HTTPResponse(status: 202, body: Data()) }
            return HTTPResponse(status: 200, body: reply, contentType: "application/json")
        case "DELETE":
            return HTTPResponse(status: 200, body: Data())
        default:
            // No server-side SSE stream – reject with 405 per the specification.
            return HTTPResponse(status: 405, body: Data(), extraHeaders: ["Allow": "POST, DELETE"])
        }
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, close: Bool) {
        connection.send(content: response.encoded(close: close), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var wantsClose: Bool { headers["connection"]?.lowercased() == "close" }

    enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(HTTPRequest, consumed: Int)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid : .incomplete
        }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .invalid }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(), path: path, headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])
        )
        return .complete(request, consumed: bodyStart + length - data.startIndex)
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType: String = "text/plain; charset=utf-8"
    var extraHeaders: [String: String] = [:]

    func encoded(close: Bool) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += close ? "Connection: close\r\n\r\n" : "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8) + body
    }
}
