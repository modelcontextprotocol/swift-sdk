/**
 * Everything client - a single conformance test client that handles all scenarios.
 *
 * Usage: mcp-everything-client <server-url>
 *
 * The scenario name is read from the MCP_CONFORMANCE_SCENARIO environment variable,
 * which is set by the conformance test runner.
 *
 * This client routes to the appropriate behavior based on the scenario name,
 * consolidating all the individual test clients into one.
 */

import Foundation
import Logging
import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Scenario Handlers

typealias ScenarioHandler = ([String]) async throws -> Void

// MARK: - Authorization Scenarios

private func loadConformanceContext() -> [String: String] {
    let env = ProcessInfo.processInfo.environment

    if let raw = env["MCP_CONFORMANCE_CONTEXT"],
        let data = raw.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        var parsed: [String: String] = [:]
        for (key, value) in json {
            if let value = value as? String {
                parsed[key] = value
            }
        }
        return parsed
    }

    var parsed: [String: String] = [:]
    if let clientID = env["MCP_CONFORMANCE_CLIENT_ID"] {
        parsed["client_id"] = clientID
    }
    if let clientSecret = env["MCP_CONFORMANCE_CLIENT_SECRET"] {
        parsed["client_secret"] = clientSecret
    }
    return parsed
}

private func percentEncodeFormValue(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func formURLEncodedBody(_ parameters: [String: String]) -> Data {
    let encoded = parameters
        .sorted { $0.key < $1.key }
        .map { key, value in
            "\(percentEncodeFormValue(key))=\(percentEncodeFormValue(value))"
        }
        .joined(separator: "&")
    return Data(encoded.utf8)
}

private func clientAssertionAudience(from tokenEndpoint: URL) -> String {
    guard var components = URLComponents(url: tokenEndpoint, resolvingAgainstBaseURL: false) else {
        return tokenEndpoint.absoluteString
    }

    components.query = nil
    components.fragment = nil

    var path = components.path
    if path.hasSuffix("/token") {
        path = String(path.dropLast("/token".count))
    } else {
        let parts = path.split(separator: "/")
        if !parts.isEmpty {
            let parent = parts.dropLast()
            path = parent.isEmpty ? "" : "/" + parent.joined(separator: "/")
        }
    }
    if path == "/" {
        path = ""
    }
    components.path = path

    return components.url?.absoluteString ?? tokenEndpoint.absoluteString
}

private func parsePrivateKeyJWTSigningAlgorithm(
    _ signingAlgorithm: String
) throws -> OAuthConfiguration.PrivateKeyJWTSigningAlgorithm {
    switch signingAlgorithm.uppercased() {
    case OAuthConfiguration.PrivateKeyJWTSigningAlgorithm.ES256.rawValue:
        return .ES256
    default:
        throw ConformanceError.invalidArguments(
            "Unsupported signing algorithm: \(signingAlgorithm)"
        )
    }
}

private func makeOAuthConfiguration(
    for scenario: String,
    context: [String: String]
) -> OAuthConfiguration {
    let clientID = context["client_id"] ?? "test-client"
    let clientSecret = context["client_secret"] ?? "test-secret"

    var configuration: OAuthConfiguration
    switch scenario {
    case "auth/pre-registration":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/token-endpoint-auth-basic":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/token-endpoint-auth-post":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .clientSecretPost(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/client-credentials-basic":
        configuration = .init(
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            )
        )

    case "auth/client-credentials-jwt":
        let privateKeyPEM = context["private_key_pem"] ?? ""
        let signingAlgorithm = context["signing_algorithm"] ?? "ES256"
        configuration = .init(
            authentication: .privateKeyJWT(
                clientID: clientID,
                assertionFactory: { tokenEndpoint, clientID in
                    try OAuthConfiguration.makePrivateKeyJWTAssertion(
                        clientID: clientID,
                        tokenEndpoint: tokenEndpoint,
                        privateKeyPEM: privateKeyPEM,
                        signingAlgorithm: try parsePrivateKeyJWTSigningAlgorithm(signingAlgorithm),
                        audience: clientAssertionAudience(from: tokenEndpoint)
                    )
                }
            )
        )

    case "auth/basic-cimd":
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .none(
                clientID: context["client_id"]
                    ?? "https://conformance-test.local/client-metadata.json")
        )

    case "auth/cross-app-access-complete-flow":
        configuration = .init(
            authentication: .clientSecretBasic(
                clientID: clientID,
                clientSecret: clientSecret
            ),
            accessTokenProvider: makeCrossAppAccessTokenProvider(context: context)
        )

    case let s where s.hasPrefix("auth/client-credentials"):
        configuration = .init(
            authentication: .none(clientID: clientID)
        )

    default:
        configuration = .init(
            grantType: .authorizationCode,
            authentication: .none(clientID: clientID)
        )
    }

    // Conformance harness currently uses loopback http AS endpoints.
    configuration.allowLoopbackHTTPAuthorizationServerEndpoints = true
    return configuration
}

