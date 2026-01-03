import Foundation

@testable import MCP

/// Common JSON-RPC payloads used in tests.
///
/// These helpers centralize test payload construction to:
/// - Eliminate duplicate JSON strings across tests
/// - Ensure consistent use of version constants
/// - Make version-specific testing easier
enum TestPayloads {

    // MARK: - Default Values

    /// Default protocol version for tests (initial stable release).
    static let defaultVersion = Version.v2024_11_05

    // MARK: - Initialize

    /// Creates a JSON-RPC initialize request.
    static func initializeRequest(
        id: String = "1",
        protocolVersion: String = defaultVersion,
        clientName: String = "test",
        clientVersion: String = "1.0"
    ) -> String {
        """
        {"jsonrpc":"2.0","method":"initialize","id":"\(id)","params":{"protocolVersion":"\(protocolVersion)","capabilities":{},"clientInfo":{"name":"\(clientName)","version":"\(clientVersion)"}}}
        """
    }

    /// Creates a JSON-RPC initialize result.
    static func initializeResult(
        id: String = "1",
        protocolVersion: String = defaultVersion,
        serverName: String = "test",
        serverVersion: String = "1.0"
    ) -> String {
        """
        {"jsonrpc":"2.0","result":{"protocolVersion":"\(protocolVersion)","capabilities":{},"serverInfo":{"name":"\(serverName)","version":"\(serverVersion)"}},"id":"\(id)"}
        """
    }

    // MARK: - Initialized Notification

    /// Creates a JSON-RPC initialized notification.
    static func initializedNotification() -> String {
        """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """
    }

    // MARK: - Tools

    /// Creates a JSON-RPC tools/list request.
    static func listToolsRequest(id: String = "2") -> String {
        """
        {"jsonrpc":"2.0","method":"tools/list","id":"\(id)","params":{}}
        """
    }

    /// Creates a JSON-RPC tools/call request.
    static func callToolRequest(
        id: String = "2",
        name: String,
        arguments: [String: Any] = [:]
    ) -> String {
        let argsJSON = arguments.isEmpty ? "{}" : serializeJSON(arguments)
        return """
            {"jsonrpc":"2.0","method":"tools/call","id":"\(id)","params":{"name":"\(name)","arguments":\(argsJSON)}}
            """
    }

    // MARK: - Resources

    /// Creates a JSON-RPC resources/list request.
    static func listResourcesRequest(id: String = "2") -> String {
        """
        {"jsonrpc":"2.0","method":"resources/list","id":"\(id)","params":{}}
        """
    }

    /// Creates a JSON-RPC resources/read request.
    static func readResourceRequest(id: String = "2", uri: String) -> String {
        """
        {"jsonrpc":"2.0","method":"resources/read","id":"\(id)","params":{"uri":"\(uri)"}}
        """
    }

    // MARK: - Prompts

    /// Creates a JSON-RPC prompts/list request.
    static func listPromptsRequest(id: String = "2") -> String {
        """
        {"jsonrpc":"2.0","method":"prompts/list","id":"\(id)","params":{}}
        """
    }

    /// Creates a JSON-RPC prompts/get request.
    static func getPromptRequest(id: String = "2", name: String) -> String {
        """
        {"jsonrpc":"2.0","method":"prompts/get","id":"\(id)","params":{"name":"\(name)"}}
        """
    }

    // MARK: - Ping

    /// Creates a JSON-RPC ping request.
    static func pingRequest(id: String = "ping") -> String {
        """
        {"jsonrpc":"2.0","method":"ping","id":"\(id)"}
        """
    }

    // MARK: - Batch Requests

    /// Creates a batch of JSON-RPC requests.
    static func batchRequest(_ requests: [String]) -> String {
        "[\(requests.joined(separator: ","))]"
    }

    // MARK: - Helpers

    private static func serializeJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}

// MARK: - HTTPRequest Helpers

extension TestPayloads {

    /// Creates an HTTP POST request for MCP.
    static func postRequest(
        body: String,
        sessionId: String? = nil,
        protocolVersion: String = defaultVersion,
        lastEventId: String? = nil,
        accept: String = "application/json, text/event-stream"
    ) -> HTTPRequest {
        var headers = [
            HTTPHeader.accept: accept,
            HTTPHeader.contentType: "application/json",
            HTTPHeader.protocolVersion: protocolVersion,
        ]
        if let sessionId {
            headers[HTTPHeader.sessionId] = sessionId
        }
        if let lastEventId {
            headers[HTTPHeader.lastEventId] = lastEventId
        }
        return HTTPRequest(
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        )
    }

    /// Creates an HTTP GET request for SSE streams.
    static func getRequest(
        sessionId: String,
        protocolVersion: String = defaultVersion,
        lastEventId: String? = nil
    ) -> HTTPRequest {
        var headers = [
            HTTPHeader.accept: "text/event-stream",
            HTTPHeader.sessionId: sessionId,
            HTTPHeader.protocolVersion: protocolVersion,
        ]
        if let lastEventId {
            headers[HTTPHeader.lastEventId] = lastEventId
        }
        return HTTPRequest(
            method: "GET",
            headers: headers,
            body: nil
        )
    }

    /// Creates an HTTP DELETE request for session termination.
    static func deleteRequest(
        sessionId: String,
        protocolVersion: String = defaultVersion
    ) -> HTTPRequest {
        HTTPRequest(
            method: "DELETE",
            headers: [
                HTTPHeader.sessionId: sessionId,
                HTTPHeader.protocolVersion: protocolVersion,
            ],
            body: nil
        )
    }
}
