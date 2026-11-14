import Foundation

/// FACEIT statistics dictionaries are declared in the swagger as free-form objects
/// (`additionalProperties: {}`), and almost every value inside is a *string* ("104.2", "1").
/// We decode them into this loose type and coerce on read; a missing key is a normal case.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Numeric view: accepts numbers and numeric strings ("81.94", "1", " 50 ").
    /// Empty strings and non-numeric strings are `nil` (treated as "no data", never as 0).
    public var double: Double? {
        switch self {
        case .number(let d): return d.isFinite ? d : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
            return d
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var int: Int? { double.map { Int($0.rounded()) } }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func double(_ key: String) -> Double? { self[key]?.double }
    func int(_ key: String) -> Int? { self[key]?.int }
    func string(_ key: String) -> String? {
        guard let s = self[key]?.string, !s.isEmpty else { return nil }
        return s
    }
}