private struct ConformanceTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private func requestOAuthToken(
    url: URL,
    parameters: [String: String],
    authorizationHeader: String?,
    session: URLSession
) async throws -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let authorizationHeader {
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = formURLEncodedBody(parameters)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw ConformanceError.invalidArguments("Token endpoint returned an invalid response")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw ConformanceError.invalidArguments(
            "Token endpoint error (\(httpResponse.statusCode)): \(body)"
        )
    }

    let token = try JSONDecoder().decode(ConformanceTokenResponse.self, from: data)
    guard !token.accessToken.isEmpty else {
        throw ConformanceError.invalidArguments("Token endpoint returned an empty access token")
    }
    return token.accessToken
}

private func makeCrossAppAccessTokenProvider(
    context: [String: String]
) -> OAuthConfiguration.AccessTokenProvider {
    return { discovery, session in
        guard let clientID = context["client_id"],
            let clientSecret = context["client_secret"],
            let idpClientID = context["idp_client_id"],
            let idpIDToken = context["idp_id_token"],
            let idpTokenEndpointValue = context["idp_token_endpoint"],
            let idpTokenEndpoint = URL(string: idpTokenEndpointValue)
        else {
            throw ConformanceError.invalidArguments(
                "Cross-app scenario requires client_id, client_secret, idp_client_id, idp_id_token, and idp_token_endpoint"
            )
        }

        guard let authorizationServer = discovery.authorizationServer else {
            throw ConformanceError.invalidArguments(
                "SDK did not provide authorization server discovery context"
            )
        }
        guard let tokenEndpoint = discovery.tokenEndpoint else {
            throw ConformanceError.invalidArguments(
                "SDK did not provide token endpoint discovery context"
            )
        }
        let resource = discovery.resource.absoluteString

        let idJag = try await requestOAuthToken(
            url: idpTokenEndpoint,
            parameters: [
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": idpIDToken,
                "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:id-jag",
                "audience": authorizationServer.absoluteString,
                "resource": resource,
                "client_id": idpClientID,
            ],
            authorizationHeader: nil,
            session: session
        )

        var accessTokenParameters: [String: String] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": idJag,
            "resource": resource,
        ]
        if let requestedScopes = discovery.requestedScopes, !requestedScopes.isEmpty {
            accessTokenParameters["scope"] = requestedScopes.sorted().joined(separator: " ")
        }

        let basicCredentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        let accessToken = try await requestOAuthToken(
            url: tokenEndpoint,
            parameters: accessTokenParameters,
            authorizationHeader: "Basic \(basicCredentials)",
            session: session
        )

        return accessToken
    }
}

