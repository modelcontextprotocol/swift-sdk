import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension Value {
        /// Creates a value from FoundationModels generated content.
        ///
        /// A number that is integral and fits in `Int` becomes ``int(_:)``, as
        /// when `Value` decodes JSON; any other number becomes ``double(_:)``.
        /// An object keeps its properties but not their order.
        public init(_ content: GeneratedContent) {
            switch content.kind {
            case .null:
                self = .null
            case .bool(let value):
                self = .bool(value)
            case .number(let value):
                if let integer = Int(exactly: value) {
                    self = .int(integer)
                } else {
                    self = .double(value)
                }
            case .string(let value):
                self = .string(value)
            case .array(let elements):
                self = .array(elements.map(Value.init))
            case .structure(let properties, _):
                self = .object(properties.mapValues(Value.init))
            @unknown default:
                self = .string(content.jsonString)
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, visionOS 26.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension GeneratedContent {
        /// Creates FoundationModels generated content from a value.
        ///
        /// ``Value/data(mimeType:_:)`` becomes the `data:` URL string it is
        /// encoded as on the wire. `GeneratedContent` represents numbers as
        /// `Double`, so integers with magnitude above `2^53` (`9_007_199_254_740_992`)
        /// lose precision; ``CallTool/Parameters/arguments(as:)`` rejects
        /// out-of-range integers before conversion. The properties of an object
        /// are in sorted order.
        public init(_ value: Value) {
            switch value {
            case .null:
                self.init(kind: .null)
            case .bool(let value):
                self.init(kind: .bool(value))
            case .int(let value):
                self.init(kind: .number(Double(value)))
            case .double(let value):
                self.init(kind: .number(value))
            case .string(let value):
                self.init(kind: .string(value))
            case let .data(mimeType, data):
                self.init(kind: .string(data.dataURLEncoded(mimeType: mimeType)))
            case .array(let elements):
                self.init(kind: .array(elements.map(GeneratedContent.init)))
            case .object(let properties):
                self.init(
                    kind: .structure(
                        properties: properties.mapValues(GeneratedContent.init),
                        orderedKeys: properties.keys.sorted()))
            }
        }
    }
#endif
