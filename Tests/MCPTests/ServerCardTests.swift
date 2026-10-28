import Crypto
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import MCP

// Server Cards (SEP-2127), against the examples of the extension at the
// pinned commit (Generated/ServerCardExamples.swift).

private func decode(_ text: String) throws -> ServerCard {
    try JSONDecoder().decode(ServerCard.self, from: Data(text.utf8))
}

private func json(_ text: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(text.utf8))
}

private let validCard = ServerCard(
    name: "com.example/weather", version: "1.2.0", description: "Current weather for a city.",
    title: "Weather",
    remotes: [.init(type: .streamableHTTP, url: "https://example.com/mcp", supportedProtocolVersions: ["2026-07-28", "2025-11-25"])])

@Suite("Server Cards: the format")
struct ServerCardFormatTests {
    @Test("The examples are vendored as published")
    func vendored() {
        #expect(serverCardExamples.count == 7)
        for example in serverCardExamples {
            let digest = SHA256.hash(data: Data(example.contents.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == example.sha256, "\(example.path)")
        }
    }

    @Test("Valid examples decode, pass the checks and encode as they were")
    func valid() throws {
        for example in serverCardExamples where example.isValid {
            let card = try decode(example.text)
            try card.validate()
            let encoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(card))
            #expect(encoded == (try json(example.text)), "\(example.path)")
        }
    }

    @Test("Invalid examples fail to decode or fail the checks")
    func invalid() throws {
        var reasons: [String: String] = [:]
        for example in serverCardExamples where !example.isValid {
            do {
                try decode(example.text).validate()
                Issue.record("\(example.path) passed")
            } catch let error as ServerCardError {
                reasons[example.path] = error.reason.rawValue
            } catch is DecodingError {
                reasons[example.path] = "decoding"
            }
        }
        #expect(
            reasons == [
                "examples/ServerCard/invalid/bad-name-pattern.json": "invalidCard",
                "examples/ServerCard/invalid/date-versioned-schema.json": "invalidCard",
                "examples/ServerCard/invalid/missing-name.json": "decoding",
                "examples/ServerCard/invalid/missing-schema.json": "decoding",
                "examples/ServerCard/invalid/wrong-schema-name.json": "invalidCard",
            ])
    }

    @Test("Unknown fields are ignored")
    func unknownFields() throws {
        let card = try decode(
            #"{"$schema":"https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json","name":"a.b/c","version":"1","description":"d","later":true,"remotes":[{"type":"websocket","url":"https://x.example/mcp","later":1}]}"#
        )
        try card.validate()
        #expect(card.remotes?.first?.type == ServerCard.Remote.TransportType(rawValue: "websocket"))
    }

    @Test("The checks of the schema", arguments: [
        ("name", "nameless", false), ("name", "a/b/c", false), ("name", "ab", false), ("name", "a.b/c", true),
        ("name", "io.github.user/my_server-1.0", true), ("name", "a b/c", false),
        ("version", "^1.2.3", false), ("version", "~1.2.3", false), ("version", ">=1.2.3", false),
        ("version", "1.x", false), ("version", "1.*", false), ("version", "2.1.0-alpha", true),
        ("version", "2026.10.28", true), ("version", String(repeating: "1", count: 256), false),
        ("description", "", false), ("description", String(repeating: "d", count: 101), false),
        ("description", String(repeating: "d", count: 100), true),
        ("url", "https://example.com/mcp", true), ("url", "{base}/mcp", true), ("url", "ftp://example.com", false),
        ("url", "https://", false), ("url", "https://a b", false), ("url", "{1x}/mcp", false),
    ])
    func checks(field: String, value: String, valid: Bool) {
        var card = validCard
        switch field {
        case "name": card.name = value
        case "version": card.version = value
        case "description": card.description = value
        default: card.remotes = [.init(type: .streamableHTTP, url: value)]
        }
        #expect(card.problems().isEmpty == valid, "\(field) \(value): \(card.problems())")
    }

    @Test("A card from the server's implementation information")
    func builder() throws {
        let info = Server.Info(
            name: "com.example/weather", version: "1.2.0", title: "Weather", description: "Current weather for a city.")
        let card = ServerCard(
            info: info, endpoint: URL(string: "https://example.com/mcp")!,
            protocolVersions: ["2026-07-28", "2025-11-25"])
        #expect(card == validCard)
        try card.validate()

        // The usual implementation name is not reverse-DNS, and a card needs a description.
        let plain = ServerCard(
            info: .init(name: "weather", version: "1.0"), endpoint: URL(string: "https://example.com/mcp")!,
            protocolVersions: [])
        #expect(plain.problems().count == 2)
        let named = ServerCard(
            info: .init(name: "weather", version: "1.0"), endpoint: URL(string: "https://example.com/mcp")!,
            protocolVersions: [], name: "com.example/weather", description: "Weather.")
        try named.validate()
    }

    @Test("The recommended location is <endpoint>/server-card")
    func cardURL() {
        func url(_ endpoint: String) -> String {
            ServerCard.cardURL(forEndpoint: URL(string: endpoint)!).absoluteString
        }
        #expect(url("https://host/mcp") == "https://host/mcp/server-card")
        #expect(url("https://host/mcp/") == "https://host/mcp/server-card")
        #expect(url("https://host/server/mcp?x=1#f") == "https://host/server/mcp/server-card")
        #expect(url("http://127.0.0.1:3000") == "http://127.0.0.1:3000/server-card")
    }

    @Test("URL templates take values, then the variable's value, then its default")
    func templates() throws {
        let card = try decode(try #require(serverCardExamples.first { $0.path.hasSuffix("templated-remote.json") }).text)
        let remote = try #require(card.remotes?.first)
        #expect(try remote.url().absoluteString == "https://default.example.com/mcp")
        #expect(try remote.url(resolving: ["tenant": "acme"]).absoluteString == "https://acme.example.com/mcp")

        let required = ServerCard.Remote(
            type: .streamableHTTP, url: "https://{tenant}.example.com/mcp", variables: ["tenant": .init(isRequired: true)])
        #expect(throws: ServerCardError.self) { _ = try required.url() }
        let undeclared = ServerCard.Remote(type: .streamableHTTP, url: "{base}/mcp")
        #expect { _ = try undeclared.url() } throws: { ($0 as? ServerCardError)?.reason == .missingVariable }
        #expect(try undeclared.url(resolving: ["base": "https://x.example"]).absoluteString == "https://x.example/mcp")
        let optional = ServerCard.Remote(
            type: .streamableHTTP, url: "https://example.com/{prefix}mcp", variables: ["prefix": .init()])
        #expect(try optional.url().absoluteString == "https://example.com/mcp")
        #expect { _ = try undeclared.url(resolving: ["base": "javascript:"]) } throws: {
            ($0 as? ServerCardError)?.reason == .invalidCard
        }
    }

    @Test("Mismatches with server/discover")
    func mismatches() {
        var meta = Metadata()
        meta.serverInfo = .init(name: "com.example/weather", version: "1.3.0", title: "Weather")
        let live = ServerDiscover.Result(supportedVersions: ["2026-07-28"], capabilities: .init(), _meta: meta)
        let found = validCard.mismatches(with: live)
        #expect(found.map(\.field) == [.version, .protocolVersion])
        #expect(found.first?.card == "1.2.0" && found.first?.server == "1.3.0")
        #expect(found.last?.card == "2025-11-25")
        // Without serverInfo only the versions are compared.
        let anonymous = ServerDiscover.Result(supportedVersions: ["2026-07-28", "2025-11-25"], capabilities: .init())
        #expect(validCard.mismatches(with: anonymous).isEmpty)
    }
}