func runAuthorizationScenario(scenario: String, args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.auth",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting auth scenario", metadata: ["scenario": "\(scenario)"])

    guard let serverURLString = args.last,
        let serverURL = URL(string: serverURLString)
    else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    let context = loadConformanceContext()
    let oauthConfig = makeOAuthConfiguration(for: scenario, context: context)

    let transport = HTTPClientTransport(
        endpoint: serverURL,
        streaming: true,
        authorizer: OAuthAuthorizer(configuration: oauthConfig),
        logger: logger
    )

    let client = Client(name: "test-client", version: "1.0.0")

    // Scenarios that expect the connection to fail with a specific error.
    if scenario == "auth/resource-mismatch" {
        do {
            _ = try await client.connect(transport: transport)
            throw ConformanceError.invalidArguments(
                "Expected authorization to fail with resource mismatch, but connection succeeded"
            )
        } catch let error as MCPError {
            guard case .internalError(let detail) = error,
                detail?.contains("resource mismatch") == true
            else {
                throw ConformanceError.invalidArguments(
                    "Connection failed, but not due to resource mismatch: \(error.localizedDescription)"
                )
            }
            logger.debug("Client correctly rejected mismatched PRM resource")
        }
        return
    }

    _ = try await client.connect(transport: transport)

    // Exercise both initialization and regular request paths.
    let (tools, _) = try await client.listTools()
    logger.debug("Auth scenario listed tools", metadata: ["count": "\(tools.count)"])

    // Trigger an additional request for scenarios that involve runtime scope behavior.
    if scenario.contains("scope"), let firstTool = tools.first {
        _ = try? await client.callTool(name: firstTool.name, arguments: [:])
    }

    await client.disconnect()
    logger.debug("Auth scenario completed", metadata: ["scenario": "\(scenario)"])
}

// MARK: - Basic Scenarios

/// Basic client that connects, initializes, and lists tools
func runInitializeScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.initialize",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting initialize scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Disconnect
    await client.disconnect()

    logger.debug("Initialize scenario completed successfully")
}

/// Client that calls the add_numbers tool
func runToolsCallScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.tools_call",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting tools_call scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the add_numbers tool
    if tools.contains(where: { $0.name == "add_numbers" }) {
        let result = try await client.callTool(
            name: "add_numbers",
            arguments: ["a": 5, "b": 3]
        )
        logger.debug("Tool call result", metadata: [
            "isError": "\(result.isError ?? false)",
            "contentCount": "\(result.content.count)"
        ])
    } else {
        logger.warning("add_numbers tool not found")
    }

    // Disconnect
    await client.disconnect()

    logger.debug("Tools call scenario completed successfully")
}

// MARK: - SSE Scenarios

/// Handler for SSE-related scenarios (retry, reconnection, etc.)
func runSSEScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.sse",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting SSE scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport with streaming enabled
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        streaming: true,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect - this will start the SSE stream in the background
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // Give the GET SSE stream time to establish
    try await Task.sleep(for: .milliseconds(500))

    // Call the test_reconnection tool to trigger SSE stream closure and retry test.
    // The server will close the POST SSE stream without the response,
    // then deliver it on the GET SSE stream after we reconnect.
    logger.debug("Calling test_reconnection tool...")
    let result = try await client.callTool(name: "test_reconnection", arguments: [:])
    logger.debug("Tool call result received", metadata: [
        "isError": "\(result.isError ?? false)",
        "contentCount": "\(result.content.count)"
    ])

    // Keep the connection open briefly for the test to collect timing data
    try await Task.sleep(for: .seconds(2))

    // Disconnect
    await client.disconnect()

    logger.debug("SSE scenario completed")
}

/// Client that handles elicitation-sep1034-client-defaults scenario
/// Tests that client properly applies default values for omitted fields
func runElicitationSEP1034ClientDefaults(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.elicitation_client_defaults",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Starting elicitation-sep1034-client-defaults scenario")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport with streaming enabled for bidirectional communication
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        streaming: true,
        logger: logger
    )

    // Create client with elicitation capabilities
    let client = Client(
        name: "test-client",
        version: "1.0.0",
        capabilities: Client.Capabilities(
            elicitation: Client.Capabilities.Elicitation(form: .init(), url: .init())
        )
    )

    // Set up elicitation handler that accepts defaults BEFORE connecting
    await client.withElicitationHandler { [logger] params in
        let message: String
        switch params {
        case .form(let formParams):
            message = formParams.message
        case .url(let urlParams):
            message = urlParams.message
        }

        logger.debug("Elicitation handler invoked", metadata: [
            "message": "\(message)"
        ])

        // Accept with default values applied
        // The schema has optional fields with defaults:
        // name: "John Doe", age: 30, score: 95.5, status: "active", verified: true
        return CreateElicitation.Result(
            action: .accept,
            content: [
                "name": "John Doe",
                "age": 30,
                "score": 95.5,
                "status": "active",
                "verified": true
            ]
        )
    }

    // Connect
    try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server")

    // List tools
    let (tools, _) = try await client.listTools()
    logger.debug("Successfully listed tools", metadata: [
        "toolCount": "\(tools.count)"
    ])

    // Call the test_client_elicitation_defaults tool
    if tools.contains(where: { $0.name == "test_client_elicitation_defaults" }) {
        let result = try await client.callTool(
            name: "test_client_elicitation_defaults",
            arguments: [:]
        )
        logger.debug("Tool call result", metadata: [
            "isError": "\(result.isError ?? false)",
            "contentCount": "\(result.content.count)"
        ])
    } else {
        logger.warning("test_client_elicitation_defaults tool not found")
    }

    // Disconnect
    await client.disconnect()

    logger.debug("Elicitation client defaults scenario completed successfully")
}

