import Foundation

public enum MacrodexAgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MacrodexAgentJSONValue])
    case object([String: MacrodexAgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MacrodexAgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MacrodexAgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    public var intValue: Int? {
        guard let numberValue else {
            return nil
        }
        return Int(numberValue)
    }

    public var objectValue: [String: MacrodexAgentJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [MacrodexAgentJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    public subscript(key: String) -> MacrodexAgentJSONValue? {
        objectValue?[key]
    }

    public init(jsonObject value: Any) throws {
        switch value {
        case _ as NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Int64:
            self = .number(Double(value))
        case let value as UInt64:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as Float:
            self = .number(Double(value))
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try MacrodexAgentJSONValue(jsonObject: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try MacrodexAgentJSONValue(jsonObject: $0) })
        default:
            throw MacrodexAgentJSONValueError.unsupportedFoundationValue(String(describing: type(of: value)))
        }
    }

    public func jsonObject() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map { $0.jsonObject() }
        case .object(let value):
            return value.mapValues { $0.jsonObject() }
        }
    }
}

public enum MacrodexAgentJSONValueError: Error, Equatable, LocalizedError {
    case unsupportedFoundationValue(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFoundationValue(let type):
            return "Unsupported JSON foundation value: \(type)"
        }
    }
}

extension MacrodexAgentJSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension MacrodexAgentJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension MacrodexAgentJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension MacrodexAgentJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension MacrodexAgentJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension MacrodexAgentJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MacrodexAgentJSONValue...) {
        self = .array(elements)
    }
}

extension MacrodexAgentJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MacrodexAgentJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