@Suite("Server Cards: serving")
struct ServerCardValidatorTests {
    private let validator = try! ServerCardValidator(card: validCard, endpointPath: "/mcp/")

    private func request(_ method: String = "GET", path: String = "/mcp/server-card", headers: [String: String] = [:])
        -> HTTPRequest
    {
        HTTPRequest(method: method, headers: headers, body: nil, path: path)
    }

    @Test("GET answers the card with its media type, an ETag, caching and CORS headers")
    func get() throws {
        let response = try #require(validator.response(to: request()))
        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeaderName.contentType] == ServerCard.mediaType)
        #expect(response.headers[HTTPHeaderName.cacheControl] == "public, max-age=3600")
        #expect(response.headers["Access-Control-Allow-Origin"] == "*")
        #expect(response.headers["Access-Control-Expose-Headers"] == "ETag")
        let etag = try #require(response.headers[HTTPHeaderName.etag])
        #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""))
        #expect(try JSONDecoder().decode(ServerCard.self, from: try #require(response.bodyData)) == validCard)
        #expect(validator.path == "/mcp/server-card")
    }

    @Test("If-None-Match with the ETag answers 304 without a body")
    func revalidation() throws {
        let etag = try #require(validator.response(to: request())?.headers[HTTPHeaderName.etag])
        for header in [etag, "W/\(etag)", "\"other\", \(etag)", "*"] {
            let response = try #require(validator.response(to: request(headers: ["If-None-Match": header])))
            #expect(response.statusCode == 304, "\(header)")
            #expect(response.bodyData?.isEmpty != false)
            #expect(response.headers[HTTPHeaderName.etag] == etag)
        }
        #expect(validator.response(to: request(headers: ["if-none-match": "\"other\""]))?.statusCode == 200)
    }

    @Test("OPTIONS is a CORS preflight; other methods are 405; other paths are not answered")
    func methodsAndPaths() {
        let preflight = validator.response(to: request("OPTIONS"))
        #expect(preflight?.statusCode == 204)
        #expect(preflight?.headers["Access-Control-Allow-Methods"] == "GET")
        #expect(preflight?.headers["Access-Control-Allow-Headers"] == "Content-Type, If-None-Match")
        let head = validator.response(to: request("HEAD"))
        #expect(head?.statusCode == 200 && head?.bodyData?.isEmpty != false)
        #expect(head?.headers[HTTPHeaderName.etag] == validator.response(to: request())?.headers[HTTPHeaderName.etag])
        #expect(validator.response(to: request("POST"))?.statusCode == 405)
        #expect(validator.response(to: request(path: "/mcp")) == nil)
        #expect(validator.response(to: request(path: "/mcp/server-card/x")) == nil)
    }

    @Test("A card that does not follow the format is refused")
    func invalidCard() {
        var card = validCard
        card.name = "weather"
        #expect(throws: ServerCardError.self) { _ = try ServerCardValidator(card: card) }
    }

    @Test("Both HTTP server transports pass the validator's answers")
    func transports() async throws {
        let pipeline = StandardValidationPipeline(validators: [validator])
        let stateless = StatelessHTTPServerTransport(validationPipeline: pipeline)
        let etag = try #require(await stateless.handleRequest(request()).headers[HTTPHeaderName.etag])
        #expect(await stateless.handleRequest(request()).statusCode == 200)
        #expect(await stateless.handleRequest(request(headers: ["If-None-Match": etag])).statusCode == 304)
        #expect(await stateless.handleRequest(request("OPTIONS")).statusCode == 204)

        let stateful = StatefulHTTPServerTransport(validationPipeline: pipeline)
        #expect(await stateful.handleRequest(request()).statusCode == 200)
        #expect(await stateful.handleRequest(request(headers: ["If-None-Match": etag])).statusCode == 304)
        #expect(await stateful.handleRequest(request("OPTIONS")).statusCode == 204)
        // Without a validator that answers, OPTIONS stays 405.
        #expect(await StatefulHTTPServerTransport().handleRequest(request("OPTIONS")).statusCode == 405)
    }
}

