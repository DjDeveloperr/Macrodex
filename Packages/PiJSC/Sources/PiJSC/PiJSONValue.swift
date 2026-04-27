import Foundation

public enum PiJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PiJSONValue])
    case object([String: PiJSONValue])

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
        } else if let value = try? container.decode([PiJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PiJSONValue].self) {
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

    public var objectValue: [String: PiJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [PiJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    public subscript(key: String) -> PiJSONValue? {
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
            self = .array(try value.map { try PiJSONValue(jsonObject: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try PiJSONValue(jsonObject: $0) })
        default:
            throw PiJSONValueError.unsupportedFoundationValue(String(describing: type(of: value)))
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

public enum PiJSONValueError: Error, Equatable, LocalizedError {
    case unsupportedFoundationValue(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFoundationValue(let type):
            return "Unsupported JSON foundation value: \(type)"
        }
    }
}

extension PiJSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension PiJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension PiJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension PiJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension PiJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension PiJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: PiJSONValue...) {
        self = .array(elements)
    }
}

extension PiJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, PiJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
