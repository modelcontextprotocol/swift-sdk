import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension GenerationSchema {
        /// Why a JSON Schema cannot be used as a generation schema, or as the
        /// schema of an MCP tool.
        public struct JSONSchemaError: Error, CustomStringConvertible, LocalizedError, Sendable {
            /// The JSON Pointer (RFC 6901) of the subschema at fault, empty
            /// for the root.
            public let pointer: String
            /// A readable reason.
            public let reason: String

            init(pointer: String, reason: String) {
                self.pointer = pointer
                self.reason = reason
            }

            /// The reason, prefixed with the pointer unless it is the root.
            public var description: String {
                pointer.isEmpty ? reason : "\(pointer): \(reason)"
            }

            /// The same text as ``description``.
            public var errorDescription: String? { description }
        }

        /// Creates a generation schema from a JSON Schema, such as the input
        /// schema of an MCP tool.
        ///
        /// The root must resolve to an object (`"type": "object"`). The
        /// conversion keeps what a generation schema can express and loosens
        /// constraints it cannot represent rather than narrowing them:
        ///
        /// - Objects keep `properties`, `required` and `description`, in the
        ///   order of `x-order` when it is present. A property that is not
        ///   required, or that may be `null`, is optional; when called through
        ///   ``MCP/Client/LanguageModelTool``, omitted properties that are both
        ///   required and nullable are sent as `null`.
        /// - `string`, `integer`, `number`, `boolean` and `array` keep `enum`
        ///   and `const` of strings, `minimum`, `maximum`, `exclusiveMinimum`,
        ///   `exclusiveMaximum` (within safe generation bounds), `items`,
        ///   `minItems` and `maxItems`. `items: false` caps the array length at
        ///   the count of `prefixItems` (or `0` when absent).
        /// - `anyOf`, `oneOf` and a list of types become choices (merging any
        ///   sibling object `properties` and `required`); `null` among them
        ///   makes the property optional.
        /// - Local JSON Pointer `$ref`s (`#` and `#/...`) and `allOf` with one
        ///   schema are followed.
        /// - A non-root map (an object without `properties`, unless
        ///   `additionalProperties` is `false`), a subschema with no `type`,
        ///   `properties`, `items` or composition keyword, and `true` accept
        ///   any non-null JSON value. An empty root object (including
        ///   `additionalProperties: true`), and an empty or type-less choice of
        ///   a root `anyOf` or `oneOf`, becomes an object with no properties.
        /// - Other keywords, such as `pattern`, `format`, `minLength`, `not`
        ///   or `if`/`then`/`else`, are ignored.
        ///
        /// - Parameters:
        ///   - jsonSchema: The JSON Schema.
        ///   - name: The name of the root schema, such as the tool name.
        /// - Throws: ``JSONSchemaError`` when the root, or a choice of a root
        ///   `anyOf` or `oneOf` (nested choices included), does not resolve to
        ///   an object or is a schema-valued map (or requires
        ///   `minProperties > 0` without `properties`), when the schema exceeds nesting or size
        ///   limits, or when a subschema is `false`, is malformed, has `allOf`
        ///   without exactly one schema, has an unknown `type`, accepts only
        ///   `null`, has contradictory bounds (`minimum > maximum` or
        ///   `minItems > maxItems`) or `minItems > 1000`, has a recursive
        ///   reference that does not target an object or choice, or has a
        ///   `$ref` outside the document. `SchemaError` when the framework
        ///   refuses the converted schema.
        public init(jsonSchema: Value, name: String) throws {
            var converter = JSONSchemaConverter(document: jsonSchema, rootName: name)
            let root = try converter.convertRoot()
            try self.init(root: root, dependencies: converter.dependencies)
        }
    }

    /// Converts a JSON Schema into `DynamicGenerationSchema`s.
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    struct JSONSchemaConverter {
        typealias JSONSchemaError = GenerationSchema.JSONSchemaError

        static let maxDepth = 32
        static let maxNodes = 1_024
        static let maxIntegerGuideMagnitude: Int64 = (1 << 53) - 1
        static let maxDoubleGuideMagnitude = 9e18
        static let maxMinimumArrayElements = 1_000
        static let maxMaximumArrayElements = 10_000

        /// A converted subschema.
        struct Converted {
            var schema: DynamicGenerationSchema
            /// Whether the subschema also accepts `null`.
            var nullable = false
            /// Number of converted subschema nodes in this subtree.
            var nodeCount = 1
        }

        private struct ResolvedReference {
            let pointer: String
            let key: String
            let schema: Value
        }

        let document: Value
        let rootName: String
        private let effectiveRootName: String
        /// The definitions that are not the root, in the order they are first referenced.
        private(set) var dependencies: [DynamicGenerationSchema] = []

        /// Named target schemas converted (or in progress), keyed by canonical JSON Pointer.
        private var namedReferences: [String: (name: String, nullable: Bool)] = [:]
        /// Unnamed target schemas converted once and inlined, keyed by canonical JSON Pointer.
        private var inlined: [String: Converted] = [:]
        /// Unnamed `$ref` pointers currently on the call stack, to detect cycles.
        private var activeReferences: Set<String> = []
        private var usedNames: Set<String> = []
        private var totalNodes = 0

        init(document: Value, rootName: String) {
            self.document = document
            self.rootName = rootName
            // Reserve "GeneratedContent" so `DynamicGenerationSchema(type: GeneratedContent.self)`
            // never collides with a tool or definition of the same name.
            usedNames.insert("GeneratedContent")
            if rootName == "GeneratedContent" {
                self.effectiveRootName = "GeneratedContent_2"
            } else {
                self.effectiveRootName = rootName
            }
            usedNames.insert(effectiveRootName)
        }

        mutating func convertRoot() throws -> DynamicGenerationSchema {
            let (keywords, rootPointer) = try resolveRootKeywords()
            let type = keywords["type"]
            let isObjectType: Bool
            switch type {
            case .string("object")?:
                isObjectType = true
            case .array(let list)? where list == [.string("object")]:
                isObjectType = true
            case nil:
                isObjectType = keywords["items"] == nil && keywords["enum"] == nil && keywords["const"] == nil
            default:
                isObjectType = false
            }
            guard isObjectType else {
                throw JSONSchemaError(pointer: rootPointer, reason: "The root schema must have type \"object\"")
            }
            let properties = keywords["properties"]?.objectValue ?? [:]
            if properties.isEmpty && keywords["anyOf"] == nil && keywords["oneOf"] == nil {
                try Self.validateObjectWithoutProperties(keywords, at: rootPointer)
            }
            for keyword in ["anyOf", "oneOf"] {
                if let choices = keywords[keyword] {
                    let merged = try Self.rootObjectChoices(
                        Self.mergeObjectBase(keywords, intoChoices: choices, in: document),
                        keyword: keyword, at: rootPointer, in: document)
                    return try choice(
                        merged, keyword: keyword, description: keywords["description"]?.stringValue,
                        at: rootPointer, name: effectiveRootName, reserved: true, depth: 0
                    ).schema
                }
            }
            return try object(keywords, at: rootPointer, name: effectiveRootName, reserved: true, isRoot: true, depth: 0)
                .schema
        }

        /// Throws when an object of the root (the root itself or one of its choices) has no
        /// `properties` and is a typed map or requires properties. Otherwise it converts to an
        /// object with no properties, since tool arguments are always an object.
        private static func validateObjectWithoutProperties(
            _ keywords: [String: Value], at pointer: String
        ) throws {
            if let minProperties = count(keywords["minProperties"]), minProperties > 0 {
                throw JSONSchemaError(
                    pointer: "\(pointer)/minProperties",
                    reason: "A root schema without properties cannot require minProperties > 0")
            }
            if keywords["patternProperties"] != nil {
                throw JSONSchemaError(
                    pointer: "\(pointer)/patternProperties",
                    reason: "A root schema that is a typed map is not supported")
            }
            if let additional = keywords["additionalProperties"],
                additional != .bool(false) && additional != .bool(true) && additional != .object([:])
            {
                throw JSONSchemaError(
                    pointer: "\(pointer)/additionalProperties",
                    reason: "A root schema that is a typed map is not supported")
            }
        }

        /// The choices of a root `anyOf` or `oneOf`, each resolved to an object schema.
        ///
        /// Tool arguments are an object, so every choice must convert to one. A choice that is
        /// not an object, or is a typed map, throws instead of letting the model generate, say,
        /// a string. A `$ref` choice is replaced by its target, so a single choice becomes the
        /// root itself, named after the tool, and `"$ref": "#"` still refers to a defined schema.
        /// A choice with its own `anyOf` or `oneOf` is checked the same way, after the choice's
        /// properties are merged into it. A choice without `properties` is marked
        /// `additionalProperties: false` and `type: "object"`: otherwise conversion, which treats
        /// such a non-root object as any JSON value, would let the model generate a non-object.
        private static func rootObjectChoices(
            _ choices: Value, keyword: String, at pointer: String, in document: Value, depth: Int = 0
        ) throws -> Value {
            guard depth <= maxDepth else {
                throw JSONSchemaError(pointer: pointer, reason: "The schema is nested deeper than \(maxDepth) levels")
            }
            guard let list = choices.arrayValue else { return choices }
            var resolved: [Value] = []
            for (index, option) in list.enumerated() {
                if isNull(option) {
                    resolved.append(option)
                    continue
                }
                let branchPointer = "\(pointer)/\(keyword)/\(index)"
                guard var branch = resolveObjectChoiceBranch(option, in: document) else {
                    throw JSONSchemaError(
                        pointer: branchPointer, reason: "Every choice of the root schema must be an object")
                }
                // Conversion follows the first of `anyOf` and `oneOf`, so check the same one.
                if let nestedKeyword = ["anyOf", "oneOf"].first(where: { branch[$0] != nil }),
                    let nested = branch[nestedKeyword]
                {
                    branch[nestedKeyword] = try rootObjectChoices(
                        mergeObjectBase(branch, intoChoices: nested, in: document),
                        keyword: nestedKeyword, at: branchPointer, in: document, depth: depth + 1)
                } else {
                    if (branch["properties"]?.objectValue ?? [:]).isEmpty {
                        try validateObjectWithoutProperties(branch, at: branchPointer)
                        branch["additionalProperties"] = .bool(false)
                    }
                    branch["type"] = .string("object")
                }
                resolved.append(.object(branch))
            }
            return .array(resolved)
        }

        /// Unwraps top-level `$ref` or single-element `allOf` to reach the root object keywords.
        private mutating func resolveRootKeywords() throws -> ([String: Value], String) {
            var current = document
            var pointer = ""
            var visited: Set<String> = [""]
            var steps = 0
            while true {
                guard steps <= Self.maxDepth else {
                    throw JSONSchemaError(
                        pointer: pointer, reason: "The schema is nested deeper than \(Self.maxDepth) levels")
                }
                guard let keywords = current.objectValue else {
                    throw JSONSchemaError(pointer: pointer, reason: "The schema must be an object")
                }
                if let ref = keywords["$ref"] {
                    guard let refString = ref.stringValue else {
                        throw JSONSchemaError(pointer: "\(pointer)/$ref", reason: "$ref must be a string")
                    }
                    if refString == "#" {
                        throw JSONSchemaError(pointer: "\(pointer)/$ref", reason: "Root schema cannot reference itself directly")
                    }
                    guard let resolved = Self.resolveLocalPointer(refString, in: document) else {
                        throw JSONSchemaError(
                            pointer: "\(pointer)/$ref",
                            reason: "Only local JSON Pointer references (#/...) to existing subschemas are supported")
                    }
                    guard visited.insert(resolved.pointer).inserted else {
                        throw JSONSchemaError(pointer: "\(pointer)/$ref", reason: "Cyclic root $ref is not supported")
                    }
                    current = resolved.schema
                    pointer = resolved.pointer
                    steps += 1
                    continue
                }
                if let allOf = keywords["allOf"] {
                    guard let schemas = allOf.arrayValue, !schemas.isEmpty else {
                        throw JSONSchemaError(
                            pointer: "\(pointer)/allOf", reason: "allOf must be a non-empty list of schemas")
                    }
                    guard schemas.count == 1 else {
                        throw JSONSchemaError(
                            pointer: "\(pointer)/allOf", reason: "allOf with more than one schema is not supported")
                    }
                    current = schemas[0]
                    pointer = "\(pointer)/allOf/0"
                    steps += 1
                    continue
                }
                return (keywords, pointer)
            }
        }

        // MARK: - Subschemas

        private mutating func addNodes(_ count: Int = 1, at pointer: String) throws {
            totalNodes += count
            if totalNodes > Self.maxNodes {
                throw JSONSchemaError(
                    pointer: pointer, reason: "The schema exceeds \(Self.maxNodes) converted subschemas")
            }
        }

        private mutating func convert(
            _ schema: Value, at pointer: String, name: String, reserved: Bool = false, depth: Int
        ) throws -> Converted {
            guard depth <= Self.maxDepth else {
                throw JSONSchemaError(
                    pointer: pointer, reason: "The schema is nested deeper than \(Self.maxDepth) levels")
            }
            if !reserved, !pointer.isEmpty, let existing = namedReferences[pointer] {
                try addNodes(1, at: pointer)
                return Converted(
                    schema: DynamicGenerationSchema(referenceTo: existing.name),
                    nullable: existing.nullable,
                    nodeCount: 1)
            }
            try addNodes(1, at: pointer)
            switch schema {
            case .bool(true):
                return Converted(schema: Self.anyJSON)
            case .bool(false):
                throw JSONSchemaError(pointer: pointer, reason: "The schema false accepts no value")
            case .object(let keywords):
                return try convert(keywords, at: pointer, name: name, reserved: reserved, depth: depth)
            default:
                throw JSONSchemaError(pointer: pointer, reason: "A schema must be an object or a boolean")
            }
        }

        private mutating func convert(
            _ keywords: [String: Value], at pointer: String, name: String, reserved: Bool, depth: Int
        ) throws -> Converted {
            if let ref = keywords["$ref"] {
                guard let ref = ref.stringValue else {
                    throw JSONSchemaError(pointer: "\(pointer)/$ref", reason: "$ref must be a string")
                }
                return try reference(ref, at: pointer, name: name, depth: depth)
            }
            if let allOf = keywords["allOf"] {
                guard let schemas = allOf.arrayValue, !schemas.isEmpty else {
                    throw JSONSchemaError(
                        pointer: "\(pointer)/allOf", reason: "allOf must be a non-empty list of schemas")
                }
                guard schemas.count == 1 else {
                    throw JSONSchemaError(
                        pointer: "\(pointer)/allOf", reason: "allOf with more than one schema is not supported")
                }
                return try convert(
                    schemas[0], at: "\(pointer)/allOf/0", name: name, reserved: reserved, depth: depth + 1)
            }
            for keyword in ["anyOf", "oneOf"] {
                if let choices = keywords[keyword] {
                    let merged = Self.mergeObjectBase(keywords, intoChoices: choices, in: document)
                    return try choice(
                        merged, keyword: keyword, description: keywords["description"]?.stringValue,
                        at: pointer, name: name, reserved: reserved, depth: depth)
                }
            }
            if let values = keywords["enum"] {
                return try enumeration(values, keywords, at: pointer, name: name, reserved: reserved)
            }
            if let value = keywords["const"] {
                if let string = value.stringValue {
                    return Converted(schema: DynamicGenerationSchema(type: String.self, guides: [.constant(string)]))
                }
                if value == .null {
                    throw JSONSchemaError(
                        pointer: "\(pointer)/const", reason: "A schema that accepts only null is not supported")
                }
                return Converted(schema: Self.schema(ofType: Self.type(of: value)))
            }

            var types: [String]
            switch keywords["type"] {
            case .string(let type)?:
                types = [type]
            case .array(let list)?:
                let rawTypes = list.compactMap(\.stringValue)
                guard rawTypes.count == list.count else {
                    throw JSONSchemaError(pointer: "\(pointer)/type", reason: "type must list strings")
                }
                var seenTypes = Set<String>()
                types = rawTypes.filter { seenTypes.insert($0).inserted }
            case nil:
                if keywords["properties"] != nil {
                    types = ["object"]
                } else if keywords["items"] != nil {
                    types = ["array"]
                } else {
                    return Converted(schema: Self.anyJSON)
                }
            default:
                throw JSONSchemaError(pointer: "\(pointer)/type", reason: "type must be a string or a list of strings")
            }
            let nullable = types.contains("null")
            types.removeAll { $0 == "null" }
            guard !types.isEmpty else {
                throw JSONSchemaError(pointer: pointer, reason: "A schema that accepts only null is not supported")
            }
            if types.count > 1 {
                let schemaName = reserved ? name : unique(name)
                var choices: [DynamicGenerationSchema] = []
                var nodes = 1
                for type in types {
                    var single = keywords
                    single["type"] = .string(type)
                    try addNodes(1, at: pointer)
                    let branch = try typed(
                        type, single, at: pointer, name: "\(schemaName).\(type)", depth: depth + 1)
                    choices.append(branch.schema)
                    nodes += branch.nodeCount
                }
                return Converted(
                    schema: DynamicGenerationSchema(
                        name: schemaName, description: keywords["description"]?.stringValue, anyOf: choices),
                    nullable: nullable,
                    nodeCount: nodes)
            }
            var converted = try typed(types[0], keywords, at: pointer, name: name, reserved: reserved, depth: depth)
            converted.nullable = converted.nullable || nullable
            return converted
        }

        private mutating func typed(
            _ type: String, _ keywords: [String: Value], at pointer: String, name: String, reserved: Bool = false,
            depth: Int
        ) throws -> Converted {
            switch type {
            case "object":
                return try object(
                    keywords, at: pointer, name: name, reserved: reserved, isRoot: false, depth: depth)
            case "array":
                return try array(keywords, at: pointer, name: name, depth: depth)
            case "string":
                // `pattern` is omitted: JSON Schema patterns have substring semantics and ECMA-262
                // features (anchors, character classes, lookarounds) that guided generation rejects
                // at run time across the whole session.
                return Converted(schema: DynamicGenerationSchema(type: String.self))
            case "integer":
                return Converted(schema: try integer(keywords, at: pointer))
            case "number":
                return Converted(schema: try number(keywords, at: pointer))
            case "boolean":
                return Converted(schema: DynamicGenerationSchema(type: Bool.self))
            default:
                throw JSONSchemaError(pointer: "\(pointer)/type", reason: "Unknown type \"\(type)\"")
            }
        }

        private mutating func object(
            _ keywords: [String: Value], at pointer: String, name: String, reserved: Bool, isRoot: Bool, depth: Int
        ) throws -> Converted {
            let description = keywords["description"]?.stringValue
            let properties = keywords["properties"]?.objectValue ?? [:]
            if properties.isEmpty && !isRoot
                && (keywords["additionalProperties"] != .bool(false) || keywords["patternProperties"] != nil)
            {
                // A map, or any object: its keys are not known.
                return Converted(schema: Self.anyJSON)
            }
            let schemaName = reserved ? name : unique(name)
            let required = Set(keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var seenOrder = Set<String>()
            let order = (keywords["x-order"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter {
                properties[$0] != nil && seenOrder.insert($0).inserted
            }
            let keys = order + properties.keys.filter { !seenOrder.contains($0) }.sorted()

            var converted: [DynamicGenerationSchema.Property] = []
            var nodes = 1
            for key in keys {
                guard let schema = properties[key] else { continue }
                let property = try convert(
                    schema, at: "\(pointer)/properties/\(Self.escaped(key))", name: "\(schemaName).\(key)",
                    depth: depth + 1)
                nodes += property.nodeCount
                converted.append(
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: schema.objectValue?["description"]?.stringValue,
                        schema: property.schema,
                        isOptional: !required.contains(key) || property.nullable))
            }
            return Converted(
                schema: DynamicGenerationSchema(name: schemaName, description: description, properties: converted),
                nodeCount: nodes)
        }

        private mutating func array(
            _ keywords: [String: Value], at pointer: String, name: String, depth: Int
        ) throws -> Converted {
            var items = Self.anyJSON
            var nodes = 1
            var itemsFalseCap: Int?
            if let schema = keywords["items"] {
                if schema == .bool(false) {
                    itemsFalseCap = keywords["prefixItems"]?.arrayValue?.count ?? 0
                    if itemsFalseCap == 0 {
                        items = DynamicGenerationSchema(type: String.self)
                    }
                } else if schema.objectValue != nil || schema == .bool(true) {
                    let element = try convert(
                        schema, at: "\(pointer)/items", name: "\(name).items", depth: depth + 1)
                    items = element.schema
                    nodes += element.nodeCount
                }
            }
            let rawMin = Self.count(keywords["minItems"])
            var rawMax = Self.count(keywords["maxItems"])
            if let cap = itemsFalseCap {
                rawMax = min(rawMax ?? cap, cap)
            }
            if let rawMin, let rawMax, rawMin > rawMax {
                throw JSONSchemaError(pointer: pointer, reason: "minItems is greater than maxItems")
            }
            if let rawMin, rawMin > Self.maxMinimumArrayElements {
                throw JSONSchemaError(
                    pointer: "\(pointer)/minItems",
                    reason: "minItems exceeds \(Self.maxMinimumArrayElements)")
            }
            let maximum = rawMax.flatMap { $0 <= Self.maxMaximumArrayElements ? $0 : nil }
            return Converted(
                schema: DynamicGenerationSchema(
                    arrayOf: items, minimumElements: rawMin, maximumElements: maximum),
                nodeCount: nodes)
        }

        private mutating func choice(
            _ choices: Value, keyword: String, description: String?, at pointer: String, name: String,
            reserved: Bool, depth: Int
        ) throws -> Converted {
            guard let choices = choices.arrayValue, !choices.isEmpty else {
                throw JSONSchemaError(pointer: "\(pointer)/\(keyword)", reason: "\(keyword) must be a non-empty list")
            }
            var nullable = false
            var options: [(schema: Value, pointer: String)] = []
            for (index, choice) in choices.enumerated() {
                if Self.isNull(choice) {
                    nullable = true
                } else {
                    options.append((choice, "\(pointer)/\(keyword)/\(index)"))
                }
            }
            guard !options.isEmpty else {
                throw JSONSchemaError(pointer: pointer, reason: "A schema that accepts only null is not supported")
            }
            if options.count == 1 {
                var converted = try convert(
                    options[0].schema, at: options[0].pointer, name: name, reserved: reserved, depth: depth + 1)
                converted.nullable = converted.nullable || nullable
                return converted
            }
            let schemaName = reserved ? name : unique(name)
            var converted: [DynamicGenerationSchema] = []
            var nodes = 1
            for (index, option) in options.enumerated() {
                let branch = try convert(
                    option.schema, at: option.pointer, name: "\(schemaName).\(index)", depth: depth + 1)
                converted.append(branch.schema)
                nodes += branch.nodeCount
            }
            return Converted(
                schema: DynamicGenerationSchema(name: schemaName, description: description, anyOf: converted),
                nullable: nullable,
                nodeCount: nodes)
        }

        private mutating func enumeration(
            _ values: Value, _ keywords: [String: Value], at pointer: String, name: String, reserved: Bool
        ) throws -> Converted {
            guard let values = values.arrayValue, !values.isEmpty else {
                throw JSONSchemaError(pointer: "\(pointer)/enum", reason: "enum must be a non-empty list")
            }
            let nullable = values.contains(.null)
            let others = values.filter { $0 != .null }
            guard !others.isEmpty else {
                throw JSONSchemaError(pointer: pointer, reason: "A schema that accepts only null is not supported")
            }
            let strings = others.compactMap(\.stringValue)
            if strings.count == others.count {
                let schemaName = reserved ? name : unique(name)
                return Converted(
                    schema: DynamicGenerationSchema(
                        name: schemaName, description: keywords["description"]?.stringValue, anyOf: strings),
                    nullable: nullable)
            }
            // Values that are not all strings: generate their type, without the list.
            let types = Set(others.map(Self.type(of:)))
            let schema = types.count == 1 ? Self.schema(ofType: types.first!) : Self.anyJSON
            return Converted(schema: schema, nullable: nullable)
        }

        private mutating func reference(
            _ ref: String, at pointer: String, name: String, depth: Int
        ) throws -> Converted {
            guard depth <= Self.maxDepth else {
                throw JSONSchemaError(
                    pointer: pointer, reason: "The schema is nested deeper than \(Self.maxDepth) levels")
            }
            if ref == "#" {
                return Converted(schema: DynamicGenerationSchema(referenceTo: effectiveRootName))
            }
            guard let target = Self.resolveLocalPointer(ref, in: document) else {
                throw JSONSchemaError(
                    pointer: "\(pointer)/$ref",
                    reason: "Only local JSON Pointer references (#/...) to existing subschemas are supported")
            }
            if let existing = namedReferences[target.pointer] {
                return Converted(
                    schema: DynamicGenerationSchema(referenceTo: existing.name),
                    nullable: existing.nullable)
            }
            if Self.isNamed(target.schema, in: document) {
                // Reserve the name and shallow nullability before converting the body so
                // recursive references resolve without unbounded recursion.
                let schemaName = unique(target.key)
                let initialNullable = Self.shallowNullable(target.schema)
                namedReferences[target.pointer] = (schemaName, initialNullable)
                let converted = try convert(
                    target.schema, at: target.pointer, name: schemaName, reserved: true, depth: depth + 1)
                namedReferences[target.pointer] = (schemaName, converted.nullable)
                dependencies.append(converted.schema)
                return Converted(
                    schema: DynamicGenerationSchema(referenceTo: schemaName),
                    nullable: converted.nullable)
            }
            guard activeReferences.insert(target.pointer).inserted else {
                throw JSONSchemaError(
                    pointer: "\(pointer)/$ref",
                    reason: "A recursive reference must target an object or choice schema")
            }
            defer { activeReferences.remove(target.pointer) }
            if let cached = inlined[target.pointer] {
                try addNodes(cached.nodeCount, at: pointer)
                return cached
            }
            let converted = try convert(
                target.schema, at: target.pointer, name: name, reserved: false, depth: depth + 1)
            inlined[target.pointer] = converted
            return converted
        }

        // MARK: - Numbers

        private func integer(_ keywords: [String: Value], at pointer: String) throws -> DynamicGenerationSchema {
            let minVal = keywords["minimum"]?.numberValue
            let maxVal = keywords["maximum"]?.numberValue
            var lower: Double?
            switch keywords["exclusiveMinimum"] {
            case .bool(true)?:
                lower = minVal.map { $0.rounded(.down) + 1 }
            case let value?:
                lower = minVal.map { $0.rounded(.up) }
                if let bound = value.numberValue {
                    lower = max(lower ?? -.infinity, bound.rounded(.down) + 1)
                }
            case nil:
                lower = minVal.map { $0.rounded(.up) }
            }
            var upper: Double?
            switch keywords["exclusiveMaximum"] {
            case .bool(true)?:
                upper = maxVal.map { $0.rounded(.up) - 1 }
            case let value?:
                upper = maxVal.map { $0.rounded(.down) }
                if let bound = value.numberValue {
                    upper = min(upper ?? .infinity, bound.rounded(.up) - 1)
                }
            case nil:
                upper = maxVal.map { $0.rounded(.down) }
            }
            if let lower, let upper, lower > upper {
                throw JSONSchemaError(pointer: pointer, reason: "The minimum is greater than the maximum")
            }
            let maxMag = Double(Self.maxIntegerGuideMagnitude)
            let minimum = lower.flatMap { abs($0) <= maxMag ? Int(exactly: $0) : nil }
            let maximum = upper.flatMap { abs($0) <= maxMag ? Int(exactly: $0) : nil }
            switch (minimum, maximum) {
            case let (minimum?, maximum?):
                return DynamicGenerationSchema(type: Int.self, guides: [.range(minimum...maximum)])
            case let (minimum?, nil):
                return DynamicGenerationSchema(type: Int.self, guides: [.minimum(minimum)])
            case let (nil, maximum?):
                return DynamicGenerationSchema(type: Int.self, guides: [.maximum(maximum)])
            case (nil, nil):
                return DynamicGenerationSchema(type: Int.self)
            }
        }

        private func number(_ keywords: [String: Value], at pointer: String) throws -> DynamicGenerationSchema {
            // Exclusive bounds are kept as inclusive: a generation guide has no exclusive form.
            let lowers = [keywords["minimum"], keywords["exclusiveMinimum"]].compactMap { $0?.numberValue }
            let uppers = [keywords["maximum"], keywords["exclusiveMaximum"]].compactMap { $0?.numberValue }
            let rawMin = lowers.max()
            let rawMax = uppers.min()
            if let rawMin, let rawMax, rawMin > rawMax {
                throw JSONSchemaError(pointer: pointer, reason: "The minimum is greater than the maximum")
            }
            let minimum = rawMin.flatMap { $0.isFinite && abs($0) <= Self.maxDoubleGuideMagnitude ? $0 : nil }
            let maximum = rawMax.flatMap { $0.isFinite && abs($0) <= Self.maxDoubleGuideMagnitude ? $0 : nil }
            switch (minimum, maximum) {
            case let (minimum?, maximum?):
                return DynamicGenerationSchema(type: Double.self, guides: [.range(minimum...maximum)])
            case let (minimum?, nil):
                return DynamicGenerationSchema(type: Double.self, guides: [.minimum(minimum)])
            case let (nil, maximum?):
                return DynamicGenerationSchema(type: Double.self, guides: [.maximum(maximum)])
            case (nil, nil):
                return DynamicGenerationSchema(type: Double.self)
            }
        }

        // MARK: - Required-nullable backfill

        /// Fills `null` for any property omitted from `arguments` that `schema` marks as both
        /// `required` and nullable, recursively across nested objects and arrays.
        static func backfillRequiredNulls(in arguments: [String: Value], schema: Value) -> [String: Value] {
            backfillObject(arguments, schema: schema, document: schema, depth: 0)
        }

        private static func backfillObject(
            _ arguments: [String: Value], schema: Value, document: Value, depth: Int
        ) -> [String: Value] {
            guard depth <= maxDepth,
                let resolved = unwrapNonNullBranch(schema, in: document, depth: depth),
                let keywords = resolved.objectValue
            else {
                return arguments
            }
            let properties = keywords["properties"]?.objectValue ?? [:]
            let required = keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var result = arguments
            for key in required where result[key] == nil {
                if let propSchema = properties[key], acceptsNull(propSchema, in: document, depth: depth + 1) {
                    result[key] = .null
                }
            }
            for (key, value) in result {
                if let propSchema = properties[key] {
                    result[key] = backfillValue(value, schema: propSchema, document: document, depth: depth + 1)
                }
            }
            return result
        }

        private static func backfillValue(
            _ value: Value, schema: Value, document: Value, depth: Int
        ) -> Value {
            guard depth <= maxDepth,
                let resolved = unwrapNonNullBranch(schema, in: document, depth: depth)
            else {
                return value
            }
            switch value {
            case .object(let child):
                // Same depth: conversion spends one unit per object level, already spent by the caller.
                return .object(backfillObject(child, schema: resolved, document: document, depth: depth))
            case .array(let elements):
                guard let items = resolved.objectValue?["items"], items.objectValue != nil else {
                    return value
                }
                return .array(
                    elements.map { backfillValue($0, schema: items, document: document, depth: depth + 1) })
            default:
                return value
            }
        }

        private static func unwrapSchema(_ schema: Value, in document: Value, depth: Int) -> Value? {
            guard depth <= maxDepth else { return nil }
            guard let keywords = schema.objectValue else { return schema }
            if let ref = keywords["$ref"]?.stringValue {
                if ref == "#" { return document }
                guard let resolved = resolveLocalPointer(ref, in: document) else { return nil }
                return unwrapSchema(resolved.schema, in: document, depth: depth + 1)
            }
            if let allOf = keywords["allOf"]?.arrayValue, allOf.count == 1 {
                return unwrapSchema(allOf[0], in: document, depth: depth + 1)
            }
            return schema
        }

        private static func unwrapNonNullBranch(_ schema: Value, in document: Value, depth: Int) -> Value? {
            guard let unwrapped = unwrapSchema(schema, in: document, depth: depth),
                let keywords = unwrapped.objectValue
            else {
                return nil
            }
            for keyword in ["anyOf", "oneOf"] {
                if let rawChoices = keywords[keyword], let choices = rawChoices.arrayValue {
                    // Merge the wrapper's own `properties` and `required` as conversion does, so a
                    // required property declared beside the single choice is backfilled too.
                    let merged = mergeObjectBase(keywords, intoChoices: rawChoices, in: document)
                    let nonNull = (merged.arrayValue ?? choices).filter { !isNull($0) }
                    if nonNull.count == 1 {
                        return unwrapNonNullBranch(nonNull[0], in: document, depth: depth + 1)
                    }
                }
            }
            return unwrapped
        }

        private static func acceptsNull(_ schema: Value, in document: Value, depth: Int) -> Bool {
            guard depth <= maxDepth,
                let unwrapped = unwrapSchema(schema, in: document, depth: depth)
            else {
                return false
            }
            if unwrapped == .bool(true) { return true }
            guard let keywords = unwrapped.objectValue else { return false }
            if isNull(unwrapped) { return true }
            if shallowNullable(unwrapped) { return true }
            for keyword in ["anyOf", "oneOf"] {
                if let choices = keywords[keyword]?.arrayValue {
                    if choices.contains(where: { acceptsNull($0, in: document, depth: depth + 1) }) {
                        return true
                    }
                }
            }
            return false
        }

        // MARK: - Helpers

        /// A schema that accepts any non-null JSON value.
        private static var anyJSON: DynamicGenerationSchema {
            DynamicGenerationSchema(type: GeneratedContent.self)
        }

        /// Merges sibling `properties`, `required` and `x-order` on `base` into each non-null
        /// object choice in `choices`, resolving local `$ref` branches when needed.
        private static func mergeObjectBase(
            _ base: [String: Value], intoChoices choices: Value, in document: Value
        ) -> Value {
            let baseProps = base["properties"]?.objectValue ?? [:]
            let baseReq = base["required"]?.arrayValue ?? []
            guard (!baseProps.isEmpty || !baseReq.isEmpty), let array = choices.arrayValue else {
                return choices
            }
            let merged = array.map { option -> Value in
                if isNull(option) { return option }
                guard var branch = resolveObjectChoiceBranch(option, in: document) else { return option }
                if !baseProps.isEmpty {
                    var combinedProps = baseProps
                    for (k, v) in branch["properties"]?.objectValue ?? [:] {
                        combinedProps[k] = v
                    }
                    branch["properties"] = .object(combinedProps)
                }
                if !baseReq.isEmpty {
                    var seen = Set<String>()
                    var combinedReq: [Value] = []
                    for item in baseReq + (branch["required"]?.arrayValue ?? []) {
                        if let key = item.stringValue, seen.insert(key).inserted {
                            combinedReq.append(.string(key))
                        }
                    }
                    branch["required"] = .array(combinedReq)
                }
                if branch["type"] == nil {
                    branch["type"] = .string("object")
                }
                if branch["x-order"] == nil, let order = base["x-order"] {
                    branch["x-order"] = order
                }
                return .object(branch)
            }
            return .array(merged)
        }

        /// Resolves `option` (following local non-root `$ref`s and single-item `allOf`s) when it
        /// represents an object schema into which sibling base properties can be merged.
        private static func resolveObjectChoiceBranch(
            _ option: Value, in document: Value
        ) -> [String: Value]? {
            guard let initial = option.objectValue else { return nil }
            let overrideDescription = initial["description"]
            var current = initial
            var visited = Set<String>()
            var steps = 0
            while true {
                guard steps <= maxDepth else { return nil }
                if let refValue = current["$ref"] {
                    guard let ref = refValue.stringValue, ref != "#",
                        let resolved = resolveLocalPointer(ref, in: document),
                        visited.insert(resolved.pointer).inserted,
                        let target = resolved.schema.objectValue
                    else {
                        return nil
                    }
                    current = target
                    steps += 1
                    continue
                }
                if let allOf = current["allOf"]?.arrayValue, allOf.count == 1,
                    let single = allOf[0].objectValue
                {
                    current = single
                    steps += 1
                    continue
                }
                break
            }
            if current["enum"] != nil || current["const"] != nil || current["items"] != nil {
                return nil
            }
            switch current["type"] {
            case nil, .string("object")?:
                break
            case .array(let list)? where list == [.string("object")]:
                current["type"] = .string("object")
            case .array(let list)?
            where list.contains(.string("object"))
                && list.allSatisfy({ $0 == .string("object") || $0 == .string("null") }):
                // A nullable object: the merged properties apply when it is an object.
                break
            default:
                return nil
            }
            if let overrideDescription, current["description"] == nil {
                current["description"] = overrideDescription
            }
            return current
        }

        /// Resolves a local JSON Pointer URI fragment (`#/...`, RFC 6901 §6) in `document`.
        private static func resolveLocalPointer(_ ref: String, in document: Value) -> ResolvedReference? {
            guard ref.hasPrefix("#/") else { return nil }
            let rawPointer = String(ref.dropFirst())
            let decodedPointer = rawPointer.removingPercentEncoding ?? rawPointer
            guard decodedPointer.hasPrefix("/") else { return nil }
            let rawSegments = decodedPointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            var current = document
            var segments: [String] = []
            for raw in rawSegments {
                let segment = raw.replacingOccurrences(of: "~1", with: "/")
                    .replacingOccurrences(of: "~0", with: "~")
                segments.append(segment)
                switch current {
                case .object(let dict):
                    guard let next = dict[segment] else { return nil }
                    current = next
                case .array(let array):
                    guard let index = Int(segment), array.indices.contains(index) else { return nil }
                    current = array[index]
                default:
                    return nil
                }
            }
            let canonicalPointer = "/" + segments.map(escaped).joined(separator: "/")
            return ResolvedReference(
                pointer: canonicalPointer,
                key: segments.last ?? "Schema",
                schema: current)
        }

        /// A name that no other schema of the document has.
        private mutating func unique(_ base: String) -> String {
            var candidate = base
            var suffix = 2
            while !usedNames.insert(candidate).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            return candidate
        }

        /// Whether a subschema converts to a named `DynamicGenerationSchema`, which can be referenced.
        ///
        /// Bounded by `maxDepth`: a merged `$ref` choice keeps its target's own choices, so a
        /// self-referencing choice would otherwise expand forever. Past the bound it answers
        /// `false`, and the inline conversion path throws for the depth.
        private static func isNamed(_ schema: Value, in document: Value, depth: Int = 0) -> Bool {
            guard depth <= maxDepth, let keywords = schema.objectValue else { return false }
            if keywords["$ref"] != nil { return false }
            if let allOf = keywords["allOf"]?.arrayValue, allOf.count == 1 {
                return isNamed(allOf[0], in: document, depth: depth + 1)
            }
            for keyword in ["anyOf", "oneOf"] {
                if let rawChoices = keywords[keyword] {
                    let merged = mergeObjectBase(keywords, intoChoices: rawChoices, in: document)
                    if let choices = merged.arrayValue {
                        let options = choices.filter { !isNull($0) }
                        return options.count > 1
                            || (options.count == 1 && isNamed(options[0], in: document, depth: depth + 1))
                    }
                }
            }
            if let values = keywords["enum"]?.arrayValue {
                let others = values.filter { $0 != .null }
                return !others.isEmpty && others.allSatisfy { $0.stringValue != nil }
            }
            if keywords["const"] != nil { return false }
            var types: [String]
            switch keywords["type"] {
            case .string(let type)?:
                types = [type]
            case .array(let list)?:
                var seen = Set<String>()
                types = list.compactMap(\.stringValue).filter { seen.insert($0).inserted }
            default:
                types = keywords["properties"] != nil ? ["object"] : []
            }
            types.removeAll { $0 == "null" }
            if types.count > 1 { return true }
            guard types == ["object"] else { return false }
            let properties = keywords["properties"]?.objectValue ?? [:]
            return !properties.isEmpty
                || (keywords["additionalProperties"] == .bool(false) && keywords["patternProperties"] == nil)
        }

        private static func shallowNullable(_ schema: Value) -> Bool {
            guard let keywords = schema.objectValue else { return false }
            if let list = keywords["type"]?.arrayValue, list.contains(.string("null")) { return true }
            if let values = keywords["enum"]?.arrayValue, values.contains(.null) { return true }
            for keyword in ["anyOf", "oneOf"] {
                if let choices = keywords[keyword]?.arrayValue, choices.contains(where: isNull) {
                    return true
                }
            }
            return false
        }

        private static func isNull(_ schema: Value) -> Bool {
            guard let keywords = schema.objectValue else { return false }
            return keywords["type"] == .string("null") || keywords["const"] == .null
                || keywords["enum"] == .array([.null])
        }

        private static func type(of value: Value) -> String {
            switch value {
            case .bool: return "boolean"
            case .int: return "integer"
            case .double: return "number"
            case .string, .data: return "string"
            case .array: return "array"
            case .object: return "object"
            case .null: return "null"
            }
        }

        private static func schema(ofType type: String) -> DynamicGenerationSchema {
            switch type {
            case "boolean": return DynamicGenerationSchema(type: Bool.self)
            case "integer": return DynamicGenerationSchema(type: Int.self)
            case "number": return DynamicGenerationSchema(type: Double.self)
            case "string": return DynamicGenerationSchema(type: String.self)
            default: return anyJSON
            }
        }

        /// A `minItems` or `maxItems` value, as a non-negative integer.
        private static func count(_ value: Value?) -> Int? {
            value?.numberValue.flatMap { Int(exactly: $0) }.map { max($0, 0) }
        }

        /// `key` escaped for a JSON Pointer (RFC 6901 §3).
        private static func escaped(_ key: String) -> String {
            key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }
    }
#endif
