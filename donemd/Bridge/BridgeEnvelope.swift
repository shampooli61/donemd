import Foundation

/// Versioned envelope for every Swift ↔ JS message.
///
/// JSON shape:
///   `{ "version": 1, "type": "loadDocument", "payload": <JSON> }`
public struct BridgeEnvelope: Equatable {
    public let version: Int
    public let type: String
    public let payload: JSONValue

    /// Increment when the envelope format itself changes (not when adding new
    /// `type`s — those are additive and don't bump the version).
    public static let currentVersion = 1

    public init(type: String, payload: JSONValue, version: Int = BridgeEnvelope.currentVersion) {
        self.version = version
        self.type = type
        self.payload = payload
    }
}

extension BridgeEnvelope: Codable {
    enum CodingKeys: String, CodingKey {
        case version, type, payload
    }
}

/// Heterogeneous JSON value used as the bridge payload type.
///
/// Stays lightweight — we deliberately don't use `Any` to keep the type
/// system honest across the Swift↔JS boundary.
public indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "JSONValue: not a recognized JSON primitive/array/object"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .integer(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Errors raised while validating or dispatching an envelope.
public enum BridgeError: Error, Equatable {
    case unsupportedVersion(received: Int, current: Int)
    case unknownType(String)
    case decodeFailure(String)
}
