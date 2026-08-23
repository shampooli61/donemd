import Foundation

/// ProseMirror / Tiptap document JSON model.
///
/// Mirrors the JSON shape consumed by Tiptap's `editor.commands.setContent(json)`.
/// Optional fields are omitted from the encoded JSON (not encoded as `null`).
public struct TiptapNode: Equatable {
    public var type: String
    public var attrs: [String: AttrValue]?
    public var content: [TiptapNode]?
    public var text: String?
    public var marks: [TiptapMark]?

    public init(
        type: String,
        attrs: [String: AttrValue]? = nil,
        content: [TiptapNode]? = nil,
        text: String? = nil,
        marks: [TiptapMark]? = nil
    ) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.text = text
        self.marks = marks
    }
}

public struct TiptapMark: Equatable {
    public var type: String
    public var attrs: [String: AttrValue]?

    public init(type: String, attrs: [String: AttrValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }
}

/// JSON-compatible value used inside Tiptap node/mark `attrs`.
///
/// `null` is a real value Tiptap emits — e.g. the Link extension's default
/// `class: null` — so we need to round-trip it instead of failing decode.
///
/// `array` / `object` exist for nodes whose attrs hold structured data the
/// editor doesn't interpret but must preserve byte-for-byte (e.g. the
/// `feishu_placeholder_block` node's `unknown_fields` list — see ADR-0007).
public indirect enum AttrValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([AttrValue])
    case object([String: AttrValue])
}

// MARK: - Codable

extension TiptapNode: Codable {
    enum CodingKeys: String, CodingKey {
        case type, attrs, content, text, marks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        attrs = try c.decodeIfPresent([String: AttrValue].self, forKey: .attrs)
        content = try c.decodeIfPresent([TiptapNode].self, forKey: .content)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        marks = try c.decodeIfPresent([TiptapMark].self, forKey: .marks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(attrs, forKey: .attrs)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(marks, forKey: .marks)
    }
}

extension TiptapMark: Codable {
    enum CodingKeys: String, CodingKey {
        case type, attrs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        attrs = try c.decodeIfPresent([String: AttrValue].self, forKey: .attrs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(attrs, forKey: .attrs)
    }
}

extension AttrValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AttrValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: AttrValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "AttrValue: expected null, String, Int, Bool, array, or object"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Convenience factories

extension TiptapNode {
    public static let emptyDoc = TiptapNode(
        type: "doc",
        content: [TiptapNode(type: "paragraph")]
    )

    public static func text(_ s: String, marks: [TiptapMark]? = nil) -> TiptapNode {
        TiptapNode(type: "text", text: s, marks: marks)
    }
}
