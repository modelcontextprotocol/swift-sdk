import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension MCP.Tool {
        /// Creates a tool whose input schema is the generation schema of a
        /// `Generable` type.
        ///
        /// ```swift
        /// @Generable
        /// struct WeatherQuery {
        ///     @Guide(description: "City name")
        ///     var city: String
        /// }
        ///
        /// let tool = try MCP.Tool(
        ///     name: "get_weather",
        ///     description: "Forecast for a city",
        ///     arguments: WeatherQuery.self)
        /// ```
        ///
        /// Decode the arguments of a call with
        /// ``CallTool/Parameters/arguments(as:)``.
        ///
        /// - Throws: ``FoundationModels/GenerationSchema/JSONSchemaError``
        ///   when the schema of `arguments` is not an object, as MCP requires
        ///   (a `@Generable` enum or a `String` cannot be the arguments), or
        ///   `EncodingError` when the schema contains a non-finite bound.
        public init<Arguments: Generable>(
            name: String,
            title: String? = nil,
            description: String?,
            arguments: Arguments.Type,
            annotations: Annotations = nil,
            icons: [Icon]? = nil,
            _meta: Metadata? = nil,
            execution: Execution? = nil
        ) throws {
            self.init(
                name: name,
                title: title,
                description: description,
                inputSchema: try Self.objectSchema(Arguments.generationSchema, of: "arguments"),
                annotations: annotations,
                icons: icons,
                _meta: _meta,
                execution: execution)
        }

        /// Creates a tool whose input and output schemas are the generation
        /// schemas of `Generable` types.
        ///
        /// Return the output of a call with
        /// ``CallTool/Result/init(_:isError:_meta:)``, which fills
        /// `structuredContent`.
        ///
        /// - Throws: ``FoundationModels/GenerationSchema/JSONSchemaError``
        ///   when the schema of `arguments` or `output` is not an object, as
        ///   MCP requires, or `EncodingError` when a schema contains a
        ///   non-finite bound.
        public init<Arguments: Generable, Output: Generable>(
            name: String,
            title: String? = nil,
            description: String?,
            arguments: Arguments.Type,
            output: Output.Type,
            annotations: Annotations = nil,
            icons: [Icon]? = nil,
            _meta: Metadata? = nil,
            execution: Execution? = nil
        ) throws {
            self.init(
                name: name,
                title: title,
                description: description,
                inputSchema: try Self.objectSchema(Arguments.generationSchema, of: "arguments"),
                annotations: annotations,
                outputSchema: try Self.objectSchema(Output.generationSchema, of: "output"),
                icons: icons,
                _meta: _meta,
                execution: execution)
        }

        /// Creates the MCP definition of a FoundationModels tool.
        ///
        /// The name, description and input schema are the tool's. When the
        /// tool's `Output` is a `Generable` type whose schema is an object,
        /// that schema is the output schema. Serve calls with
        /// `call(_:)` on the tool.
        ///
        /// - Throws: ``FoundationModels/GenerationSchema/JSONSchemaError``
        ///   when the tool's parameters are not an object, as MCP requires, or
        ///   `EncodingError` when a schema contains a non-finite bound.
        public init<T: FoundationModels.Tool>(
            _ tool: T,
            title: String? = nil,
            annotations: Annotations = nil,
            icons: [Icon]? = nil,
            _meta: Metadata? = nil,
            execution: Execution? = nil
        ) throws {
            var outputSchema: Value?
            if let output = T.Output.self as? any Generable.Type {
                let encoded = try Value.preservingStrings(output.generationSchema)
                if encoded.objectValue?["type"]?.stringValue == "object" {
                    outputSchema = encoded
                }
            }
            self.init(
                name: tool.name,
                title: title,
                description: tool.description,
                inputSchema: try Self.objectSchema(tool.parameters, of: "arguments"),
                annotations: annotations,
                outputSchema: outputSchema,
                icons: icons,
                _meta: _meta,
                execution: execution)
        }

        /// `schema` as JSON Schema, which must be an object.
        static func objectSchema(_ schema: GenerationSchema, of role: String) throws -> Value {
            let value = try Value.preservingStrings(schema)
            guard value.objectValue?["type"]?.stringValue == "object" else {
                throw GenerationSchema.JSONSchemaError(
                    pointer: "", reason: "The schema of the tool's \(role) must be an object")
            }
            return value
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension CallTool.Parameters {
        /// The arguments of the call, decoded into a FoundationModels type
        /// such as a `@Generable` struct.
        ///
        /// Missing arguments are decoded as an empty object. Decoding checks
        /// the structure and property types of `T`; `@Guide` constraints
        /// (such as ranges, counts or patterns) are not enforced on remote
        /// arguments and must be checked by the tool. Integers decoded as
        /// ``Value/int(_:)`` outside IEEE-754 exact `Double` precision (`±2^53`)
        /// and non-finite numbers are rejected rather than rounded. An integer
        /// literal that does not fit in `Int` (above `2^31` on 32-bit watchOS)
        /// is decoded by ``Value`` as a `Double` before this check, so it is
        /// already rounded.
        ///
        /// - Throws: ``MCPError/invalidParams(_:)`` when the arguments do not
        ///   match `type`, contain an ``Value/int(_:)`` outside exact `Double`
        ///   precision, or contain a non-finite number, so that the call is
        ///   answered with -32602. Any ``MCPError`` thrown by `T.init(_:)` is
        ///   rethrown unchanged.
        public func arguments<T: ConvertibleFromGeneratedContent>(as type: T.Type = T.self) throws -> T {
            let root = Value.object(arguments ?? [:])
            try Self.validateRepresentableNumbers(in: root, toolName: name)
            do {
                return try T(GeneratedContent(root))
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.invalidParams("Invalid arguments for tool \(name): \(error)")
            }
        }

        /// Whether `integer` converts losslessly to an IEEE-754 `Double`.
        static func isExactInDouble(_ integer: Int64) -> Bool {
            let maxExact: Int64 = 1 << 53
            return (-maxExact...maxExact).contains(integer)
        }

        /// Ensures every number in `value` converts losslessly to a finite `Double`
        /// in `GeneratedContent`.
        private static func validateRepresentableNumbers(in value: Value, toolName: String) throws {
            switch value {
            case .int(let integer):
                guard Self.isExactInDouble(Int64(integer)) else {
                    throw MCPError.invalidParams(
                        "Invalid arguments for tool \(toolName): integer \(integer) exceeds exact Double precision")
                }
            case .double(let number):
                guard number.isFinite else {
                    throw MCPError.invalidParams(
                        "Invalid arguments for tool \(toolName): non-finite number is not valid JSON")
                }
            case .array(let elements):
                for element in elements {
                    try validateRepresentableNumbers(in: element, toolName: toolName)
                }
            case .object(let properties):
                for element in properties.values {
                    try validateRepresentableNumbers(in: element, toolName: toolName)
                }
            case .null, .bool, .string, .data:
                break
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension CallTool.Result {
        /// Creates the result of a call from a FoundationModels value, such as
        /// a `@Generable` struct or a `String`.
        ///
        /// A structure becomes `structuredContent`, and its JSON one text block
        /// for clients that do not read structured content. Null-valued object
        /// properties (such as `nil` optionals built with
        /// `GeneratedContent(properties:)`) are omitted so the result conforms
        /// to the non-nullable properties of a `GenerationSchema`. A string
        /// becomes one text block. Any other value becomes one text block with
        /// its JSON.
        ///
        /// - Throws: `EncodingError` when `output` contains a non-finite
        ///   floating-point value (`NaN` or `Infinity`) that cannot be encoded
        ///   as JSON.
        public init(
            _ output: some ConvertibleToGeneratedContent,
            isError: Bool? = nil,
            _meta: Metadata? = nil
        ) throws {
            let content = output.generatedContent
            switch content.kind {
            case .structure:
                let structured = Self.droppingNullProperties(Value(content))
                let text = try Self.encodeJSONText(structured)
                self.init(
                    content: [.text(text: text)],
                    structuredContent: Optional.some(structured),
                    isError: isError,
                    _meta: _meta)
            case .string(let text):
                self.init(content: [.text(text: text)], isError: isError, _meta: _meta)
            default:
                let encoded = try Self.encodeJSONText(Self.droppingNullProperties(Value(content)))
                self.init(content: [.text(text: encoded)], isError: isError, _meta: _meta)
            }
        }

        private static func droppingNullProperties(_ value: Value) -> Value {
            switch value {
            case .object(let properties):
                var cleaned: [String: Value] = [:]
                cleaned.reserveCapacity(properties.count)
                for (key, property) in properties where property != .null {
                    cleaned[key] = droppingNullProperties(property)
                }
                return .object(cleaned)
            case .array(let elements):
                return .array(elements.map(droppingNullProperties))
            default:
                return value
            }
        }

        private static func encodeJSONText(_ value: Value) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension FoundationModels.Tool where Output: ConvertibleToGeneratedContent {
        /// Serves a `tools/call` request with this tool.
        ///
        /// Decodes the arguments, calls `call(arguments:)` and returns its
        /// output with `CallTool.Result(_:isError:_meta:)`.
        ///
        /// An error the tool throws becomes a result with `isError` set, so that
        /// the model can read it and correct the call. The text is the error's
        /// `errorDescription` when it conforms to `LocalizedError`, and
        /// `"The tool failed."` otherwise: the bridged `localizedDescription`
        /// of other errors names the module, type and case, which must not
        /// reach an untrusted client. Conform the error to `LocalizedError` (or
        /// catch errors in the tool) to send a specific message. `MCPError` and
        /// `CancellationError` are thrown unchanged.
        ///
        /// - Throws: `MCPError.invalidParams` when the arguments do not match
        ///   the tool's `Arguments`.
        public func call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
            let arguments = try parameters.arguments(as: Arguments.self)
            do {
                return try CallTool.Result(try await call(arguments: arguments))
            } catch let error as MCPError {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "The tool failed."
                return CallTool.Result(content: [.text(text: message)], isError: true)
            }
        }
    }
#endif
