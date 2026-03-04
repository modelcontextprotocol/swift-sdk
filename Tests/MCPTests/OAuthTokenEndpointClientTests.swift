@preconcurrency import Foundation
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    @Suite("OAuthTokenEndpointClient", .serialized)
    struct OAuthTokenEndpointClientTests {

        let client = OAuthTokenEndpointClient(urlValidator: OAuthURLValidator())
        let tokenEndpoint = URL(string: "https://auth.example.com/token")!

        func successBody(
            accessToken: String = "access-token",
            tokenType: String = "Bearer",
            scope: String? = nil,
            refreshToken: String? = nil
        ) throws -> Data {
            var dict: [String: Any] = [
                "access_token": accessToken,
                "token_type": tokenType,
                "expires_in": 3600,
            ]
            if let scope { dict["scope"] = scope }
            if let refreshToken { dict["refresh_token"] = refreshToken }
            return try JSONSerialization.data(withJSONObject: dict)
        }

        // MARK: - Success

        @Test("Returns decoded token response on success")
        func testRequestReturnsToken() async throws {
            let body = try successBody()
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            var params = ["grant_type": "client_credentials"]
            let result = try await client.request(
                parameters: &params,
                endpoint: tokenEndpoint,
                authentication: .none(clientID: "client-id"),
                session: session
            )
            let expected = OAuthTokenResponse(
                accessToken: "access-token", tokenType: "Bearer",
                expiresIn: 3600, scope: nil, refreshToken: nil)
            #expect(result == expected)
        }

        @Test("Parses optional scope and refresh token")
        func testRequestParsesOptionalFields() async throws {
            let body = try successBody(scope: "read write", refreshToken: "refresh-xyz")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            var params = ["grant_type": "client_credentials"]
            let result = try await client.request(
                parameters: &params,
                endpoint: tokenEndpoint,
                authentication: .none(clientID: "client-id"),
                session: session
            )
            let expected = OAuthTokenResponse(
                accessToken: "access-token", tokenType: "Bearer",
                expiresIn: 3600, scope: "read write", refreshToken: "refresh-xyz")
            #expect(result == expected)
        }

        // MARK: - Error Responses

        @Test("Throws for non-2xx status")
        func testRequestThrowsForNon2xx() async throws {
            let errorBody = try JSONSerialization.data(withJSONObject: ["error": "invalid_client"])
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 401,
                    httpVersion: nil, headerFields: nil)!
                return (response, errorBody)
            }

            var params = ["grant_type": "client_credentials"]
            await #expect(throws: OAuthAuthorizationError.self) {
                try await client.request(
                    parameters: &params,
                    endpoint: tokenEndpoint,
                    authentication: .none(clientID: "client-id"),
                    session: session
                )
            }
        }

        @Test("Throws for empty access_token")
        func testRequestThrowsForEmptyAccessToken() async throws {
            let body = try successBody(accessToken: "")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            var params = ["grant_type": "client_credentials"]
            await #expect(throws: OAuthAuthorizationError.self) {
                try await client.request(
                    parameters: &params,
                    endpoint: tokenEndpoint,
                    authentication: .none(clientID: "client-id"),
                    session: session
                )
            }
        }

        @Test("Throws for non-Bearer token_type")
        func testRequestThrowsForNonBearerTokenType() async throws {
            let body = try successBody(tokenType: "MAC")
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { _ in
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            var params = ["grant_type": "client_credentials"]
            await #expect(throws: OAuthAuthorizationError.self) {
                try await client.request(
                    parameters: &params,
                    endpoint: tokenEndpoint,
                    authentication: .none(clientID: "client-id"),
                    session: session
                )
            }
        }

        // MARK: - Form Encoding

        @Test("Sends parameters as form-encoded POST body")
        func testRequestSendsFormEncodedBody() async throws {
            let body = try successBody()
            let (session, key) = makeIsolatedSession()
            actor RequestCapture { var value: URLRequest?; func set(_ r: URLRequest) { value = r } }
            let capture = RequestCapture()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                await capture.set(request)
                let response = HTTPURLResponse(
                    url: self.tokenEndpoint, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
                return (response, body)
            }

            var params = ["grant_type": "client_credentials", "resource": "https://api.example.com"]
            _ = try await client.request(
                parameters: &params,
                endpoint: tokenEndpoint,
                authentication: .none(clientID: "client-id"),
                session: session
            )

            let capturedRequest = await capture.value
            let bodyData: Data = {
                if let data = capturedRequest?.httpBody { return data }
                guard let stream = capturedRequest?.httpBodyStream else { return Data() }
                stream.open(); defer { stream.close() }
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable { data.append(buf, count: stream.read(buf, maxLength: 4096)) }
                return data
            }()
            let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
            #expect(bodyString.contains("grant_type=client_credentials"))
            #expect(bodyString.contains("resource="))
            #expect(capturedRequest?.httpMethod == "POST")
        }
    }

#endif
