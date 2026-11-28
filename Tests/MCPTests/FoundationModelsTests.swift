import Foundation
import Testing

@testable import MCP

// The bridge is unavailable on tvOS.
#if canImport(FoundationModels) && !os(tvOS)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable(description: "A weather query")
    struct FMWeatherQuery {
        @Guide(description: "City name")
        var city: String
        @Guide(description: "Days ahead", .range(0...7))
        var days: Int?
        @Guide(.anyOf(["metric", "imperial"]))
        var units: String
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct FMForecast {
        var city: String
        var high: Double
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    enum FMSky {
        case sunny
        case rainy
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct FMNode {
        var name: String
        var children: [FMNode]
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct FMEchoArguments {
        var text: String
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct FMLargeIDArguments {
        var id: Int
    }

    struct FMNoSuchCity: LocalizedError {
        var errorDescription: String? { "No such city" }
    }

    struct FMInternalFailure: Error {
        let connectionString: String
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct FMCustomArguments: ConvertibleFromGeneratedContent {
        init(_ content: GeneratedContent) throws {
            throw MCPError.invalidRequest("Custom argument error")
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct FMHandBuiltOutput: ConvertibleToGeneratedContent {
        let content: GeneratedContent
        var generatedContent: GeneratedContent { content }
    }

    /// Manual `Generable` conformance using `GeneratedContent(properties:)`, which
    /// records `nil` optionals as `.null` while `DynamicGenerationSchema` declares
    /// optional properties as non-nullable and omitted from `required`.
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct FMManualForecast: Generable {
        var city: String
        var advisory: String?

        static var generationSchema: GenerationSchema {
            // Force-try is safe in tests: static valid object schema.
            try! GenerationSchema(
                root: DynamicGenerationSchema(
                    name: "FMManualForecast",
                    properties: [
                        .init(name: "city", schema: .init(type: String.self), isOptional: false),
                        .init(name: "advisory", schema: .init(type: String.self), isOptional: true),
                    ]),
                dependencies: [])
        }

        init(city: String, advisory: String? = nil) {
            self.city = city
            self.advisory = advisory
        }

        init(_ content: GeneratedContent) throws {
            self.city = try content.value(String.self, forProperty: "city")
            self.advisory = try content.value(String?.self, forProperty: "advisory")
        }

        var generatedContent: GeneratedContent {
            GeneratedContent(properties: ["city": city, "advisory": advisory])
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @Generable
    struct FMOptionalForecast {
        var city: String
        var advisory: String?
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct FMWeatherTool: FoundationModels.Tool {
        let name = "get_weather"
        let description = "Forecast for a city"

        func call(arguments: FMWeatherQuery) async throws -> FMForecast {
            switch arguments.city {
            case "Nowhere": throw FMNoSuchCity()
            case "SecretDB": throw FMInternalFailure(connectionString: "postgres://admin:secret@internal.db")
            case "NaNCity": return FMForecast(city: "NaNCity", high: .nan)
            case "Forbidden": throw MCPError.invalidRequest("Forbidden city")
            case "Cancelled": throw CancellationError()
            default: return FMForecast(city: arguments.city, high: 21.5)
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    struct FMEchoTool: FoundationModels.Tool {
        let name = "echo"
        let description = "Echoes text"

        func call(arguments: FMEchoArguments) async throws -> String { arguments.text }
    }

    private actor PageCounter {
        private(set) var cursors: [String?] = []
        private(set) var calls = 0

        func record(_ cursor: String?) -> Int {
            cursors.append(cursor)
            calls += 1
            return calls
        }
    }

    private actor ArgumentRecorder {
        private(set) var recorded: [[String: Value]] = []

        func record(_ arguments: [String: Value]) {
            recorded.append(arguments)
        }
    }

    @Suite("Foundation Models")
    struct FoundationModelsTests {
        // MARK: - Value and GeneratedContent

        @Test("Value and GeneratedContent convert both ways")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func valueRoundTrip() throws {
            #if _pointerBitWidth(_64)
                let maxExactInt: Value = 9_007_199_254_740_991
            #else
                let maxExactInt: Value = .int(Int(Int32.max))
            #endif
            let value: Value = [
                "string": "text",
                "int": maxExactInt,
                "double": 2.5,
                "bool": true,
                "null": nil,
                "array": [1, "two", ["three": 3]],
            ]
            #expect(Value(GeneratedContent(value)) == value)
        }

        @Test("An integral number becomes an int, data becomes its data URL")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func valueConversionEdges() throws {
            #expect(Value(GeneratedContent(Value.double(2))) == .int(2))
            #expect(Value(GeneratedContent(kind: .number(1e300))) == .double(1e300))
            let data = Value.data(mimeType: "text/plain", Data("hi".utf8))
            #expect(GeneratedContent(data).kind == .string(Data("hi".utf8).dataURLEncoded(mimeType: "text/plain")))
            let object = GeneratedContent(Value.object(["b": 1, "a": 2]))
            #expect(object.jsonString == #"{"a": 2, "b": 1}"#)
        }

        // MARK: - Server

        @Test("A Generable type is a tool's input schema")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolFromArguments() throws {
            let tool = try MCP.Tool(
                name: "get_weather", description: "Forecast for a city", arguments: FMWeatherQuery.self)
            expectWire(
                try Value(tool),
                matches: [
                    "name": "get_weather",
                    "description": "Forecast for a city",
                    "inputSchema": [
                        "type": "object",
                        "description": "A weather query",
                        "additionalProperties": false,
                        "properties": [
                            "city": ["type": "string", "description": "City name"],
                            "days": ["type": "integer", "description": "Days ahead", "minimum": 0, "maximum": 7],
                            "units": ["type": "string", "enum": ["metric", "imperial"]],
                        ],
                        "required": ["city", "units"],
                        "x-order": ["city", "days", "units"],
                    ],
                ])
            #expect(tool.outputSchema == nil)
        }

        @Test("A Generable output type is a tool's output schema")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolFromArgumentsAndOutput() throws {
            let tool = try MCP.Tool(
                name: "get_weather", description: nil, arguments: FMWeatherQuery.self, output: FMForecast.self)
            expectWire(
                try #require(tool.outputSchema),
                matches: [
                    "type": "object",
                    "properties": ["city": ["type": "string"], "high": ["type": "number"]],
                    "required": ["city", "high"],
                ])
        }

        @Test("Arguments or output that are not an object throw")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolFromNonObject() throws {
            let error = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try MCP.Tool(name: "sky", description: nil, arguments: FMSky.self)
            }
            #expect(error?.pointer == "")
            #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try MCP.Tool(name: "sky", description: nil, arguments: FMWeatherQuery.self, output: String.self)
            }
        }

        @Test("A FoundationModels tool is an MCP tool")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolFromFoundationModelsTool() throws {
            let tool = try MCP.Tool(FMWeatherTool(), annotations: .init(readOnlyHint: true))
            #expect(tool.name == "get_weather")
            #expect(tool.description == "Forecast for a city")
            #expect(tool.annotations.readOnlyHint == true)
            let expected = try MCP.Tool(
                name: "get_weather", description: nil, arguments: FMWeatherQuery.self, output: FMForecast.self)
            #expect(tool.inputSchema == expected.inputSchema)
            #expect(tool.outputSchema == expected.outputSchema)

            // A String output has no output schema.
            #expect(try MCP.Tool(FMEchoTool()).outputSchema == nil)
        }

        @Test("Arguments decode into a Generable type")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func argumentsDecode() throws {
            let parameters = CallTool.Parameters(
                name: "get_weather", arguments: ["city": "Zürich", "units": "metric", "days": 2])
            let query = try parameters.arguments(as: FMWeatherQuery.self)
            #expect(query.city == "Zürich")
            #expect(query.days == 2)
            #expect(query.units == "metric")
        }

        @Test("Arguments that do not match or exceed Double integer precision answer -32602")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func argumentsMismatch() throws {
            for arguments: [String: Value]? in [["city": "Zürich"], ["city": 1, "units": "metric"], nil] {
                let parameters = CallTool.Parameters(name: "get_weather", arguments: arguments)
                let error = #expect(throws: MCPError.self) {
                    try parameters.arguments(as: FMWeatherQuery.self)
                }
                #expect(error?.code == -32602)
            }

            // 32-bit Int bounds decode on every architecture (including watchOS arm64_32).
            for id in [1, -1, Int(Int32.max), Int(Int32.min)] {
                let valid = CallTool.Parameters(name: "id_tool", arguments: ["id": .int(id)])
                #expect(try valid.arguments(as: FMLargeIDArguments.self).id == id)
            }
            #expect(CallTool.Parameters.isExactInDouble(1))
            #expect(CallTool.Parameters.isExactInDouble(Int64(Int32.max)))
            #expect(CallTool.Parameters.isExactInDouble(Int64(Int32.min)))
            #expect(CallTool.Parameters.isExactInDouble(Int64(1) << 53))
            #expect(!CallTool.Parameters.isExactInDouble((Int64(1) << 53) + 1))
            #expect(!CallTool.Parameters.isExactInDouble(-(Int64(1) << 53) - 1))
            #expect(JSONSchemaConverter.maxIntegerGuideMagnitude == (Int64(1) << 53) - 1)

            #if _pointerBitWidth(_64)
                // Exact boundary 2^53 succeeds; 2^53 + 1 (top-level or nested) is rejected rather than rounded.
                let exact = CallTool.Parameters(name: "id_tool", arguments: ["id": .int(1 << 53)])
                #expect(try exact.arguments(as: FMLargeIDArguments.self).id == (1 << 53))
                for badIntArgs: [String: Value] in [
                    ["id": .int((1 << 53) + 1)],
                    ["id": 1, "nested": ["list": [.int((1 << 53) + 1)]]],
                ] {
                    let imprecise = CallTool.Parameters(name: "id_tool", arguments: badIntArgs)
                    let precisionError = #expect(throws: MCPError.self) {
                        try imprecise.arguments(as: FMLargeIDArguments.self)
                    }
                    #expect(precisionError?.code == -32602)
                }
            #endif

            // Non-finite numbers (top-level or nested in objects/arrays) answer -32602.
            for badDoubleArgs: [String: Value] in [
                ["id": .double(.nan)],
                ["id": 1, "nested": ["values": [.double(.infinity)]]],
                ["id": 1, "nested": [.double(-.infinity)]],
            ] {
                let nonFinite = CallTool.Parameters(name: "id_tool", arguments: badDoubleArgs)
                let nonFiniteError = #expect(throws: MCPError.self) {
                    try nonFinite.arguments(as: FMLargeIDArguments.self)
                }
                #expect(nonFiniteError?.code == -32602)
            }

            // Custom ConvertibleFromGeneratedContent throwing an MCPError preserves its code.
            let custom = CallTool.Parameters(name: "custom", arguments: [:])
            let rethrown = #expect(throws: MCPError.self) {
                try custom.arguments(as: FMCustomArguments.self)
            }
            #expect(rethrown == .invalidRequest("Custom argument error"))
        }

        @Test("A structure result has structured content, JSON text, metadata, and throws on NaN")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func resultFromStructure() throws {
            let meta = Metadata(additionalFields: ["trace": "1"])
            let result = try CallTool.Result(
                FMForecast(city: "Zürich", high: 21.5), isError: false, _meta: meta)
            #expect(result.structuredContent == ["city": "Zürich", "high": 21.5])
            guard case .text(let text, _, _) = try #require(result.content.first) else {
                Issue.record("Expected text content")
                return
            }
            #expect(try wireJSON(text) == ["city": "Zürich", "high": 21.5])
            #expect(result.isError == false)
            #expect(result._meta == meta)

            // Non-finite numbers throw EncodingError instead of trapping inside FoundationModels.
            #expect(throws: EncodingError.self) {
                try CallTool.Result(FMForecast(city: "Zürich", high: .nan))
            }
            #expect(throws: EncodingError.self) {
                try CallTool.Result(Double.infinity)
            }

            // Hand-built GeneratedContent with inconsistent orderedKeys encodes safely via Value.
            let inconsistent = FMHandBuiltOutput(
                content: GeneratedContent(
                    kind: .structure(properties: ["a": .init(kind: .number(1))], orderedKeys: ["a", "missing"])))
            let built = try CallTool.Result(inconsistent)
            #expect(built.structuredContent == ["a": 1])

            // Nil optionals omit the property rather than sending `"advisory": null`, which
            // would violate the non-nullable property in the derived `outputSchema` (both for
            // `@Generable` types and for manual `GeneratedContent(properties:)` conformances).
            let manualTool = try MCP.Tool(
                name: "forecast", description: nil, arguments: FMWeatherQuery.self, output: FMManualForecast.self)
            #expect(
                manualTool.outputSchema?.objectValue?["properties"]?.objectValue?["advisory"]
                    == ["type": "string"])
            #expect(manualTool.outputSchema?.objectValue?["required"] == ["city"])

            let manualNil = try CallTool.Result(FMManualForecast(city: "Zürich", advisory: nil))
            #expect(manualNil.structuredContent == ["city": "Zürich"])
            guard case .text(let manualText, _, _) = try #require(manualNil.content.first) else {
                Issue.record("Expected text content")
                return
            }
            #expect(try wireJSON(manualText) == ["city": "Zürich"])

            let macroNil = try CallTool.Result(FMOptionalForecast(city: "Zürich", advisory: nil))
            #expect(macroNil.structuredContent == ["city": "Zürich"])

            let nestedNil = try CallTool.Result([FMManualForecast(city: "Bern", advisory: nil)])
            #expect(nestedNil.content == [.text(text: #"[{"city":"Bern"}]"#)])
        }

        @Test("A string result is text, another value its JSON")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func resultFromScalars() throws {
            let meta = Metadata(additionalFields: ["k": "v"])
            let text = try CallTool.Result("Sunny", isError: true, _meta: meta)
            #expect(text.content == [.text(text: "Sunny")])
            #expect(text.structuredContent == nil)
            #expect(text.isError == true)
            #expect(text._meta == meta)

            let number = try CallTool.Result(42, isError: false, _meta: meta)
            #expect(number.content == [.text(text: "42")])
            #expect(number.structuredContent == nil)
            #expect(number.isError == false)
            #expect(number._meta == meta)

            let list = try CallTool.Result(["a", "b"])
            #expect(list.content == [.text(text: #"["a","b"]"#)])
        }

        @Test("A FoundationModels tool serves tools/call")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolCall() async throws {
            let tool = FMWeatherTool()
            let result = try await tool.call(
                CallTool.Parameters(name: tool.name, arguments: ["city": "Zürich", "units": "metric"]))
            #expect(result.structuredContent == ["city": "Zürich", "high": 21.5])
            #expect(result.isError == nil)
        }

        @Test("Tool errors use localizedDescription without leaking internals; MCPError and cancellation throw")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func toolCallErrors() async throws {
            let tool = FMWeatherTool()
            func call(_ city: String) async throws -> CallTool.Result {
                try await tool.call(
                    CallTool.Parameters(name: tool.name, arguments: ["city": .string(city), "units": "metric"]))
            }

            let failed = try await call("Nowhere")
            #expect(failed.isError == true)
            #expect(failed.content == [.text(text: "No such city")])
            #expect(failed.structuredContent == nil)

            // A non-LocalizedError sends neither its stored properties nor the module and type
            // names that the bridged `localizedDescription` contains.
            let internalErr = try await call("SecretDB")
            #expect(internalErr.isError == true)
            #expect(internalErr.content == [.text(text: "The tool failed.")])

            // Non-finite output becomes an isError result rather than crashing the server.
            let nanResult = try await call("NaNCity")
            #expect(nanResult.isError == true)

            let forbidden = await #expect(throws: MCPError.self) { try await call("Forbidden") }
            #expect(forbidden == .invalidRequest("Forbidden city"))
            await #expect(throws: CancellationError.self) { try await call("Cancelled") }

            let invalid = await #expect(throws: MCPError.self) {
                try await tool.call(CallTool.Parameters(name: tool.name, arguments: ["city": "Zürich"]))
            }
            #expect(invalid?.code == -32602)
        }

        // MARK: - JSON Schema to GenerationSchema

        /// `schema` converted to a generation schema, encoded back to JSON Schema.
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        private func converted(_ schema: Value, name: String = "t") throws -> Value {
            try Value.preservingStrings(GenerationSchema(jsonSchema: schema, name: name))
        }

        /// The schema of property `name` of a converted object.
        private func property(_ name: String, of schema: Value) -> Value? {
            schema.objectValue?["properties"]?.objectValue?[name]
        }

        @Test("A plain MCP input schema converts (#169)")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func plainSchema() throws {
            let schema = try converted(
                [
                    "type": "object",
                    "description": "Weather",
                    "properties": [
                        "city": ["type": "string", "description": "City name"],
                        "days": ["type": "integer"],
                    ],
                    "required": ["city"],
                ],
                name: "get_weather")
            expectWire(
                schema,
                matches: [
                    "type": "object",
                    "description": "Weather",
                    "properties": [
                        "city": ["type": "string", "description": "City name"],
                        "days": ["type": "integer"],
                    ],
                    "required": ["city"],
                    "x-order": ["city", "days"],
                ])
        }

        @Test("Empty, passthrough, typeless, and $ref object roots convert; typed root maps throw")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func rootForms() throws {
            for root: Value in [
                ["type": "object"],
                [:],
                ["properties": ["a": ["type": "string"]]],
                ["type": ["object"], "properties": ["a": ["type": "string"]]],
                ["type": "object", "properties": [:], "additionalProperties": false],
                ["type": "object", "additionalProperties": true],
                ["type": "object", "additionalProperties": [:]],
                [
                    "$ref": "#/definitions/Args",
                    "definitions": ["Args": ["type": "object", "properties": ["x": ["type": "integer"]]]],
                ],
                ["allOf": [["type": "object", "properties": ["x": ["type": "integer"]]]]],
            ] {
                let schema = try converted(root)
                #expect(schema.objectValue?["type"] == "object")
            }

            let mapError = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try converted(["type": "object", "additionalProperties": ["type": "string"]])
            }
            #expect(mapError?.pointer == "/additionalProperties")

            let minPropsError = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try converted(["type": "object", "minProperties": 1])
            }
            #expect(minPropsError?.pointer == "/minProperties")
        }

        @Test("Properties follow deduplicated x-order, then the other keys in sorted order")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func propertyOrder() throws {
            let schema = try converted([
                "type": "object",
                "properties": ["a": ["type": "string"], "b": ["type": "string"], "c": ["type": "string"]],
                "x-order": ["c", "c", "missing", "a", "c"],
            ])
            #expect(schema.objectValue?["x-order"] == ["c", "a", "b"])
        }

        @Test("Strings keep enum and const; pattern is dropped for guided-generation safety")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func strings() throws {
            let schema = try converted([
                "type": "object",
                "properties": [
                    "choice": ["type": "string", "enum": ["a", "b"]],
                    "untyped": ["enum": ["x", nil]],
                    "fixed": ["const": "k"],
                    "word": ["type": "string", "pattern": "^[a-z]+$"],
                    "broken": ["type": "string", "pattern": "[", "format": "email", "minLength": 2],
                ],
                "required": ["choice", "untyped", "fixed", "word", "broken"],
            ])
            #expect(property("choice", of: schema) == ["type": "string", "enum": ["a", "b"]])
            #expect(property("untyped", of: schema) == ["type": "string", "enum": ["x"]])
            #expect(property("fixed", of: schema) == ["const": "k"])
            #expect(property("word", of: schema) == ["type": "string"])
            #expect(property("broken", of: schema) == ["type": "string"])
            #expect(schema.objectValue?["required"] == ["broken", "choice", "fixed", "word"])
        }

        @Test("Numbers keep safe bounds, handle draft-04 exclusive booleans, and drop extreme bounds")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func numbers() throws {
            #if _pointerBitWidth(_64)
                let maxSafeInt = (1 << 53) - 1
                let extremeIntBound: Value = .int(Int.min)
            #else
                let maxSafeInt = Int(Int32.max)
                let extremeIntBound: Value = .double(-9_223_372_036_854_775_808.0)
            #endif
            let schema = try converted([
                "type": "object",
                "properties": [
                    "range": ["type": "integer", "minimum": 1, "maximum": 5],
                    "exclusive": ["type": "integer", "exclusiveMinimum": 0, "exclusiveMaximum": 10],
                    "exclFrac": ["type": "integer", "exclusiveMinimum": 0.5],
                    "boolExclInt": ["type": "integer", "minimum": 1, "exclusiveMinimum": true],
                    "boolExclFracLow": ["type": "integer", "minimum": 1.5, "exclusiveMinimum": true],
                    "boolExclFracHigh": ["type": "integer", "maximum": 2.5, "exclusiveMaximum": true],
                    "low": ["type": "integer", "minimum": 1.5, "maximum": 4.7],
                    "safeInt": ["type": "integer", "minimum": .int(-maxSafeInt), "maximum": .int(maxSafeInt)],
                    "int64Min": ["type": "integer", "minimum": extremeIntBound],
                    "ratio": ["type": "number", "exclusiveMinimum": 0.5, "maximum": 2],
                    "high": ["type": "number", "maximum": 2.5],
                    "float64": [
                        "type": "number",
                        "minimum": .double(-Double.greatestFiniteMagnitude),
                        "maximum": .double(Double.greatestFiniteMagnitude),
                    ],
                    "flag": ["type": "boolean"],
                    "numbers": ["enum": [1, 2, 3]],
                    "mixedEnum": ["enum": [1, "a"]],
                    "intConst": ["const": 3],
                ],
            ])
            #expect(property("range", of: schema) == ["type": "integer", "minimum": 1, "maximum": 5])
            #expect(property("exclusive", of: schema) == ["type": "integer", "minimum": 1, "maximum": 9])
            #expect(property("exclFrac", of: schema) == ["type": "integer", "minimum": 1])
            #expect(property("boolExclInt", of: schema) == ["type": "integer", "minimum": 2])
            #expect(property("boolExclFracLow", of: schema) == ["type": "integer", "minimum": 2])
            #expect(property("boolExclFracHigh", of: schema) == ["type": "integer", "maximum": 2])
            #expect(property("low", of: schema) == ["type": "integer", "minimum": 2, "maximum": 4])
            #expect(
                property("safeInt", of: schema)
                    == ["type": "integer", "minimum": .int(-maxSafeInt), "maximum": .int(maxSafeInt)])
            #expect(property("int64Min", of: schema) == ["type": "integer"])
            expectWire(
                try #require(property("ratio", of: schema)),
                matches: ["type": "number", "minimum": 0.5, "maximum": 2])
            expectWire(try #require(property("high", of: schema)), matches: ["type": "number", "maximum": 2.5])
            #expect(property("float64", of: schema) == ["type": "number"])
            #expect(property("flag", of: schema) == ["type": "boolean"])
            #expect(property("numbers", of: schema) == ["type": "integer"])
            #expect(property("mixedEnum", of: schema) == ["$ref": "#/$defs/GeneratedContent"])
            #expect(property("intConst", of: schema) == ["type": "integer"])
        }

        @Test("Arrays keep items, clamp negative or huge maxItems, handle items:false, and reject huge minItems")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func arrays() throws {
            let schema = try converted([
                "type": "object",
                "properties": [
                    "tags": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3],
                    "maxOnly": ["type": "array", "items": ["type": "integer"], "maxItems": 2],
                    "hugeMax": ["type": "array", "items": ["type": "string"], "maxItems": 1_000_000],
                    "inferred": ["items": ["type": "string"]],
                    "closedEmpty": ["type": "array", "items": false],
                    "closedTuple": [
                        "type": "array",
                        "prefixItems": [["type": "string"], ["type": "integer"]],
                        "items": false,
                    ],
                    "numberTuple": [
                        "type": "array",
                        "prefixItems": [["type": "number"], ["type": "number"]],
                        "items": false,
                    ],
                    "legacyTuple": ["type": "array", "items": [["type": "string"]]],
                    "anything": ["type": "array"],
                ],
            ])
            #expect(
                property("tags", of: schema)
                    == ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3])
            #expect(
                property("maxOnly", of: schema)
                    == ["type": "array", "items": ["type": "integer"], "maxItems": 2])
            #expect(property("hugeMax", of: schema) == ["type": "array", "items": ["type": "string"]])
            #expect(property("inferred", of: schema) == ["type": "array", "items": ["type": "string"]])
            #expect(
                property("closedEmpty", of: schema)
                    == ["type": "array", "items": ["type": "string"], "maxItems": 0])
            #expect(
                property("closedTuple", of: schema)
                    == ["type": "array", "items": ["$ref": "#/$defs/GeneratedContent"], "maxItems": 2])
            #expect(
                property("numberTuple", of: schema)
                    == ["type": "array", "items": ["$ref": "#/$defs/GeneratedContent"], "maxItems": 2])
            #expect(property("legacyTuple", of: schema)?.objectValue?["items"] == ["$ref": "#/$defs/GeneratedContent"])
            #expect(property("anything", of: schema)?.objectValue?["items"] == ["$ref": "#/$defs/GeneratedContent"])
        }

        @Test("anyOf, oneOf, sibling object properties, and deduplicated type lists convert")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func choices() throws {
            let schema = try converted([
                "type": "object",
                "properties": [
                    "either": ["anyOf": [["type": "string"], ["type": "integer"]], "description": "Either"],
                    "one": ["oneOf": [["type": "string"], ["type": "boolean"]]],
                    "maybe": ["anyOf": [["type": "string"], ["const": nil]]],
                    "listed": ["type": ["integer", "null"]],
                    "several": ["type": ["string", "integer", "null"]],
                    "dupTypes": ["type": ["string", "string"]],
                    "merged": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "a": ["type": "string"],
                            "b": ["type": "string"],
                        ],
                        "required": ["name"],
                        "anyOf": [["required": ["a"]], ["required": ["b"]]],
                    ],
                    "mergedRefs": [
                        "type": "object",
                        "properties": ["id": ["type": "string"]],
                        "required": ["id"],
                        "oneOf": [
                            ["$ref": "#/$defs/VariantA", "description": "First"],
                            ["$ref": "#/$defs/VariantB"],
                        ],
                    ],
                ],
                "required": ["either", "one", "maybe", "listed", "several", "dupTypes", "merged", "mergedRefs"],
                "$defs": [
                    "VariantA": [
                        "type": "object",
                        "properties": ["a": ["type": "integer"]],
                        "required": ["a"],
                    ],
                    "VariantB": [
                        "type": "object",
                        "properties": ["b": ["type": "boolean"]],
                        "required": ["b"],
                    ],
                ],
            ])
            #expect(property("either", of: schema) == ["$ref": "#/$defs/t.either", "description": "Either"])
            #expect(property("one", of: schema) == ["$ref": "#/$defs/t.one"])
            #expect(property("maybe", of: schema) == ["type": "string"])
            #expect(property("listed", of: schema) == ["type": "integer"])
            #expect(property("several", of: schema) == ["$ref": "#/$defs/t.several"])
            #expect(property("dupTypes", of: schema) == ["type": "string"])
            #expect(property("merged", of: schema) == ["$ref": "#/$defs/t.merged"])
            #expect(property("mergedRefs", of: schema) == ["$ref": "#/$defs/t.mergedRefs"])
            let defs = try #require(schema.objectValue?["$defs"]?.objectValue)
            expectWire(try #require(defs["t.either"]), matches: ["anyOf": [["type": "string"], ["type": "integer"]]])
            expectWire(try #require(defs["t.several"]), matches: ["anyOf": [["type": "string"], ["type": "integer"]]])
            expectWire(try #require(defs["t.merged.0"]), matches: ["required": ["a", "name"]])
            expectWire(try #require(defs["t.merged.1"]), matches: ["required": ["b", "name"]])
            expectWire(
                try #require(defs["t.mergedRefs.0"]),
                matches: [
                    "description": "First",
                    "properties": ["a": ["type": "integer"], "id": ["type": "string"]],
                    "required": ["a", "id"],
                ])
            expectWire(
                try #require(defs["t.mergedRefs.1"]),
                matches: [
                    "properties": ["b": ["type": "boolean"], "id": ["type": "string"]],
                    "required": ["b", "id"],
                ])
            #expect(schema.objectValue?["required"] == ["dupTypes", "either", "merged", "mergedRefs", "one"])

            // Root-level `oneOf` with `$ref` branches also merges sibling `properties` and `required`.
            let rootMerged = try converted([
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "oneOf": [["$ref": "#/$defs/VariantA"], ["$ref": "#/$defs/VariantB"]],
                "$defs": [
                    "VariantA": ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a"]],
                    "VariantB": ["type": "object", "properties": ["b": ["type": "boolean"]], "required": ["b"]],
                ],
            ])
            let rootDefs = try #require(rootMerged.objectValue?["$defs"]?.objectValue)
            expectWire(try #require(rootDefs["t.0"]), matches: ["required": ["a", "id"]])
            expectWire(try #require(rootDefs["t.1"]), matches: ["required": ["b", "id"]])
        }

        @Test("References follow $defs, definitions, property pointers, percent-encoding, and preserve nullability")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func references() throws {
            let schema = try converted([
                "type": "object",
                "properties": [
                    "from": ["type": "object", "properties": ["x": ["type": "number"]], "required": ["x"]],
                    "to": ["$ref": "#/properties/from"],
                    "location": ["$ref": "#/$defs/Location", "description": "Where"],
                    "optLocation": ["anyOf": [["$ref": "#/$defs/Location"], ["type": "null"]]],
                    "unit": ["$ref": "#/definitions/Unit"],
                    "aliasUnit": ["$ref": "#/$defs/UnitAlias"],
                    "shape": ["$ref": "#/$defs/Shape"],
                    "maybe1": ["$ref": "#/$defs/MaybeObj"],
                    "maybe2": ["$ref": "#/$defs/MaybeObj"],
                    "encoded": ["$ref": "#/$defs/My%20Type"],
                    "list1": ["$ref": "#/$defs/ItemList"],
                    "list2": ["$ref": "#/$defs/ItemList"],
                    "parent": ["$ref": "#"],
                    "wrapped": ["allOf": [["$ref": "#/$defs/Location"]]],
                ],
                "required": ["from", "to", "location", "optLocation", "maybe1", "maybe2"],
                "$defs": [
                    "Location": ["type": "object", "properties": ["lat": ["type": "number"]], "required": ["lat"]],
                    "UnitAlias": ["$ref": "#/definitions/Unit"],
                    "Shape": ["anyOf": [["type": "string"], ["type": "integer"]]],
                    "MaybeObj": [
                        "type": ["object", "null"],
                        "properties": ["flag": ["type": "boolean"]],
                    ],
                    "My Type": ["const": "special"],
                    "ItemList": [
                        "type": "array",
                        "items": ["type": "object", "properties": ["id": ["type": "string"]]],
                    ],
                ],
                "definitions": ["Unit": ["type": "string", "enum": ["c", "f"]]],
            ])
            #expect(property("location", of: schema) == ["$ref": "#/$defs/Location", "description": "Where"])
            #expect(property("optLocation", of: schema) == ["$ref": "#/$defs/Location"])
            #expect(property("unit", of: schema) == ["type": "string", "enum": ["c", "f"]])
            #expect(property("aliasUnit", of: schema) == ["type": "string", "enum": ["c", "f"]])
            #expect(property("shape", of: schema) == ["$ref": "#/$defs/Shape"])
            #expect(property("encoded", of: schema) == ["const": "special"])
            #expect(property("parent", of: schema) == ["$ref": "#"])
            #expect(property("wrapped", of: schema) == ["$ref": "#/$defs/Location"])
            // Both maybe1 and maybe2 inherit MaybeObj's nullability, and optLocation is optional.
            #expect(schema.objectValue?["required"] == ["from", "location", "to"])
            let defs = try #require(schema.objectValue?["$defs"]?.objectValue)
            expectWire(
                try #require(defs["Location"]),
                matches: ["type": "object", "properties": ["lat": ["type": "number"]], "required": ["lat"]])
            expectWire(try #require(defs["Shape"]), matches: ["anyOf": [["type": "string"], ["type": "integer"]]])
        }

        @Test("A recursive definition refers to itself")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func recursiveDefinition() throws {
            let schema = try converted([
                "type": "object",
                "properties": ["tree": ["$ref": "#/$defs/Tree"]],
                "$defs": [
                    "Tree": [
                        "type": "object",
                        "properties": ["children": ["type": "array", "items": ["$ref": "#/$defs/Tree"]]],
                    ]
                ],
            ])
            expectWire(
                try #require(schema.objectValue?["$defs"]?.objectValue?["Tree"]),
                matches: ["properties": ["children": ["items": ["$ref": "#/$defs/Tree"]]]])
        }

        @Test("Maps, untyped subschemas, and GeneratedContent name collisions are handled")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func anyJSONAndNameReservation() throws {
            let schema = try converted(
                [
                    "type": "object",
                    "properties": [
                        "map": ["type": "object", "additionalProperties": ["type": "string"]],
                        "patternMap": ["type": "object", "patternProperties": ["^a": ["type": "string"]]],
                        "closedEmpty": ["type": "object", "additionalProperties": false],
                        "object": ["type": "object"],
                        "untyped": ["description": "Anything"],
                        "always": true,
                        "namedGC": ["$ref": "#/$defs/GeneratedContent"],
                    ],
                    "$defs": [
                        "GeneratedContent": ["type": "object", "properties": ["k": ["type": "string"]]]
                    ],
                ],
                name: "GeneratedContent")
            for name in ["map", "patternMap", "object", "untyped", "always"] {
                expectWire(try #require(property(name, of: schema)), matches: ["$ref": "#/$defs/GeneratedContent"])
            }
            #expect(property("closedEmpty", of: schema) == ["$ref": "#/$defs/GeneratedContent_2.closedEmpty"])
            #expect(property("namedGC", of: schema) == ["$ref": "#/$defs/GeneratedContent_3"])
        }

        @Test("Schema names stay unique")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func uniqueNames() throws {
            let inner: Value = ["type": "object", "properties": ["x": ["type": "string"]]]
            let schema = try converted([
                "type": "object",
                "properties": [
                    "a": ["type": "object", "properties": ["b": inner]],
                    "a.b": inner,
                ],
                "$defs": ["t": inner],
            ])
            let defs = try #require(schema.objectValue?["$defs"]?.objectValue)
            #expect(defs["t.a"] != nil)
            #expect(defs["t.a.b"] != nil)
            #expect(defs["t.a.b_2"] != nil)
        }

        @Test("Deep nesting, duplicate type blowups, and exponential inlining are bounded")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func resourceBounds() throws {
            // Duplicate `type` entries are deduplicated, so 20 nested levels convert in linear time.
            var dupNested: Value = ["type": "string"]
            for _ in 0..<20 {
                dupNested = ["type": ["object", "object"], "properties": ["a": dupNested]]
            }
            let dupRoot: Value = ["type": "object", "properties": ["root": dupNested]]
            #expect(try converted(dupRoot).objectValue?["type"] == "object")

            // Exceeding maxDepth (32) throws JSONSchemaError rather than overflowing the stack.
            var tooDeep: Value = ["type": "string"]
            for _ in 0..<40 {
                tooDeep = ["type": "object", "properties": ["a": tooDeep]]
            }
            #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(jsonSchema: tooDeep, name: "t")
            }

            // A deep `$defs` alias chain also hits maxDepth rather than overflowing the stack.
            var chainDefs: [String: Value] = ["C40": ["type": "string"]]
            for i in 0..<40 {
                chainDefs["C\(i)"] = ["$ref": .string("#/$defs/C\(i + 1)")]
            }
            let deepChain: Value = [
                "type": "object",
                "properties": ["x": ["$ref": "#/$defs/C0"]],
                "$defs": .object(chainDefs),
            ]
            #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(jsonSchema: deepChain, name: "t")
            }

            // Chained inlined definitions quadrupling across 6 levels stay well within maxDepth (32)
            // while exceeding maxNodes (1,024).
            var defs: [String: Value] = ["D6": ["type": "string"]]
            for i in stride(from: 5, through: 0, by: -1) {
                let next: Value = ["$ref": .string("#/$defs/D\(i + 1)")]
                defs["D\(i)"] = [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["a": next, "b": next, "c": next, "d": next],
                    ],
                ]
            }
            let bomb: Value = [
                "type": "object",
                "properties": ["x": ["$ref": "#/$defs/D0"]],
                "$defs": .object(defs),
            ]
            let bombError = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(jsonSchema: bomb, name: "t")
            }
            #expect(bombError?.reason.contains("\(JSONSchemaConverter.maxNodes)") == true)
        }

        @Test("A choice that refers to itself through $ref throws instead of recursing without bound")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func selfReferencingChoice() throws {
            let direct: Value = [
                "type": "object",
                "properties": ["p": ["$ref": "#/$defs/X"]],
                "$defs": ["X": ["properties": ["a": ["type": "string"]], "anyOf": [["$ref": "#/$defs/X"]]]],
            ]
            let mutual: Value = [
                "type": "object",
                "properties": ["p": ["$ref": "#/$defs/X"]],
                "$defs": [
                    "X": ["properties": ["a": ["type": "string"]], "anyOf": [["$ref": "#/$defs/Y"]]],
                    "Y": ["properties": ["b": ["type": "string"]], "anyOf": [["$ref": "#/$defs/X"]]],
                ],
            ]
            for schema in [direct, mutual] {
                #expect(throws: GenerationSchema.JSONSchemaError.self) {
                    try GenerationSchema(jsonSchema: schema, name: "t")
                }
                // Backfill walks the same choices and stays bounded too.
                _ = JSONSchemaConverter.backfillRequiredNulls(in: ["p": ["a": "x"]], schema: schema)
            }
        }

        @Test("Sibling properties merge into a choice typed [object, null]")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func mergeIntoNullableObjectChoice() throws {
            let schema = try converted([
                "type": "object",
                "properties": [
                    "p": [
                        "properties": ["id": ["type": "string"]],
                        "required": ["id"],
                        "anyOf": [
                            ["type": ["object", "null"], "properties": ["a": ["type": "string"]]],
                            ["properties": ["b": ["type": "string"]]],
                        ],
                    ]
                ],
                "required": ["p"],
            ])
            let defs = try #require(schema.objectValue?["$defs"]?.objectValue)
            expectWire(try #require(defs["t.p.0"]), matches: ["required": ["id"]])
            expectWire(try #require(defs["t.p.1"]), matches: ["required": ["id"]])
            #expect(defs["t.p.0"]?.objectValue?["properties"]?.objectValue?["id"] == ["type": "string"])
        }

        @Test("Every choice of a root anyOf or oneOf must be an object; a single $ref choice is the root")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func rootChoices() throws {
            let mixed = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(
                    jsonSchema: [
                        "type": "object",
                        "anyOf": [["type": "string"], ["type": "object", "properties": ["a": ["type": "string"]]]],
                    ],
                    name: "t")
            }
            #expect(mixed?.pointer == "/anyOf/0")

            let single = try converted([
                "anyOf": [["$ref": "#/$defs/X"]],
                "$defs": [
                    "X": [
                        "type": "object",
                        "properties": ["x": ["type": "string"], "again": ["$ref": "#"]],
                        "required": ["x"],
                    ]
                ],
            ])
            #expect(single.objectValue?["type"] == "object")
            #expect(single.objectValue?["title"] == "t")
            #expect(property("x", of: single) == ["type": "string"])
            #expect(property("again", of: single) == ["$ref": "#"])
            #expect(single.objectValue?["required"] == ["x"])
        }

        /// Whether every choice of a converted root is an object, inline or under `$defs`,
        /// following nested choices.
        private func rootChoicesAreObjects(_ schema: Value) -> Bool {
            let defs = schema.objectValue?["$defs"]?.objectValue ?? [:]
            func isObject(_ node: Value, depth: Int) -> Bool {
                guard depth < 8, let keywords = node.objectValue else { return false }
                if let ref = keywords["$ref"]?.stringValue {
                    guard ref.hasPrefix("#/$defs/"), let target = defs[String(ref.dropFirst("#/$defs/".count))] else {
                        return false
                    }
                    return isObject(target, depth: depth + 1)
                }
                if let choices = keywords["anyOf"]?.arrayValue {
                    return !choices.isEmpty && choices.allSatisfy { isObject($0, depth: depth + 1) }
                }
                return keywords["type"] == "object"
            }
            return isObject(schema, depth: 0)
        }

        @Test(
            "Root choices that are empty, type-less or nested convert to objects",
            arguments: [
                ["anyOf": [["type": "object"]]],
                ["anyOf": [["type": "object"], ["type": "object", "properties": ["a": ["type": "string"]]]]],
                ["anyOf": [["required": ["a"]], ["properties": ["b": ["type": "string"]]]]],
                ["type": "object", "anyOf": [["type": "object", "additionalProperties": true]]],
                [
                    "type": "object",
                    "anyOf": [["anyOf": [["$ref": "#/$defs/A"], ["$ref": "#/$defs/B"]]]],
                    "$defs": [
                        "A": ["type": "object", "properties": ["a": ["type": "string"]]],
                        "B": ["type": "object", "properties": ["b": ["type": "string"]]],
                    ],
                ],
            ] as [Value])
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func rootChoicesBecomeObjects(schema: Value) throws {
            let result = try converted(schema)
            #expect(rootChoicesAreObjects(result), "\(result)")
        }

        @Test("Sibling properties reach the choices of a nested root choice")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func nestedRootChoiceMerge() throws {
            let schema = try converted([
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "anyOf": [
                    ["oneOf": [["properties": ["a": ["type": "string"]]], ["properties": ["b": ["type": "string"]]]]]
                ],
            ])
            #expect(rootChoicesAreObjects(schema), "\(schema)")
            let defs = try #require(schema.objectValue?["$defs"]?.objectValue)
            let branches = defs.values.filter { $0.objectValue?["properties"]?.objectValue?["id"] != nil }
            #expect(branches.count == 2)
            #expect(branches.allSatisfy { $0.objectValue?["required"]?.arrayValue?.contains("id") == true })
        }

        @Test(
            "Root choices that are maps, require properties, or nest a non-object throw with their pointer",
            arguments: [
                (["anyOf": [["type": "object", "additionalProperties": ["type": "string"]]]], "/anyOf/0/additionalProperties"),
                (["anyOf": [["type": "object", "patternProperties": ["^a": ["type": "string"]]]]], "/anyOf/0/patternProperties"),
                (["anyOf": [["type": "object", "minProperties": 1]]], "/anyOf/0/minProperties"),
                (["type": "object", "anyOf": [["anyOf": [["type": "string"]]]]], "/anyOf/0/anyOf/0"),
                (
                    ["oneOf": [["$ref": "#/$defs/P"]], "$defs": ["P": ["oneOf": [["type": "integer"]]]]],
                    "/oneOf/0/oneOf/0"
                ),
            ] as [(Value, String)])
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func rootChoiceRejections(schema: Value, pointer: String) throws {
            let error = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(jsonSchema: schema, name: "t")
            }
            #expect(error?.pointer == pointer)
        }

        @Test("A root choice that refers to itself throws instead of recursing without bound")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func selfReferencingRootChoice() throws {
            #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(
                    jsonSchema: [
                        "anyOf": [["$ref": "#/$defs/X"]],
                        "$defs": ["X": ["properties": ["a": ["type": "string"]], "anyOf": [["$ref": "#/$defs/X"]]]],
                    ],
                    name: "t")
            }
        }

        @Test("Backfill follows a single-choice wrapper with sibling properties, and every nesting level")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func backfillWrapperAndDepth() throws {
            let wrapper: Value = [
                "type": "object",
                "properties": [
                    "p": [
                        "properties": ["n": ["type": ["string", "null"]]],
                        "required": ["n"],
                        "anyOf": [["$ref": "#/$defs/A"], ["type": "null"]],
                    ]
                ],
                "$defs": ["A": ["type": "object", "properties": ["a": ["type": "string"]]]],
            ]
            #expect(
                JSONSchemaConverter.backfillRequiredNulls(in: ["p": ["a": "x"]], schema: wrapper)
                    == ["p": ["a": "x", "n": .null]])

            // 20 nested levels convert (one depth unit each), so backfill must reach the leaf too.
            var schema: Value = [
                "type": "object", "properties": ["v": ["type": ["string", "null"]]], "required": ["v"],
            ]
            var arguments: Value = [:]
            var expected: Value = ["v": .null]
            for _ in 0..<20 {
                schema = ["type": "object", "properties": ["c": schema], "required": ["c"]]
                arguments = ["c": arguments]
                expected = ["c": expected]
            }
            _ = try GenerationSchema(jsonSchema: schema, name: "t")
            let filled = JSONSchemaConverter.backfillRequiredNulls(
                in: try #require(arguments.objectValue), schema: schema)
            #expect(Value.object(filled) == expected)
        }

        @Test(
            "Schemas the bridge cannot express throw with their pointer",
            arguments: [
                (Value.string("x"), ""),
                (["type": "string"], ""),
                (["type": ["object", "null"]], ""),
                (["type": "object", "properties": ["a": false]], "/properties/a"),
                (["type": "object", "properties": ["a": 42]], "/properties/a"),
                (["type": "object", "properties": ["a": ["allOf": []]]], "/properties/a/allOf"),
                (
                    ["type": "object", "properties": ["a": ["allOf": [["type": "string"], ["minLength": 1]]]]],
                    "/properties/a/allOf"
                ),
                (["type": "object", "properties": ["a": ["anyOf": []]]], "/properties/a/anyOf"),
                (["type": "object", "properties": ["a": ["anyOf": [["type": "null"]]]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["enum": "x"]]], "/properties/a/enum"),
                (["type": "object", "properties": ["a": ["enum": [nil]]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["const": nil]]], "/properties/a/const"),
                (["type": "object", "properties": ["a": ["type": [1]]]], "/properties/a/type"),
                (["type": "object", "properties": ["a": ["type": 1]]], "/properties/a/type"),
                (["type": "object", "properties": ["a": ["type": "date"]]], "/properties/a/type"),
                (["type": "object", "properties": ["a": ["type": "null"]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["type": "integer", "minimum": 5, "maximum": 1]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["type": "number", "minimum": 5, "maximum": 1]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["type": "array", "minItems": 3, "maxItems": 1]]], "/properties/a"),
                (["type": "object", "properties": ["a": ["type": "array", "minItems": 10_000]]], "/properties/a/minItems"),
                (["type": "object", "properties": ["a": ["$ref": 1]]], "/properties/a/$ref"),
                (["type": "object", "properties": ["a": ["$ref": "https://example.com/schema"]]], "/properties/a/$ref"),
                (["type": "object", "properties": ["a/b": ["$ref": "#/$defs/Missing"]]], "/properties/a~1b/$ref"),
                (
                    [
                        "type": "object",
                        "properties": ["a": ["$ref": "#/$defs/List"]],
                        "$defs": ["List": ["type": "array", "items": ["$ref": "#/$defs/List"]]],
                    ],
                    "/$defs/List/items/$ref"
                ),
            ] as [(Value, String)])
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func unsupported(schema: Value, pointer: String) throws {
            let error = #expect(throws: GenerationSchema.JSONSchemaError.self) {
                try GenerationSchema(jsonSchema: schema, name: "t")
            }
            #expect(error?.pointer == pointer)
        }

        @Test("A Generable schema converts back to itself", arguments: ["FMWeatherQuery", "FMNode"])
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func generableRoundTrip(name: String) throws {
            let original = name == "FMNode" ? FMNode.generationSchema : FMWeatherQuery.generationSchema
            let value = try Value.preservingStrings(original)
            #expect(try converted(value, name: name) == value)
        }

        // MARK: - Client

        @Test("Tool results, errors, unknown blocks, and descriptions format accurately")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func resultTextAndDescriptions() throws {
            let result = CallTool.Result(content: [
                .text(text: "First"),
                .image(data: "aGk=", mimeType: "image/png"),
                .resource(resource: .text("Second", uri: "file:///a.txt")),
                .resource(resource: .binary(Data("hi".utf8), uri: "file:///b.bin")),
                .resourceLink(uri: "file:///c.txt", name: "c"),
                .audio(data: "aGk=", mimeType: "audio/wav"),
                .unknown(type: "custom", .object([:])),
            ])
            #expect(
                Client.LanguageModelTool.text(of: result)
                    == "First\n\nSecond\n\n[image: image/png]\n[resource: file:///b.bin]\n[resource: file:///c.txt]\n[audio: audio/wav]\n[custom]"
            )

            let structured = CallTool.Result(structuredContent: Value?.some(["city": "Zürich", "url": "https://a/b"]))
            #expect(Client.LanguageModelTool.text(of: structured) == #"{"city":"Zürich","url":"https://a/b"}"#)

            // When text is present, structuredContent is not duplicated.
            let both = CallTool.Result(
                content: [.text(text: "Human text")],
                structuredContent: Value?.some(["city": "Zürich"]))
            #expect(Client.LanguageModelTool.text(of: both) == "Human text")

            // Error results are prefixed with "Error: ", with a non-empty fallback when empty.
            let errWithText = CallTool.Result(content: [.text(text: "Bad city")], isError: true)
            #expect(Client.LanguageModelTool.text(of: errWithText) == "Error: Bad city")
            let emptyErr = CallTool.Result(content: [], isError: true)
            #expect(Client.LanguageModelTool.text(of: emptyErr) == "Error: Tool call failed.")

            // Description fallback chain and visibility check on LanguageModelTool.init.
            let client = Client(name: "test", version: "1.0")
            let schema: Value = ["type": "object"]
            let titleTool = MCP.Tool(name: "t1", title: "Title 1", description: nil, inputSchema: schema)
            #expect(try Client.LanguageModelTool(titleTool, client: client).description == "Title 1")
            let annotatedTool = MCP.Tool(
                name: "t2", description: nil, inputSchema: schema, annotations: .init(title: "Annotated"))
            #expect(try Client.LanguageModelTool(annotatedTool, client: client).description == "Annotated")
            let emptyDescTool = MCP.Tool(name: "t3", description: nil, inputSchema: schema)
            #expect(try Client.LanguageModelTool(emptyDescTool, client: client).description == "")

            var appOnly = MCP.Tool(name: "app_only", description: "App", inputSchema: schema)
            appOnly.ui = ToolUIMeta(resourceUri: "ui://app", visibility: [.app])
            let visibilityError = #expect(throws: MCPError.self) {
                try Client.LanguageModelTool(appOnly, client: client)
            }
            #expect(visibilityError?.code == -32602)
        }

        @Test(
            "The client offers tools, enforces approval, and backfills required-nullable arguments",
            arguments: [Client.Configuration.default, .handshake])
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func endToEnd(configuration: Client.Configuration) async throws {
            let weather = FMWeatherTool()
            var viewOnly = try MCP.Tool(FMEchoTool())
            viewOnly.ui = ToolUIMeta(resourceUri: "ui://echo", visibility: [.app])
            let unsupported = MCP.Tool(
                name: "unsupported", description: nil,
                inputSchema: ["type": "object", "properties": ["a": ["allOf": [["type": "string"], ["minLength": 1]]]]])
            let nullableSearch = MCP.Tool(
                name: "search",
                description: "Search with nullable limit and nested filter",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["anyOf": [["type": "integer"], ["type": "null"]]],
                        "filter": ["$ref": "#/$defs/Filter"],
                        "clauses": ["type": "array", "items": ["$ref": "#/$defs/Filter"]],
                    ],
                    "required": ["query", "limit"],
                    "$defs": [
                        "Filter": [
                            "type": "object",
                            "properties": [
                                "field": ["type": "string"],
                                "cursor": ["type": ["string", "null"]],
                            ],
                            "required": ["field", "cursor"],
                        ]
                    ],
                ])
            let tools = [try MCP.Tool(weather), viewOnly, unsupported, nullableSearch]
            let recorder = ArgumentRecorder()

            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            let server = Server(name: "test", version: "1.0", capabilities: .init(tools: .init()))
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
            await server.withMethodHandler(CallTool.self) { params in
                switch params.name {
                case weather.name:
                    return try await weather.call(params)
                case "search":
                    await recorder.record(params.arguments ?? [:])
                    return CallTool.Result(content: [.text(text: "ok")])
                default:
                    throw MCPError.invalidParams("Unknown tool")
                }
            }
            try await server.start(transport: serverTransport)

            let client = Client(name: "test", version: "1.0", configuration: configuration)
            _ = try await client.connect(transport: clientTransport)

            let offered = try await client.languageModelTools { tool, args in
                !(tool.name == "get_weather" && args["city"] == "Denied")
            }
            #expect(offered.map(\.name) == ["get_weather", "search"])
            let weatherTool = try #require(offered.first)
            #expect(weatherTool.description == "Forecast for a city")
            #expect(weatherTool.tool == tools[0])

            let answer = try await weatherTool.call(
                arguments: GeneratedContent(json: #"{"city": "Zürich", "units": "metric"}"#))
            #expect(try wireJSON(answer) == ["city": "Zürich", "high": 21.5])
            let failure = try await weatherTool.call(
                arguments: GeneratedContent(json: #"{"city": "Nowhere", "units": "metric"}"#))
            #expect(failure == "Error: No such city")
            let denied = try await weatherTool.call(
                arguments: GeneratedContent(json: #"{"city": "Denied", "units": "metric"}"#))
            #expect(denied == "Error: Tool call to get_weather was not approved.")
            await #expect(throws: MCPError.self) {
                try await weatherTool.call(arguments: GeneratedContent(kind: .array([])))
            }

            // Omitted required+nullable fields (top-level, `$ref` object, and array items) are backfilled with `.null`.
            let searchTool = try #require(offered.last)
            let searchAnswer = try await searchTool.call(
                arguments: GeneratedContent(
                    json: #"{"query": "shoes", "filter": {"field": "color"}, "clauses": [{"field": "size"}]}"#))
            #expect(searchAnswer == "ok")
            #expect(
                await recorder.recorded
                    == [
                        [
                            "query": "shoes",
                            "limit": .null,
                            "filter": ["field": "color", "cursor": .null],
                            "clauses": [["field": "size", "cursor": .null]],
                        ]
                    ])

            await client.disconnect()
            await server.stop()
        }

        @Test("languageModelTools pages across cursors and stops on empty, repeated, or 100 pages")
        @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
        func pagingAndCursorGuards() async throws {
            let schema: Value = ["type": "object"]
            let toolA = MCP.Tool(name: "a", description: "A", inputSchema: schema)
            let toolB = MCP.Tool(name: "b", description: "B", inputSchema: schema)

            // 1. Multi-page listing ending with an empty cursor.
            do {
                let counter = PageCounter()
                let (ct, st) = await InMemoryTransport.createConnectedPair()
                let server = Server(name: "test", version: "1.0", capabilities: .init(tools: .init()))
                await server.withMethodHandler(ListTools.self) { params in
                    _ = await counter.record(params.cursor)
                    if params.cursor == nil {
                        return .init(tools: [toolA], nextCursor: "page2")
                    }
                    return .init(tools: [toolB], nextCursor: "")
                }
                try await server.start(transport: st)
                let client = Client(name: "test", version: "1.0")
                _ = try await client.connect(transport: ct)
                let listed = try await client.languageModelTools()
                #expect(listed.map(\.name) == ["a", "b"])
                #expect(await counter.cursors == [nil, "page2"])
                await client.disconnect()
                await server.stop()
            }

            // 2. Repeated cursor stops immediately without duplicating tools.
            do {
                let counter = PageCounter()
                let (ct, st) = await InMemoryTransport.createConnectedPair()
                let server = Server(name: "test", version: "1.0", capabilities: .init(tools: .init()))
                await server.withMethodHandler(ListTools.self) { params in
                    _ = await counter.record(params.cursor)
                    return .init(tools: [toolA], nextCursor: "same")
                }
                try await server.start(transport: st)
                let client = Client(name: "test", version: "1.0")
                _ = try await client.connect(transport: ct)
                let listed = try await client.languageModelTools()
                #expect(listed.map(\.name) == ["a"])
                #expect(await counter.calls == 2)
                await client.disconnect()
                await server.stop()
            }

            // 3. Unique cursors stop at `Client.maxListingPages` (100).
            do {
                let counter = PageCounter()
                let (ct, st) = await InMemoryTransport.createConnectedPair()
                let server = Server(name: "test", version: "1.0", capabilities: .init(tools: .init()))
                await server.withMethodHandler(ListTools.self) { params in
                    let n = await counter.record(params.cursor)
                    return .init(tools: [MCP.Tool(name: "t\(n)", description: nil, inputSchema: schema)], nextCursor: "c\(n)")
                }
                try await server.start(transport: st)
                let client = Client(name: "test", version: "1.0")
                _ = try await client.connect(transport: ct)
                let listed = try await client.languageModelTools()
                #expect(listed.count == 100)
                #expect(await counter.calls == 100)
                await client.disconnect()
                await server.stop()
            }
        }
    }
#endif