#if swift(>=6.1)
    @Suite("Server Cards: fetching")
    struct ServerCardFetchTests {
        private let url = URL(string: "https://example.com/mcp/server-card")!

        private func serve(
            status: Int = 200, body: Data, headers: [String: String] = [:],
            check: @escaping @Sendable (URLRequest) -> Void = { _ in }
        ) async -> URLSession {
            let (session, key) = makeIsolatedSession()
            await IsolatedMockURLProtocol.setHandler(key: key) { request in
                check(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (response, body)
            }
            return session
        }

        @Test("A card is fetched with the media type in Accept, and its ETag is returned")
        func fetch() async throws {
            let body = try JSONEncoder().encode(validCard)
            let session = await serve(body: body, headers: ["ETag": "\"v1\""]) { request in
                #expect(request.value(forHTTPHeaderField: "Accept") == ServerCard.mediaType)
            }
            #expect(try await ServerCard.fetch(from: url, session: session) == validCard)
            #expect(try await ServerCard.fetch(from: url, ifNoneMatch: nil, session: session) == .card(validCard, etag: "\"v1\""))
        }

        @Test("If-None-Match is sent, and 304 is notModified")
        func notModified() async throws {
            let session = await serve(status: 304, body: Data()) { request in
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
            }
            #expect(try await ServerCard.fetch(from: url, ifNoneMatch: "\"v1\"", session: session) == .notModified)
        }

        @Test("Refusals", arguments: [
            ("http://example.com/mcp/server-card", 200, "card", "insecureURL"),
            ("https://example.com/mcp/server-card", 404, "card", "httpStatus"),
            ("https://example.com/mcp/server-card", 200, "large", "tooLarge"),
            ("https://example.com/mcp/server-card", 200, "html", "notACard"),
            ("https://example.com/mcp/server-card", 200, "invalid", "invalidCard"),
        ])
        func refusals(address: String, status: Int, body: String, reason: String) async throws {
            var invalid = validCard
            invalid.description = ""
            let data: Data
            switch body {
            case "card": data = try JSONEncoder().encode(validCard)
            case "large": data = Data(repeating: 0x20, count: ServerCard.maximumSize + 1)
            case "html": data = Data("<html></html>".utf8)
            default: data = try JSONEncoder().encode(invalid)
            }
            let session = await serve(status: status, body: data)
            do {
                _ = try await ServerCard.fetch(from: URL(string: address)!, session: session)
                Issue.record("Expected \(reason)")
            } catch let error as ServerCardError {
                #expect(error.reason.rawValue == reason)
            }
        }

        @Test("http is allowed on a loopback host")
        func loopback() async throws {
            let session = await serve(body: try JSONEncoder().encode(validCard))
            for address in ["http://127.0.0.1:3000/mcp/server-card", "http://localhost/mcp/server-card", "http://[::1]:8080/server-card"] {
                #expect(try await ServerCard.fetch(from: URL(string: address)!, session: session) == validCard)
            }
        }
    }
#endif
