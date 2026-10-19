// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Ein Werkzeug, das Agents über MCP aufrufen können.
public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    /// JSON-Schema der Argumente.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// Kurzform für Objekt-Schemata: `properties` und `required`.
    public init(name: String, description: String, properties: [String: JSONValue] = [:], required: [String] = []) {
        self.init(name: name, description: description, inputSchema: [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
}

/// Ergebnis eines Werkzeugaufrufs (MCP `CallToolResult`).
public struct MCPToolResult: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    public var content: [Content]
    public var isError: Bool

    public init(_ content: [Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult { MCPToolResult([.text(text)]) }
    public static func error(_ text: String) -> MCPToolResult { MCPToolResult([.text(text)], isError: true) }

    var json: JSONValue {
        let items: [JSONValue] = content.map {
            switch $0 {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .image(let data, let mime): ["type": "image", "data": .string(data), "mimeType": .string(mime)]
            }
        }
        return ["content": .array(items), "isError": .bool(isError)]
    }
}

/// Liefert die Werkzeuge und führt sie aus.
public protocol MCPToolProvider: Sendable {
    func tools() async -> [MCPTool]
    func call(_ name: String, arguments: JSONValue) async -> MCPToolResult
}

/// JSON-RPC-2.0-Dispatcher für das Model Context Protocol (Server-Seite, nur Tools).
public struct MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public var name: String
    public var version: String
    public var instructions: String?
    public var provider: any MCPToolProvider

    public init(name: String, version: String, instructions: String? = nil, provider: any MCPToolProvider) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.provider = provider
    }

    /// Verarbeitet eine JSON-RPC-Nachricht. `nil` = Benachrichtigung ohne Antwort (HTTP 202).
    public func handle(_ body: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONValue.parse(body)
        } catch {
            return Self.error(id: .null, code: -32700, message: "Parse error").serialized()
        }
        guard case .object = message, let method = message["method"]?.stringValue else {
            // Antworten des Clients auf Server-Anfragen (wir stellen keine) und Unbekanntes ignorieren.
            if message["id"] != nil, message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request").serialized()
        }
        guard let id = message["id"] else { return nil } // Benachrichtigung (z. B. notifications/initialized)
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return Self.result(id: id, .object(result)).serialized()

        case "ping":
            return Self.result(id: id, [:]).serialized()

        case "tools/list":
            let tools = await provider.tools().map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            }
            return Self.result(id: id, ["tools": .array(tools)]).serialized()

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Missing tool name").serialized()
            }
            guard await provider.tools().contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)").serialized()
            }
            let result = await provider.call(name, arguments: params["arguments"] ?? [:])
            return Self.result(id: id, result.json).serialized()

        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)").serialized()
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