// MARK: - Default Handler for Unimplemented Scenarios

/// Default handler that performs basic connection test for unimplemented scenarios
func runDefaultScenario(_ args: [String]) async throws {
    var logger = Logger(
        label: "mcp.conformance.client.default",
        factory: { StreamLogHandler.standardError(label: $0) }
    )
    logger.logLevel = .debug

    logger.debug("Running default scenario handler")

    // Get server URL from args
    guard let serverURLString = args.last,
          let serverURL = URL(string: serverURLString) else {
        throw ConformanceError.invalidArguments("Valid server URL is required")
    }

    // Create HTTP transport
    let transport = HTTPClientTransport(
        endpoint: serverURL,
        logger: logger
    )

    // Create client
    let client = Client(name: "test-client", version: "1.0.0")

    // Connect
    let initResult = try await client.connect(transport: transport)
    logger.debug("Successfully connected to MCP server", metadata: [
        "serverName": "\(initResult.serverInfo.name)",
        "serverVersion": "\(initResult.serverInfo.version)"
    ])

    // Disconnect
    await client.disconnect()

    logger.debug("Default scenario completed successfully")
}

// MARK: - Scenario Registry

nonisolated(unsafe) let scenarioHandlers: [String: ScenarioHandler] = [
    "initialize": runInitializeScenario,
    "tools_call": runToolsCallScenario,
    "sse-retry": runSSEScenario,
    "elicitation-sep1034-client-defaults": runElicitationSEP1034ClientDefaults,
]

// MARK: - Error Types

enum ConformanceError: Error, CustomStringConvertible {
    case missingScenario
    case invalidArguments(String)

    var description: String {
        switch self {
        case .missingScenario:
            return "MCP_CONFORMANCE_SCENARIO environment variable not set"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        }
    }
}

struct ConformanceClient {
    static func run() async {
        do {
            // Get scenario from environment
            guard let scenario = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SCENARIO"] else {
                var stderr = StandardError()
                print("Error: MCP_CONFORMANCE_SCENARIO environment variable not set", to: &stderr)
                Foundation.exit(1)
            }

            // Get server URL from arguments (last argument)
            let args = Array(CommandLine.arguments.dropFirst())
            guard !args.isEmpty else {
                var stderr = StandardError()
                print("Usage: mcp-everything-client <server-url>", to: &stderr)
                print("Error: Server URL is required", to: &stderr)
                Foundation.exit(1)
            }

            // Get handler for scenario
            let handler: ScenarioHandler
            if let explicitHandler = scenarioHandlers[scenario] {
                handler = explicitHandler
            } else if scenario.hasPrefix("auth/") {
                handler = { args in
                    try await runAuthorizationScenario(scenario: scenario, args: args)
                }
            } else {
                handler = runDefaultScenario
                var stderr = StandardError()
                print("⚠️  Scenario '\(scenario)' not fully implemented - using default handler", to: &stderr)
            }

            // Run the scenario
            try await handler(args)
            Foundation.exit(0)
        } catch {
            var stderr = StandardError()
            print("Error: \(error)", to: &stderr)
            Foundation.exit(1)
        }
    }
}

// MARK: - Helpers

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

await ConformanceClient.run()
