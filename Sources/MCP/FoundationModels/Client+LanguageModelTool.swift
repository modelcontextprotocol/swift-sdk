import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension Client {
        /// A tool of the server, for a FoundationModels `LanguageModelSession`.
        ///
        /// ```swift
        /// let tools = try await client.languageModelTools()
        /// let session = LanguageModelSession(tools: tools)
        /// let answer = try await session.respond(to: "Weather in Zürich tomorrow?")
        /// ```
        ///
        /// When the model calls the tool, an optional approval callback can
        /// inspect the tool (including its ``MCP/Tool/annotations``) and
        /// arguments before the client sends `tools/call`. The result is
        /// returned to the model as text:
        ///
        /// - The text blocks, and the text of embedded text resources, joined
        ///   with blank lines. When there are none, the JSON of
        ///   `structuredContent`.
        /// - A line for each image, audio clip, binary resource and resource
        ///   link, such as `[image: image/png]`.
        ///
        /// A result with `isError` is prefixed with `"Error: "` and returned to
        /// the model as text so that it can correct the call. A protocol or
        /// transport error is thrown, and the session reports it as a
        /// `ToolCallError`.
        public struct LanguageModelTool: FoundationModels.Tool {
            /// Approves or denies a model-initiated tool call before it is sent
            /// to the server. Return `true` to run the call, or `false` to
            /// tell the model that the call was not approved.
            public typealias Approval = @Sendable (MCP.Tool, [String: Value]) async throws -> Bool

            /// The arguments the model generates: an object that follows
            /// ``parameters``.
            public typealias Arguments = GeneratedContent
            /// The result of the call, as text for the model.
            public typealias Output = String

            /// The MCP definition of the tool.
            public let tool: MCP.Tool
            /// The tool's input schema, as a generation schema.
            public let parameters: GenerationSchema
            private let client: Client
            private let approval: Approval?

            /// The MCP name of the tool.
            public var name: String { tool.name }

            /// The tool's description, or its title when it has none.
            public var description: String {
                tool.description ?? tool.title ?? tool.annotations.title ?? ""
            }

            /// Wraps a tool of the server that `client` is connected to.
            ///
            /// - Parameters:
            ///   - tool: The MCP tool definition. Must be visible to the model
            ///     (``MCP/Tool/isVisibleToModel``).
            ///   - client: The connected MCP client that executes `tools/call`.
            ///   - approval: Optional human-in-the-loop or policy check run
            ///     before each call is sent to the server.
            /// - Throws: ``MCPError/invalidParams(_:)`` when
            ///   `tool.isVisibleToModel` is `false`;
            ///   ``FoundationModels/GenerationSchema/JSONSchemaError`` or
            ///   `SchemaError` when the tool's input schema cannot be
            ///   converted; see
            ///   ``FoundationModels/GenerationSchema/init(jsonSchema:name:)``.
            public init(
                _ tool: MCP.Tool,
                client: Client,
                approval: Approval? = nil
            ) throws {
                guard tool.isVisibleToModel else {
                    throw MCPError.invalidParams(
                        "Tool \(tool.name) is not visible to the language model")
                }
                self.tool = tool
                self.parameters = try GenerationSchema(jsonSchema: tool.inputSchema, name: tool.name)
                self.client = client
                self.approval = approval
            }

            /// Calls the tool on the server with the arguments the model
            /// generated.
            ///
            /// Any property that the tool's `inputSchema` marks as both
            /// `required` and nullable, and that the model omitted, is filled
            /// in as `null` before approval and execution.
            ///
            /// - Throws: ``MCPError/invalidParams(_:)`` when `arguments` is not
            ///   an object; any error thrown by the `approval` callback or
            ///   ``Client/callTool(name:arguments:meta:)``.
            public func call(arguments: GeneratedContent) async throws -> String {
                guard case .object(let rawObject) = Value(arguments) else {
                    throw MCPError.invalidParams("The arguments of tool \(tool.name) must be an object")
                }
                let object = JSONSchemaConverter.backfillRequiredNulls(
                    in: rawObject, schema: tool.inputSchema)
                if let approval {
                    guard try await approval(tool, object) else {
                        return "Error: Tool call to \(tool.name) was not approved."
                    }
                }
                let result = try await client.callTool(name: tool.name, arguments: object)
                return Self.text(of: result)
            }

            /// The result of a call, as text for the model.
            static func text(of result: CallTool.Result) -> String {
                var texts: [String] = []
                var others: [String] = []
                for content in result.content {
                    switch content {
                    case .text(let text, _, _):
                        texts.append(text)
                    case .image(_, let mimeType, _, _):
                        others.append("[image: \(mimeType)]")
                    case .audio(_, let mimeType, _, _):
                        others.append("[audio: \(mimeType)]")
                    case .resource(let resource, _, _):
                        if let text = resource.text {
                            texts.append(text)
                        } else {
                            others.append("[resource: \(resource.uri)]")
                        }
                    case .resourceLink(let uri, _, _, _, _, _):
                        others.append("[resource: \(uri)]")
                    case .unknown(let type, _):
                        others.append("[\(type)]")
                    }
                }
                if texts.isEmpty, let structured = result.structuredContent {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    if let data = try? encoder.encode(structured) {
                        texts.append(String(decoding: data, as: UTF8.self))
                    }
                }
                var parts = texts
                if !others.isEmpty { parts.append(others.joined(separator: "\n")) }
                let body = parts.joined(separator: "\n\n")
                if result.isError == true {
                    return body.isEmpty ? "Error: Tool call failed." : "Error: \(body)"
                }
                return body
            }
        }

        /// The server's tools, for a FoundationModels `LanguageModelSession`.
        ///
        /// Lists every page of the server's tools (`tools/list`, stopping on a
        /// repeated or empty cursor or after `maxListingPages` pages) and wraps
        /// each distinct tool name in a ``LanguageModelTool``. Tools for views
        /// only (MCP Apps,
        /// ``MCP/Tool/isVisibleToModel``) are left out. A tool whose input
        /// schema cannot be converted is left out too, with a warning in the
        /// log; to fail instead, list the tools with ``listTools(cursor:)`` and
        /// create each ``LanguageModelTool`` with
        /// ``LanguageModelTool/init(_:client:approval:)`` for tools where
        /// `tool.isVisibleToModel` is `true`.
        ///
        /// Pass `approval` to put a human or host policy check in the loop
        /// before model-initiated calls, especially when connecting to
        /// untrusted servers or exposing destructive tools.
        ///
        /// - Parameter approval: Optional callback run before each tool call is
        ///   sent to the server.
        /// - Throws: When the server has no tools capability, or listing its
        ///   tools fails.
        public func languageModelTools(
            approval: LanguageModelTool.Approval? = nil
        ) async throws -> [LanguageModelTool] {
            var tools: [LanguageModelTool] = []
            var seenTools = Set<String>()
            var cursor: String?
            var seen = Set<String>()
            var pages = 0
            repeat {
                let page = try await listTools(cursor: cursor)
                pages += 1
                for tool in page.tools where tool.isVisibleToModel && seenTools.insert(tool.name).inserted {
                    do {
                        tools.append(try LanguageModelTool(tool, client: self, approval: approval))
                    } catch {
                        await logger?.warning(
                            "A tool is not offered to the language model: its input schema cannot be converted",
                            metadata: [
                                "tool": "\(MCPRequestHeaders.sanitized(tool.name))",
                                "error": "\(MCPRequestHeaders.sanitized("\(error)", limit: 256))",
                            ])
                    }
                }
                cursor = page.nextCursor.flatMap {
                    $0.isEmpty || !seen.insert($0).inserted ? nil : $0
                }
            } while cursor != nil && pages < Self.maxListingPages
            return tools
        }
    }
#endif
