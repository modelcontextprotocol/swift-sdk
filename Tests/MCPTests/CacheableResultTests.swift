import Foundation
import Testing

@testable import MCP

@Suite("Cacheable result tests")
struct CacheableResultTests {
    @Test("July result fields decode for each cacheable method")
    func decodesCacheFields() throws {
        let decoder = JSONDecoder()

        let tools = try decoder.decode(ListTools.Result.self, from: Data(#"{"tools":[],"ttlMs":300000,"cacheScope":"public"}"#.utf8))
        #expect(tools.ttlMs == 300000)
        #expect(tools.cacheScope == .public)

        let prompts = try decoder.decode(ListPrompts.Result.self, from: Data(#"{"prompts":[],"ttlMs":0,"cacheScope":"private"}"#.utf8))
        #expect(prompts.ttlMs == 0)
        #expect(prompts.cacheScope == .private)

        let resources = try decoder.decode(ListResources.Result.self, from: Data(#"{"resources":[],"ttlMs":1000,"cacheScope":"private"}"#.utf8))
        #expect(resources.ttlMs == 1000)
        #expect(resources.cacheScope == .private)

        let read = try decoder.decode(ReadResource.Result.self, from: Data(#"{"contents":[],"ttlMs":500,"cacheScope":"private"}"#.utf8))
        #expect(read.ttlMs == 500)
        #expect(read.cacheScope == .private)

        let templates = try decoder.decode(ListResourceTemplates.Result.self, from: Data(#"{"resourceTemplates":[],"ttlMs":60000,"cacheScope":"public"}"#.utf8))
        #expect(templates.ttlMs == 60000)
        #expect(templates.cacheScope == .public)
    }

    @Test("Server results emit cache fields in JSON-RPC responses")
    func encodesCacheFields() throws {
        try expectCacheFields(
            ListTools.response(id: "tools", result: .init(tools: [], ttlMs: 1000, cacheScope: .public)),
            resultKey: "tools", scope: "public")
        try expectCacheFields(
            ListPrompts.response(id: "prompts", result: .init(prompts: [], ttlMs: 1000, cacheScope: .private)),
            resultKey: "prompts", scope: "private")
        try expectCacheFields(
            ListResources.response(id: "resources", result: .init(resources: [], ttlMs: 1000, cacheScope: .private)),
            resultKey: "resources", scope: "private")
        try expectCacheFields(
            ReadResource.response(id: "read", result: .init(contents: [], ttlMs: 1000, cacheScope: .private)),
            resultKey: "contents", scope: "private")
        try expectCacheFields(
            ListResourceTemplates.response(id: "templates", result: .init(templates: [], ttlMs: 1000, cacheScope: .public)),
            resultKey: "resourceTemplates", scope: "public")
    }

    @Test("Older results without cache fields still decode and do not gain a cache policy")
    func decodesLegacyResults() throws {
        let decoder = JSONDecoder()
        let tools = try decoder.decode(ListTools.Result.self, from: Data(#"{"tools":[]}"#.utf8))
        let prompts = try decoder.decode(ListPrompts.Result.self, from: Data(#"{"prompts":[]}"#.utf8))
        let resources = try decoder.decode(ListResources.Result.self, from: Data(#"{"resources":[]}"#.utf8))
        let read = try decoder.decode(ReadResource.Result.self, from: Data(#"{"contents":[]}"#.utf8))
        let templates = try decoder.decode(ListResourceTemplates.Result.self, from: Data(#"{"resourceTemplates":[]}"#.utf8))

        #expect(tools.ttlMs == nil && tools.cacheScope == nil)
        #expect(prompts.ttlMs == nil && prompts.cacheScope == nil)
        #expect(resources.ttlMs == nil && resources.cacheScope == nil)
        #expect(read.ttlMs == nil && read.cacheScope == nil)
        #expect(templates.ttlMs == nil && templates.cacheScope == nil)

        let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools)) as? [String: Any]
        #expect(legacyJSON?["ttlMs"] == nil)
        #expect(legacyJSON?["cacheScope"] == nil)
    }

    @Test("Unknown cache scope is rejected")
    func rejectsUnknownScope() {
        let data = Data(#"{"tools":[],"ttlMs":1000,"cacheScope":"shared"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ListTools.Result.self, from: data)
        }
    }

    @Test("Negative TTL is immediately stale and never emitted")
    func normalizesNegativeTTL() throws {
        let data = Data(#"{"tools":[],"ttlMs":-1,"cacheScope":"private"}"#.utf8)
        let decoded = try JSONDecoder().decode(ListTools.Result.self, from: data)
        #expect(decoded.ttlMs == 0)

        let result = ListTools.Result(tools: [], ttlMs: -100, cacheScope: .private)
        #expect(result.ttlMs == 0)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(json["ttlMs"] as? Int == 0)
    }

    private func expectCacheFields<M: MCP.Method>(
        _ response: Response<M>, resultKey: String, scope: String
    ) throws {
        let data = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(result[resultKey] as? [Any] != nil)
        #expect(result["ttlMs"] as? Int == 1000)
        #expect(result["cacheScope"] as? String == scope)
    }
}
