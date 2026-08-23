import Foundation

/// Document-level metadata carried at the top of a `.md` file inside a
/// `---` fenced YAML block. See ADR-0005.
///
/// Two kinds of fields live in here:
///
/// 1. **User fields** — anything the user types (`title`, `tags`, `authors`, …).
///    Original text is preserved verbatim so a parse → serialize round-trip
///    produces byte-identical output (per ADR-0002 § Frontmatter).
///
/// 2. **Done.md-managed namespace** (`feishu:`). Typed, restructured by
///    Done.md when sync state changes; user direct edits get normalized
///    away on the next save.
///
/// `Frontmatter.empty` represents "no `---` fence at the top of the file"
/// — distinct from "fence present but YAML body is empty".
public struct Frontmatter: Equatable {
    /// Top-level user keys in original order, each carrying the raw text
    /// slice from `<key>:` through the line preceding the next top-level
    /// key (or end of YAML body). Preserves comments, quoting style,
    /// indentation, blank lines — anything that wasn't `feishu:`.
    public var userFields: [UserField]

    /// Optional Done.md-managed `feishu:` subtree. `nil` when no such
    /// key exists in the source.
    public var feishu: FeishuFrontmatter?

    /// Position of the `feishu:` block in the original key order. `nil`
    /// when feishu is absent or when it was appended after parse. Used
    /// by serialize to keep the original line ordering.
    public var feishuOriginalIndex: Int?

    /// `true` iff the source had **no** leading `---` fence at all. An
    /// empty-but-present fence (`---\n---\n`) returns `.empty == false`
    /// with no userFields and no feishu — Done.md still emits the fence
    /// on serialize because the user explicitly wrote one.
    public var hasFence: Bool

    public static let empty = Frontmatter(
        userFields: [],
        feishu: nil,
        feishuOriginalIndex: nil,
        hasFence: false
    )

    public init(
        userFields: [UserField] = [],
        feishu: FeishuFrontmatter? = nil,
        feishuOriginalIndex: Int? = nil,
        hasFence: Bool = false
    ) {
        self.userFields = userFields
        self.feishu = feishu
        self.feishuOriginalIndex = feishuOriginalIndex
        self.hasFence = hasFence
    }

    /// Convenience: did parse find anything substantive?
    public var isEffectivelyEmpty: Bool {
        userFields.isEmpty && feishu == nil
    }
}

/// One top-level user key, captured as raw text. `rawBlock` includes the
/// trailing newline and any continuation / comment lines, but **not** the
/// final document-level newline. Storing raw text — instead of re-emitting
/// from a parsed YAML tree — is what lets Done.md promise "nothing gets
/// silently reformatted".
public struct UserField: Equatable {
    public let key: String
    public let rawBlock: String

    public init(key: String, rawBlock: String) {
        self.key = key
        self.rawBlock = rawBlock
    }
}

// MARK: - feishu namespace

/// Typed projection of the `feishu:` subtree. Every recognized field is
/// strongly typed; anything Done.md doesn't recognize sits in
/// `unknownFields` and round-trips untouched (acceptance: `feishu.foo:
/// bar` survives parse → serialize).
public struct FeishuFrontmatter: Equatable {
    public var docToken: DocToken?
    public var docURL: URL?
    public var lastPulledRevision: Int?
    public var lastPushedAt: Date?
    public var placeholderBlocks: [PlaceholderBlockRef]

    /// Anything under `feishu:` that isn't one of the recognized keys
    /// above. Stored as the original Yams node so Yams emit produces
    /// stable output.
    public var unknownFields: [UnknownField]

    public init(
        docToken: DocToken? = nil,
        docURL: URL? = nil,
        lastPulledRevision: Int? = nil,
        lastPushedAt: Date? = nil,
        placeholderBlocks: [PlaceholderBlockRef] = [],
        unknownFields: [UnknownField] = []
    ) {
        self.docToken = docToken
        self.docURL = docURL
        self.lastPulledRevision = lastPulledRevision
        self.lastPushedAt = lastPushedAt
        self.placeholderBlocks = placeholderBlocks
        self.unknownFields = unknownFields
    }

    public var isEmpty: Bool {
        docToken == nil
            && docURL == nil
            && lastPulledRevision == nil
            && lastPushedAt == nil
            && placeholderBlocks.isEmpty
            && unknownFields.isEmpty
    }
}

/// Typed wrapper around Feishu's `doc_token` string (e.g.
/// `doxcnAbc123XYZ`). A typed alias — not a String — to keep the API
/// surface honest: function signatures distinguish "any string" from
/// "the thing that identifies a Feishu doc".
public struct DocToken: Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One entry under `feishu.placeholder_blocks`. Mirrors the structure
/// drawn in ADR-0007.
public struct PlaceholderBlockRef: Equatable {
    public let blockId: String
    public let type: String
    public let title: String?

    public init(blockId: String, type: String, title: String? = nil) {
        self.blockId = blockId
        self.type = type
        self.title = title
    }
}

/// An unrecognized key under `feishu:` — preserved verbatim so a
/// future Done.md version (or a foreign tool that wrote it) doesn't
/// lose data on round-trip.
public struct UnknownField: Equatable {
    public let key: String
    /// Stored as the YAML text of just this field's value. Yams emits
    /// it verbatim — which means key order under `feishu:` is preserved
    /// only between recognized fields and unknown fields as groups, not
    /// fully interleaved. ADR-0005 accepts this trade-off.
    public let yamlValue: String

    public init(key: String, yamlValue: String) {
        self.key = key
        self.yamlValue = yamlValue
    }
}
