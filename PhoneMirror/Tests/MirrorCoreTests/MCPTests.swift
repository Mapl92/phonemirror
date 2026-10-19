// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorMCP
import Testing

private struct EchoProvider: MCPToolProvider {
    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", description: "Returns the text", properties: ["text": ["type": "string"]], required: ["text"])]
    }

    func call(_ name: String, arguments: JSONValue) async -> MCPToolResult {
        .text(arguments["text"]?.stringValue ?? "")
    }
}

@Suite struct MCPServerTests {
    let server = MCPServer(name: "PhoneMirror", version: "0.3", instructions: "Hint", provider: EchoProvider())

    private func call(_ message: JSONValue) async throws -> JSONValue? {
        guard let data = await server.handle(message.serialized()) else { return nil }
        return try JSONValue.parse(data)
    }

    @Test func initializeNegotiatesVersion() async throws {
        let reply = try #require(try await call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["serverInfo"]?["name"] == "PhoneMirror")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(reply["result"]?["instructions"] == "Hint")
        let unknown = try #require(try await call(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
        #expect(unknown["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
    }

    @Test func notificationsGetNoReply() async throws {
        #expect(try await call(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func listAndCallTools() async throws {
        let list = try #require(try await call(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        #expect(list["result"]?["tools"]?.arrayValue?.first?["name"] == "echo")
        #expect(list["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["required"] == ["text"])
        let reply = try #require(try await call(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "Hello"]]]))
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"] == "Hello")
        #expect(reply["result"]?["isError"] == false)
    }

    @Test func errorsFollowJSONRPC() async throws {
        let unknownTool = try #require(try await call(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope"]]))
        #expect(unknownTool["error"]?["code"] == -32602)
        let unknownMethod = try #require(try await call(["jsonrpc": "2.0", "id": 4, "method": "resources/list"]))
        #expect(unknownMethod["error"]?["code"] == -32601)
        let garbage = try JSONValue.parse(try #require(await server.handle(Data("{nope".utf8))))
        #expect(garbage["error"]?["code"] == -32700)
    }

    @Test func imageResultSerialization() {
        let result = MCPToolResult([.text("Image"), .image(base64: "AAAA", mimeType: "image/jpeg")])
        #expect(result.json["content"]?.arrayValue?.last?["type"] == "image")
        #expect(result.json["content"]?.arrayValue?.last?["mimeType"] == "image/jpeg")
    }
}

@Suite struct HTTPParsingTests {
    @Test func parsesPostWithBodyAndLeavesRest() {
        let raw = Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 4\r\n\r\n{}{}GET /".utf8)
        guard case .complete(let request, let consumed) = HTTPRequest.parse(raw) else {
            Issue.record("not complete")
            return
        }
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer abc")
        #expect(request.body == Data("{}{}".utf8))
        #expect(raw.count - consumed == 5)
    }

    @Test func waitsForFullBody() {
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)) == .incomplete)
    }

    @Test func localOriginsOnly() {
        #expect(MCPHTTPServer.isLocalOrigin("http://localhost:3000"))
        #expect(MCPHTTPServer.isLocalOrigin("http://127.0.0.1"))
        #expect(!MCPHTTPServer.isLocalOrigin("https://evil.example"))
    }

    /// End to end over TCP: token required, initialize, notification → 202.
    @Test func serverRoundTrip() async throws {
        let port = UInt16.random(in: 40_000...50_000)
        let http = try MCPHTTPServer(port: port, token: "secret", server: MCPServer(name: "T", version: "1", provider: EchoProvider()))
        http.start()
        defer { http.stop() }
        try await Task.sleep(for: .milliseconds(200))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = (["jsonrpc": "2.0", "id": 1, "method": "tools/list"] as JSONValue).serialized()
        let (_, unauthorized) = try await URLSession.shared.data(for: request)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (data, ok) = try await URLSession.shared.data(for: request)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONValue.parse(data)["result"]?["tools"]?.arrayValue?.count == 1)
        request.httpBody = (["jsonrpc": "2.0", "method": "notifications/initialized"] as JSONValue).serialized()
        let (_, accepted) = try await URLSession.shared.data(for: request)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 202)
    }
}
