import Foundation
import MCP

// Snippets for docs/server.md: tools from Foundation Models.

// The bridge is unavailable on tvOS.
#if canImport(FoundationModels) && !os(tvOS)
    import FoundationModels

    // snippet: generable-tool
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable(description: "A city and the number of days to forecast")
    struct ForecastQuery {
        @Guide(description: "City name")
        var city: String
        @Guide(description: "Days ahead", .range(1...7))
        var days: Int
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct DailyForecast {
        var city: String
        var highs: [Double]
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    func registerGenerableTool(on server: Server) async throws {
        let forecast = try MCP.Tool(
            name: "get_daily_forecast",
            description: "Daily highs for a city",
            arguments: ForecastQuery.self,
            output: DailyForecast.self)

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [forecast])
        }
        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case forecast.name:
                // Arguments that do not match answer -32602. Check @Guide
                // bounds in the handler: decoding checks types, not guides.
                let query = try params.arguments(as: ForecastQuery.self)
                guard (1...7).contains(query.days) else {
                    return CallTool.Result(
                        content: [.text(text: "days must be between 1 and 7")],
                        isError: true)
                }
                let highs = (1...query.days).map { 18 + Double($0) }
                // structuredContent, and its JSON as text.
                return try CallTool.Result(DailyForecast(city: query.city, highs: highs))
            default:
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
        }
    }
    // endsnippet

    // snippet: foundation-models-tool
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct UVIndexTool: FoundationModels.Tool {
        let name = "get_uv_index"
        let description = "Today's UV index for a city"

        @Generable
        struct Arguments {
            @Guide(description: "City name")
            var city: String
        }

        func call(arguments: Arguments) async throws -> String {
            "The UV index in \(arguments.city) is 5."
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    func registerUVIndexTool(on server: Server) async throws {
        let uvIndex = UVIndexTool()
        // The same tool serves a local LanguageModelSession and MCP clients.
        let definition = try MCP.Tool(uvIndex, annotations: .init(readOnlyHint: true))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [definition])
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == uvIndex.name else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            return try await uvIndex.call(params)
        }
    }
    // endsnippet
#endif
