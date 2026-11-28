# Foundation Models

## Context

Apple's FoundationModels framework describes structured data with the `Generable` protocol, the
`@Generable` and `@Guide` macros, `GenerationSchema` and `GeneratedContent`. It runs tools that
conform to its own `Tool` protocol inside a `LanguageModelSession`. An MCP tool and a
FoundationModels tool describe the same thing, a named function with a JSON Schema for its
arguments, and `Sources/MCP/FoundationModels/` bridges them in both directions:

- [#135](https://github.com/modelcontextprotocol/swift-sdk/issues/135): harmonize `MCP.Tool` with
  `Generable`, so that a server can define a tool's arguments and output with `@Generable` types
  (or publish an existing `FoundationModels.Tool`) instead of a hand-written `Value` schema.
- [#169](https://github.com/modelcontextprotocol/swift-sdk/issues/169): give the tools of an MCP
  server to a `LanguageModelSession`. Decoding `inputSchema` into `GenerationSchema` with
  `JSONDecoder` failed (`keyNotFound("additionalProperties")`) because the `Codable` form of
  `GenerationSchema` is undocumented.

FoundationModels declarations are available from macOS 26, iOS 26, visionOS 26 and watchOS 27
(`SystemLanguageModel` itself is unavailable on watchOS, and the framework is unavailable on
tvOS). The SDK supports macOS 15, iOS 18, Mac Catalyst 18, visionOS 2, watchOS 11, tvOS 18 and
Linux ([platform policy](../VERSIONING.md#platforms)), and keeps building and running there.

## Goals

- A server defines a tool's `inputSchema` and `outputSchema` from `Generable` types, decodes
  `tools/call` arguments into them, and returns a `Generable` value as the result.
- An existing `FoundationModels.Tool` can be used in a local `LanguageModelSession` and published
  over MCP unchanged (`Examples/foundation-models`).
- A client turns the tools of an MCP server into `FoundationModels.Tool` values for a
  `LanguageModelSession`.
- Public FoundationModels API only, as declared in the SDK's `FoundationModels` module.
- No change for apps that do not use the bridge, on any platform, and no change on the wire.

Non-goals:

- A tool registry. The SDK still dispatches on method names ([design.md](design.md#goals)): the
  app writes its `tools/list` and `tools/call` handlers and uses the bridge inside them.
- A macro of the SDK's own. `@Generable` and `@Guide` come from FoundationModels; on older systems
  schemas stay hand-written `Value`s.
- Validating arguments against `@Guide` constraints. `GeneratedContent` decoding checks the
  structure and property types that the target type needs, as today.
- Running a language model inside the library. The bridge converts types; sessions belong to the
  application.

## Design

### Placement and availability

The bridge lives in the `MCP` target, in `Sources/MCP/FoundationModels/`, so one `import MCP`
gives it. Every file is wrapped in `#if canImport(FoundationModels)`, so it compiles out on Linux,
on Xcode 16.3 (whose SDKs predate the framework) and on any SDK without it. Every declaration
carries:

```swift
@available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
@available(tvOS, unavailable)
```

tvOS is excluded because the SDK marks the framework unavailable there. Lifting that later is
additive.

Linking. The package's deployment targets stay where they are, below the framework's. Every
FoundationModels symbol the target references is therefore newer than the deployment target, and
the compiler imports it weakly. When all references to a library are weak, the linker records
the library as `LC_LOAD_WEAK_DYLIB` (`dyld_info -dependents` shows `weak-link` on executables
built for the package's macOS 15 deployment target), so an app linking `MCP` still launches on
macOS 15, iOS 18, watchOS 11 and visionOS 2, where FoundationModels does not exist. SwiftPM offers no supported way to force a weak
link (`unsafeFlags` are refused for dependencies), so if a later toolchain links it strongly, the
bridge moves to a separate `MCPFoundationModels` product instead (see
[Alternatives considered](#alternatives-considered)).

Names. `MCP.Tool` and `FoundationModels.Tool` collide in a file that imports both modules. The
SDK qualifies both everywhere in the bridge; the guides tell users to do the same.

### Values: `Value` ↔ `GeneratedContent`

Both are JSON trees. Two public initializers convert between them, walking `GeneratedContent.kind`
on one side and the `Value` cases on the other:

| `Value` | `GeneratedContent.Kind` |
|---|---|
| `.null` | `.null` |
| `.bool` | `.bool` |
| `.int`, `.double` | `.number(Double)` |
| `.string` | `.string` |
| `.data(mimeType:_:)` | `.string`, as the `data:` URL it is encoded as on the wire |
| `.array` | `.array` |
| `.object` | `.structure(properties:orderedKeys:)` |

- `Value.init(_ content: GeneratedContent)`: a `.number` that is integral and fits in `Int`
  becomes `.int`, the same choice `Value`'s own decoder makes for JSON numbers. Property order is
  lost, since `Value.object` is a dictionary.
- `GeneratedContent.init(_ value: Value)`: object keys are emitted in sorted order, so the result
  is deterministic. Because `GeneratedContent` stores numbers as `Double`, integers with magnitude
  above `2^53` lose precision; `CallTool.Parameters.arguments(as:)` rejects out-of-range integers
  before conversion.

`GeneratedContent.init(json:)` and `jsonString` are not used for conversion or serialization:
`jsonString` traps on non-finite numbers and on structures whose `orderedKeys` names a key missing
from `properties`.

### Server: tools from `Generable` types (#135)

```swift
@Generable
struct WeatherQuery {
    @Guide(description: "City name")
    var city: String
    @Guide(description: "Days ahead", .range(1...7))
    var days: Int
}

let weather = try MCP.Tool(
    name: "get_weather",
    description: "Forecast for a city",
    arguments: WeatherQuery.self)

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case weather.name:
        let query = try params.arguments(as: WeatherQuery.self)
        return try CallTool.Result(try await forecast(query))   // a @Generable Forecast
    default:
        throw MCPError.invalidParams("Unknown tool: \(params.name)")
    }
}
```

API, all additive:

| Declaration | Behavior |
|---|---|
| `MCP.Tool.init<Arguments: Generable>(name:title:description:arguments:annotations:icons:_meta:execution:) throws` | `inputSchema` is `Arguments.generationSchema` encoded as JSON Schema. Throws `GenerationSchema.JSONSchemaError` when the root is not `type: "object"`, which MCP requires: a `@Generable` enum or a `String` cannot be the arguments. |
| The same with `output: Output.Type` (`Output: Generable`) | Also fills `outputSchema`, with the same rule. |
| `MCP.Tool.init(_ tool: some FoundationModels.Tool, title:annotations:icons:_meta:execution:) throws` | `name`, `description` and `parameters` come from the tool, and `outputSchema` from `Output` when it is a `Generable` object, so one tool serves a local session and MCP. |
| `CallTool.Parameters.arguments<T: ConvertibleFromGeneratedContent>(as:) throws -> T` | Missing `arguments` count as `{}`. Rejects `Value.int`s outside IEEE-754 exact `Double` precision (`±2^53`, compared in `Int64`) and non-finite numbers rather than rounding. An integer literal that does not fit in `Int` (above `2^31` on 32-bit watchOS) is decoded by `Value` as a `Double`, already rounded, before the check. A conversion failure throws `MCPError.invalidParams` (-32602); any `MCPError` thrown by `T.init` passes through unchanged. |
| `CallTool.Result.init(_ output: some ConvertibleToGeneratedContent, isError:_meta:) throws` | A structure becomes `structuredContent`, plus its JSON as one text block (encoded via `Value` and `JSONEncoder`, throwing `EncodingError` on non-finite numbers); null-valued object properties (such as `nil` optionals built with `GeneratedContent(properties:)`) are omitted so `structuredContent` conforms to the non-nullable properties of a `GenerationSchema`. A string becomes one text block and no `structuredContent`. Anything else becomes one text block with its JSON. |
| `FoundationModels.Tool.call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result`, where `Output: ConvertibleToGeneratedContent` | Decodes the arguments, calls `call(arguments:)` and wraps the output. An error thrown by the tool becomes a result with `isError: true` and `(error as? LocalizedError)?.errorDescription ?? "The tool failed."` as text: the bridged `localizedDescription` of other errors names the module, type and case. `MCPError` and `CancellationError` (including cancelled tasks) are rethrown unchanged. |

Generated schema → JSON Schema. `GenerationSchema` is `Codable`; the bridge encodes it into a
`Value` and uses it unchanged:

- `type`, `properties`, `required`, `description`, `enum` for string choices, `anyOf` for other
  choices, `const`, `items`, `minItems`/`maxItems`, `minimum`/`maximum`, `pattern`.
- Nested types under `$defs`, referenced as `#/$defs/<name>`; a recursive reference to the root
  as `#`. An optional property is left out of `required`, not made nullable.
- `additionalProperties: false` on every object, which is what `@Generable` structs mean.
- `title` (the type name) and `x-order` (the declaration order of the properties). Keeping them
  lets a Swift client restore the property order and makes `Generable` → JSON Schema →
  `GenerationSchema` → JSON Schema an exact round trip. Other clients ignore `x-*` keywords.

The schema is pinned by golden tests, so a change in the framework's encoder fails a test instead
of changing the wire silently.

### Client: MCP tools for a `LanguageModelSession` (#169)

```swift
let tools = try await client.languageModelTools { tool, arguments in
    try await confirm(tool, arguments)
}
let session = LanguageModelSession(tools: tools, instructions: "Answer with the tools.")
let answer = try await session.respond(to: "Weather in Zürich tomorrow?")
```

`GenerationSchema.init(jsonSchema: Value, name: String) throws` builds a `DynamicGenerationSchema`
from the JSON Schema and calls `GenerationSchema(root:dependencies:)`. It does not go through
`JSONDecoder`, whose `Codable` form is undocumented (#169).

| JSON Schema | `DynamicGenerationSchema` |
|---|---|
| `type: "object"`, `properties`, `required`, `description` | `init(name:description:properties:)`; a property not in `required` has `isOptional: true`, and `x-order` is deduplicated |
| `type: "string"` with `enum` | `init(name:description:anyOf: [String])` |
| `type: "string"` with `const` | `init(type: String.self, guides: [.constant(_)])` |
| `type: "string"` (including `pattern`) | `init(type: String.self)`: guided generation rejects anchors, character classes and lookarounds across the whole session, and JSON Schema `pattern` is a substring match rather than full-match |
| `type: "integer"` with `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` | `init(type: Int.self, guides:)` within `±(2^53 - 1)`; exclusive bounds move by one (including draft-04 booleans); extreme bounds outside `±(2^53 - 1)` are dropped |
| `type: "number"` with the same bounds | `init(type: Double.self, guides:)` within `±9e18` (larger bounds are dropped so they do not fault the inference provider); exclusive bounds are kept as inclusive |
| `type: "boolean"` | `init(type: Bool.self)` |
| `type: "array"` with `items`, `minItems`, `maxItems` | `init(arrayOf:minimumElements:maximumElements:)`; `maxItems > 10,000` is dropped, `minItems > 1,000` throws, and `items: false` caps length at `prefixItems.count` (or `0`, leaving elements as any non-null JSON value when `prefixItems` is non-empty) |
| `anyOf` or `oneOf` | `init(name:description:anyOf: [DynamicGenerationSchema])`, merging any sibling object `properties` and `required` (including across local `$ref` and nullable-object branches); at the root every choice (nested choices included) must be an object, an empty or type-less choice becomes an object with no properties, and a single choice becomes the root |
| `type: [T, "null"]`, or `anyOf` with `{"type": "null"}` | `T`, with the property optional (and backfilled as `null` in `call(arguments:)` when required and omitted) |
| `type: [T, U]` | `init(name:description:anyOf:)` with deduplicated types |
| `enum` of non-strings | the values' type, without the list (any JSON for mixed types) |
| Local JSON Pointer `$ref` (`#` or `#/...`, RFC 6901 §6) | `init(referenceTo:)` for named targets (preserving nullability across cached references), or inlined with cycle detection and node counting |
| `allOf` with one schema | that schema |
| non-root map, subschema without typing keywords, `true` | `init(type: GeneratedContent.self)`: any non-null JSON; an empty, `additionalProperties: true` or `additionalProperties: {}` root becomes an empty object |
| `pattern`, `format`, `minLength`, `maxLength`, `default`, `examples`, `title`, `not`, `if`/`then`/`else`, `prefixItems` (except its count with `items: false`), `x-*`, `$schema`, `$id` | ignored |

Names and resource bounds. `DynamicGenerationSchema` needs a unique name per object or choice, and
`"GeneratedContent"` is reserved up front so `anyJSON` never collides with a tool or `$defs` key.
Conversion is bounded to depth `32` (`maxDepth`, matching `MCPRequestHeaders.maxSchemaDepth` so
debug builds never overflow a cooperative thread stack) and `1,024` converted subschema nodes
(`maxNodes`, counting inlined expansions so DAGs cannot blow up exponentially).

What cannot be safely loosened throws `GenerationSchema.JSONSchemaError`, a struct with the JSON
pointer of the offending subschema and a readable reason, like `MCPRequestHeaders.InvalidAnnotation`:

- A root, or a choice of a root `anyOf`/`oneOf` (nested choices included), that does not
  resolve to an object, is a schema-valued map, or requires `minProperties > 0` without
  `properties`.
- Exceeding `maxDepth` (32) or `maxNodes` (1,024), including a choice that refers to itself
  through `$ref`.
- `false`, malformed keywords, `allOf` without exactly one schema, an unknown `type`, a schema
  that accepts only `null`, contradictory bounds (`minimum > maximum` or `minItems > maxItems`) or
  `minItems > 1,000`, a recursive reference through an unnamed schema, or an external/missing
  `$ref`.

`Client.LanguageModelTool` is a `struct` that conforms to `FoundationModels.Tool`:

- `Arguments` is `GeneratedContent`, `Output` is `String`.
- `init(_ tool: MCP.Tool, client: Client, approval: Approval? = nil) throws` enforces
  `tool.isVisibleToModel` (throwing `MCPError.invalidParams` for app-only tools) and converts
  `inputSchema` with `GenerationSchema(jsonSchema:name:)`. `name` is the MCP tool name,
  `description` is `description ?? title ?? annotations.title ?? ""`, and `tool` keeps the
  `MCP.Tool`.
- `call(arguments:)` requires a structure (else it throws), backfills `null` for any omitted
  property that the schema marks as both `required` and nullable, runs the optional `approval`
  callback (returning `"Error: Tool call to <name> was not approved."` when denied), and sends
  `client.callTool(name:arguments:)`. The result becomes text: the text blocks joined with blank
  lines, plus the text of embedded text resources; when there are none, the `structuredContent`
  JSON; images, audio, blobs and resource links become one line each (`[image: image/png]`,
  `[resource: <uri>]`). An `isError` result is prefixed with `"Error: "` (with a non-empty
  fallback when empty) and returned as text so the model can recover. Protocol and transport
  errors are thrown; the session reports them as `LanguageModelSession.ToolCallError`.

`Client.languageModelTools(approval:) async throws -> [Client.LanguageModelTool]` follows
`nextCursor` through `listTools` (stopping on an empty or repeated cursor, or after
`maxListingPages` = 100 pages) and keeps distinct model-visible tools (`isVisibleToModel`).

### Failure policy of `languageModelTools(approval:)`

One server tool with a schema the bridge cannot express must not make the whole server unusable
from a session:

| Source | Behavior on an item it cannot convert |
|---|---|
| FoundationModels | Conversions throw per item (`GenerationSchema(root:dependencies:)` throws `SchemaError`); `LanguageModelSession.init(tools:)` does not throw; a tool's error is wrapped in `ToolCallError`. |
| This SDK's client | Tools with invalid `x-mcp-header` annotations are removed from the `tools/list` result and a warning is logged ([request_headers.md](request_headers.md)). |

So the per-tool conversion throws a typed error (`LanguageModelTool.init` and
`GenerationSchema.init(jsonSchema:name:)`), and the list operation is lenient like the SDK's own
client:

- `languageModelTools(approval:)` throws for what makes the list unavailable: a missing `tools`
  capability, a failed `tools/list`, a transport error.
- A tool whose schema cannot be converted is left out, and a sanitized warning naming the tool and
  the error is logged through the client's logger.
- An app that wants all or nothing pages `listTools` itself and calls
  `try Client.LanguageModelTool(tool, client:)` per model-visible tool.

## Testing

`Tests/MCPTests/FoundationModelsTests.swift` (29 tests) and
`Examples/Tests/FoundationModelsSnippetTests.swift` (the guide snippets, in both eras), Swift
Testing, under `#if canImport(FoundationModels) && !os(tvOS)`, with `@available` on each test, so
a runner on macOS 15 skips them. No unit test runs a language model.

## Alternatives considered

- **A separate `MCPFoundationModels` product.** Apps would opt in, and `MCP` would never reference
  the framework, so no weak-link question. Rejected for one `import MCP` and because DocC, the doc
  coverage check and the snippets already cover the `MCP` target. It stays the fallback if a
  toolchain ever links the framework strongly.
- **An SDK macro mirroring `@Generable` on macOS 15 and iOS 18.** Needs swift-syntax as a
  dependency, duplicates the framework, and is the "macro layer" listed as a non-goal. Rejected.
- **Decoding JSON Schema into `GenerationSchema` with `JSONDecoder`.** The `Codable` form is
  undocumented and failed on ordinary MCP schemas (#169). Rejected for `DynamicGenerationSchema`.
- **Raising the deployment targets to the framework's (macOS 26, iOS 26, visionOS 26,
  watchOS 27).** It would drop every earlier system for all apps, including those that never use
  the bridge: a breaking change ([VERSIONING.md](../VERSIONING.md)). Rejected.
- **A `ToolBox` that holds `[any FoundationModels.Tool]` and answers `tools/list` and
  `tools/call`.** Convenient, but a second way to define tools, the registry the SDK does not
  have. Rejected for now; the building blocks make it a few lines of app code.
- **Throwing `CallTool.Result.isError` as an error in `LanguageModelTool`.** The session would end
  the response with `ToolCallError` for an error the model could have corrected. Rejected.

## Open questions

- Whether to report skipped tools to the caller (a returned list next to the tools) rather than
  only through the logger.
- Content that is not text (images, audio) reaches the model as placeholders. Mapping it to
  richer prompt content is later work.
- `representNilExplicitlyInGeneratedContent` (macOS 26.4) and `DynamicGenerationSchema.null`
  could make nullable-but-required properties exact in the schema itself rather than relying on
  `call(arguments:)` null backfilling. Not used, to keep one code path from 26.0.
