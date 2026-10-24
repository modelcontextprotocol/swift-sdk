@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    enum MockResponses {
        typealias Route = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)

        static func ephemeralConfiguration() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            return config
        }

        static func mockError(_ message: String) -> NSError {
            NSError(
                domain: "MockURLProtocolError", code: 0,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        static func jsonRPCResult(id: Int) -> Data {
            #"{"jsonrpc":"2.0","result":{"ok":true},"id":\#(id)}"#.data(using: .utf8)!
        }

        // MARK: - Route Builders

        static func jsonSuccess(body: Data) -> Route {
            { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
        }

        static func bearerChallenge(
            statusCode: Int = 401,
            resourceMetadataURL: URL? = nil,
            scope: String? = nil,
            error: String? = nil,
            errorDescription: String? = nil
        ) -> Route {
            { request in
                var params: [String] = []
                if let url = resourceMetadataURL {
                    params.append("resource_metadata=\"\(url.absoluteString)\"")
                }
                if let scope { params.append("scope=\"\(scope)\"") }
                if let error { params.append("error=\"\(error)\"") }
                if let errorDescription { params.append("error_description=\"\(errorDescription)\"") }
                let headerValue = "Bearer \(params.joined(separator: ", "))"
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: ["WWW-Authenticate": headerValue])!
                return (response, Data())
            }
        }

        static func resourceMetadata(
            authorizationServers: [String],
            scopesSupported: [String]? = nil,
            resource: String? = nil
        ) -> Route {
            { request in
                var dict: [String: Any] = ["authorization_servers": authorizationServers]
                if let scopes = scopesSupported { dict["scopes_supported"] = scopes }
                if let resource { dict["resource"] = resource }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func asMetadata(
            issuer: String,
            tokenEndpoint: String,
            authorizationEndpoint: String? = nil,
            registrationEndpoint: String? = nil,
            codeChallengeMethodsSupported: [String]? = nil,
            tokenEndpointAuthMethodsSupported: [String]? = nil,
            clientIDMetadataDocumentSupported: Bool? = nil
        ) -> Route {
            { request in
                var dict: [String: Any] = ["issuer": issuer, "token_endpoint": tokenEndpoint]
                if let v = authorizationEndpoint { dict["authorization_endpoint"] = v }
                if let v = registrationEndpoint { dict["registration_endpoint"] = v }
                if let v = codeChallengeMethodsSupported {
                    dict["code_challenge_methods_supported"] = v
                }
                if let v = tokenEndpointAuthMethodsSupported {
                    dict["token_endpoint_auth_methods_supported"] = v
                }
                if let v = clientIDMetadataDocumentSupported {
                    dict["client_id_metadata_document_supported"] = v
                }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func tokenSuccess(
            accessToken: String,
            expiresIn: Int = 3600,
            scope: String? = nil,
            refreshToken: String? = nil
        ) -> Route {
            { request in
                var dict: [String: Any] = [
                    "access_token": accessToken, "token_type": "Bearer", "expires_in": expiresIn,
                ]
                if let scope { dict["scope"] = scope }
                if let refreshToken { dict["refresh_token"] = refreshToken }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func tokenResponse(
            accessToken: String,
            tokenType: String,
            expiresIn: Int = 3600
        ) -> Route {
            { request in
                let dict: [String: Any] = [
                    "access_token": accessToken, "token_type": tokenType, "expires_in": expiresIn,
                ]
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func tokenError(
            statusCode: Int = 400,
            error: String,
            errorDescription: String? = nil,
            extraFields: [String: String] = [:]
        ) -> Route {
            { request in
                var dict: [String: Any] = ["error": error]
                if let errorDescription { dict["error_description"] = errorDescription }
                for (key, value) in extraFields { dict[key] = value }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func httpError(statusCode: Int) -> Route {
            { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data())
            }
        }

        static func registrationSuccess(
            clientID: String,
            clientSecret: String? = nil
        ) -> Route {
            { request in
                var dict: [String: Any] = ["client_id": clientID]
                if let clientSecret { dict["client_secret"] = clientSecret }
                let data = try JSONSerialization.data(withJSONObject: dict)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, data)
            }
        }

        static func redirect(to location: String, statusCode: Int = 302) -> Route {
            { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location])!
                return (response, Data())
            }
        }

        // MARK: - Routing Handler

        static func routingHandler(
            routes: [URL: Route]
        ) -> @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data) {
            { request in
                guard let url = request.url else { throw mockError("Missing request URL") }
                guard let handler = routes[url] else {
                    throw mockError("Unexpected URL: \(url.absoluteString)")
                }
                return try await handler(request)
            }
        }
    }

#endif  // swift(>=6.1)
