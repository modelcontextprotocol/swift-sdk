import Crypto
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Glibc)
    import Glibc
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
        ("version", "1.0.0+build.x", true), ("version", "1.0.0-alpha.x", true), ("version", "1.x.0-beta", false),
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
        // The path keeps its encoding.
        #expect(url("https://h/a%2Fb/mcp") == "https://h/a%2Fb/mcp/server-card")
        #expect(url("https://h/a%20b/mcp/") == "https://h/a%20b/mcp/server-card")
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
        // The message names the template, not a value, which can be a secret.
        #expect { _ = try undeclared.url(resolving: ["base": "javascript:s3cret"]) } throws: {
            guard let error = $0 as? ServerCardError else { return false }
            return error.reason == .invalidCard && error.message.contains("{base}/mcp")
                && !error.message.contains("s3cret") && !error.localizedDescription.contains("s3cret")
        }
        // `localizedDescription` is the message.
        #expect((ServerCardError(.tooLarge, "too large") as any Error).localizedDescription == "too large")
    }

    @Test("A value cannot change the host, path or query of the URL")
    func templateValuesAreEncoded() throws {
        let remote = ServerCard.Remote(type: .streamableHTTP, url: "https://{tenant}.example.com/mcp/{path}")
        for tenant in ["evil.com/x?", "evil.com#", "user@evil.com", "evil.com:443/"] {
            do {
                let resolved = try remote.url(resolving: ["tenant": tenant, "path": "a"])
                #expect(resolved.host?.hasSuffix(".example.com") == true, "\(tenant): \(resolved)")
                #expect(resolved.path == "/mcp/a" && resolved.query == nil && resolved.user == nil, "\(resolved)")
            } catch {
                #expect((error as? ServerCardError)?.reason == .invalidCard)
            }
        }
        let resolved = try remote.url(resolving: ["tenant": "acme", "path": "a/b?c=d#e"])
        #expect(resolved.absoluteString == "https://acme.example.com/mcp/a%2Fb%3Fc%3Dd%23e")
        #expect(try remote.url(resolving: ["tenant": "a-b_c.d~e", "path": "x"]).host == "a-b_c.d~e.example.com")
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
        #expect(head?.headers["Content-Length"] == validator.response(to: request())?.bodyData.map { String($0.count) })
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

    @Test("A card that does not encode is refused instead of served empty")
    func unencodableCard() {
        var card = validCard
        var meta = Metadata()
        meta.fields["ratio"] = .double(.infinity)
        card._meta = meta
        #expect { _ = try ServerCardValidator(card: card) } throws: {
            ($0 as? ServerCardError)?.reason == .invalidCard
        }
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
        #expect(await stateful.handleRequest(request("HEAD")).statusCode == 200)
        #expect(await stateful.handleRequest(request("HEAD", headers: ["If-None-Match": etag])).statusCode == 304)
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

        @Test("A body larger than the limit is not read to its end")
        func streamedBodyIsCutOff() async throws {
            // 40 MiB in 64 KiB chunks, about 1.3 s: a loaded machine may let a few
            // MiB through before the cancellation reaches the mock.
            let (session, log) = CardURLProtocol.session([url.absoluteString: .stream(chunk: 64 << 10, count: 640)])
            await #expect { _ = try await ServerCard.fetch(from: url, session: session) } throws: {
                ($0 as? ServerCardError)?.reason == .tooLarge
            }
            let delivered = await log.deliveredWhenStopped()
            #expect(delivered > ServerCard.maximumSize)
            #expect(delivered < 20 << 20, "\(delivered) bytes were delivered")
        }

        @Test("A Content-Length over the limit is refused before the body is read")
        func contentLength() async throws {
            let (session, log) = CardURLProtocol.session([
                url.absoluteString: .stream(chunk: 64 << 10, count: 160, contentLength: 10 << 20, delay: 0.2)
            ])
            await #expect { _ = try await ServerCard.fetch(from: url, session: session) } throws: {
                ($0 as? ServerCardError)?.reason == .tooLarge
            }
            // The body starts 0.2 s after the headers; the fetch refuses on the headers.
            #expect(await log.deliveredWhenStopped() < ServerCard.maximumSize)
        }

        // swift-corelibs-foundation cannot redirect a URLProtocol's request
        // (it traps); there a loopback server tests them instead.
        #if !canImport(FoundationNetworking)
            @Test("Redirects are checked before they are followed", arguments: [
                ["https://example.com/card", "http://127.0.0.1/x"],
                ["https://example.com/card", "http://10.0.0.5/"],
                ["https://example.com/card", "https://10.0.0.5/card"],
                ["https://example.com/card", "https://[fd00::1]/card"],
                ["https://example.com/card", "http://example.com/card", "https://other.example/card"],
                ["http://127.0.0.1:3000/card", "http://example.com/card"],
                ["http://127.0.0.1:3000/card", "http://192.168.1.1/card"],
            ])
            func redirects(chain: [String]) async throws {
                var steps: [String: CardURLProtocol.Step] = [:]
                for (from, to) in zip(chain, chain.dropFirst()) { steps[from] = .redirect(to) }
                steps[chain.last!] = .card
                let (session, log) = CardURLProtocol.session(steps)
                await #expect { _ = try await ServerCard.fetch(from: URL(string: chain[0])!, session: session) } throws: {
                    ($0 as? ServerCardError)?.reason == .insecureURL
                }
                #expect(log.requested == [chain[0]])
            }

            @Test("Redirects to https, and from loopback http to loopback http, are followed")
            func allowedRedirects() async throws {
                for chain in [
                    ["https://example.com/card", "https://cards.example/card"],
                    ["http://127.0.0.1:3000/card", "http://localhost:3000/server-card"],
                ] {
                    let (session, log) = CardURLProtocol.session([chain[0]: .redirect(chain[1]), chain[1]: .card])
                    #expect(try await ServerCard.fetch(from: URL(string: chain[0])!, session: session) == validCard)
                    #expect(log.requested == chain)
                }
            }
        #else
            @Test("Redirects of a real session are checked before they are followed")
            func loopbackRedirects() async throws {
                let card = try JSONEncoder().encode(validCard)
                let server = try LoopbackHTTPServer()
                defer { server.stop() }
                let base = "http://127.0.0.1:\(server.port)"
                server.routes = [
                    "/private": (302, ["Location": "http://0.0.0.0:\(server.port)/card"], Data()),
                    "/loopback": (302, ["Location": "\(base)/card"], Data()),
                    "/card": (200, [:], card),
                ]
                await #expect { _ = try await ServerCard.fetch(from: URL(string: "\(base)/private")!) } throws: {
                    ($0 as? ServerCardError)?.reason == .insecureURL
                }
                #expect(server.requested == ["/private"])
                #expect(try await ServerCard.fetch(from: URL(string: "\(base)/loopback")!) == validCard)
                #expect(server.requested == ["/private", "/loopback", "/card"])
            }
        #endif

        @Test("http is allowed on a loopback host")
        func loopback() async throws {
            let session = await serve(body: try JSONEncoder().encode(validCard))
            for address in ["http://127.0.0.1:3000/mcp/server-card", "http://localhost/mcp/server-card", "http://[::1]:8080/server-card"] {
                #expect(try await ServerCard.fetch(from: URL(string: address)!, session: session) == validCard)
            }
        }
    }

    /// Serves cards, redirects and long bodies by URL, and records the
    /// requests and the bytes delivered.
    private final class CardURLProtocol: URLProtocol, @unchecked Sendable {
        enum Step: Sendable {
            case card
            case redirect(String)
            case stream(chunk: Int, count: Int, contentLength: Int? = nil, delay: TimeInterval = 0)
        }

        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [String] = []
            private var bytes = 0
            private var stopped = false

            var requested: [String] { lock.withLock { urls } }
            func request(_ url: String) { lock.withLock { urls.append(url) } }
            func delivered(_ count: Int) { lock.withLock { bytes += count } }
            func stop() { lock.withLock { stopped = true } }

            /// The bytes delivered, once the loading stopped or all chunks went out.
            func deliveredWhenStopped() async -> Int {
                for _ in 0..<200 {
                    if lock.withLock({ stopped }) { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return lock.withLock { bytes }
            }
        }

        private static let keyHeader = "X-Card-Key"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var scripts: [String: ([String: Step], Log)] = [:]

        static func session(_ steps: [String: Step]) -> (URLSession, Log) {
            let key = UUID().uuidString
            let log = Log()
            lock.withLock { scripts[key] = (steps, log) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CardURLProtocol.self]
            configuration.httpAdditionalHeaders = [keyHeader: key]
            return (URLSession(configuration: configuration), log)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        /// swift-corelibs-foundation traps on a callback after `stopLoading()`.
        private let stateLock = NSLock()
        private var stopped = false
        private var log: Log?
        private var isStopped: Bool { stateLock.withLock { stopped } }

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
            guard let url = request.url, let (steps, log) = Self.lock.withLock({ Self.scripts[key] }),
                let step = steps[url.absoluteString]
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            stateLock.withLock { self.log = log }
            log.request(url.absoluteString)
            switch step {
            case .card:
                let body = try! JSONEncoder().encode(validCard)
                respond(url, status: 200, headers: [:])
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let target):
                let response = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
                var next = URLRequest(url: URL(string: target)!)
                next.setValue(key, forHTTPHeaderField: Self.keyHeader)
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                // A followed redirect stops this loading; a refused one gets
                // the 3xx as the response.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    guard !self.isStopped else { return }
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    guard !self.isStopped else { return }
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            case .stream(let chunk, let count, let contentLength, let delay):
                respond(url, status: 200, headers: contentLength.map { ["Content-Length": String($0)] } ?? [:])
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.stream(chunk: chunk, count: count) }
            }
        }

        private func stream(chunk: Int, count: Int) {
            for _ in 0..<count {
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: chunk))
                stateLock.withLock { log }?.delivered(chunk)
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard !isStopped else { return }
            stateLock.withLock { log }?.stop()
            client?.urlProtocolDidFinishLoading(self)
        }

        private func respond(_ url: URL, status: Int, headers: [String: String]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        override func stopLoading() {
            let log = stateLock.withLock { () -> Log? in
                stopped = true
                return self.log
            }
            log?.stop()
        }
    }

    #if canImport(FoundationNetworking)
        /// An HTTP/1.1 server on every IPv4 address of the host, answering each
        /// path with a fixed response, one request per connection.
        private final class LoopbackHTTPServer: @unchecked Sendable {
            typealias Route = (status: Int, headers: [String: String], body: Data)

            let port: Int
            private let socket: Int32
            private let lock = NSLock()
            private var paths: [String] = []
            private var table: [String: Route] = [:]
            private var stopped = false

            var requested: [String] { lock.withLock { paths } }
            var routes: [String: Route] {
                get { lock.withLock { table } }
                set { lock.withLock { table = newValue } }
            }

            init() throws {
                let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                self.socket = socket
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr = in_addr(s_addr: INADDR_ANY)
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        bind(socket, address, length) == 0 && listen(socket, 16) == 0
                            && getsockname(socket, address, &length) == 0
                    }
                }
                guard bound else { throw URLError(.cannotConnectToHost) }
                port = Int(UInt16(bigEndian: address.sin_port))
                let thread = Thread { [self] in serve() }
                thread.start()
            }

            /// Stops accepting: a connection wakes the blocked `accept`.
            func stop() {
                lock.withLock { stopped = true }
                let wake = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = UInt16(port).bigEndian
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                _ = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                close(wake)
            }

            private func serve() {
                defer { close(socket) }
                while true {
                    let connection = accept(socket, nil, nil)
                    guard connection >= 0, !lock.withLock({ stopped }) else {
                        if connection >= 0 { close(connection) }
                        return
                    }
                    answer(connection)
                    close(connection)
                }
            }

            private func answer(_ connection: Int32) {
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let count = read(connection, &buffer, buffer.count)
                    guard count > 0 else { return }
                    request.append(contentsOf: buffer[..<count])
                }
                let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let route = lock.withLock { () -> Route? in
                    paths.append(path)
                    return table[path]
                } ?? (404, [:], Data())
                var head = "HTTP/1.1 \(route.status) Status\r\nContent-Length: \(route.body.count)\r\nConnection: close\r\n"
                for (name, value) in route.headers { head += "\(name): \(value)\r\n" }
                let response = Data((head + "\r\n").utf8) + route.body
                _ = response.withUnsafeBytes { write(connection, $0.baseAddress, response.count) }
            }
        }
    #endif
#endif
