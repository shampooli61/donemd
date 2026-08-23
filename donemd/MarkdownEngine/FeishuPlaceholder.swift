import Foundation

/// One occurrence of a Feishu placeholder block — the local projection of a
/// Feishu-native block (sheet / mindnote / board / bitable / attachment /
/// video / 3rd-party embed) that has no Markdown equivalent. Persisted to
/// disk as a `<!-- feishu-placeholder ... -->` HTML comment per ADR-0007.
public struct FeishuPlaceholder: Equatable {
    public let type: String
    public let blockId: String
    public let blockToken: String?
    public let title: String
    public let summary: String?
    public let url: String
    public let createdInFeishuAt: String?
    /// Fields the parser saw but didn't recognize, preserved verbatim in
    /// original order. Future Feishu metadata extensions round-trip through
    /// here untouched until Done.md grows a typed accessor for them.
    public let unknownFields: [UnknownPlaceholderField]

    public init(
        type: String,
        blockId: String,
        blockToken: String? = nil,
        title: String,
        summary: String? = nil,
        url: String,
        createdInFeishuAt: String? = nil,
        unknownFields: [UnknownPlaceholderField] = []
    ) {
        self.type = type
        self.blockId = blockId
        self.blockToken = blockToken
        self.title = title
        self.summary = summary
        self.url = url
        self.createdInFeishuAt = createdInFeishuAt
        self.unknownFields = unknownFields
    }
}

/// One unrecognized `key: value` line inside a placeholder magic comment.
public struct UnknownPlaceholderField: Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Parser + serializer for the placeholder magic comment. Hand-rolled state
/// machine — does not go through Yams. Rationale in ADR-0007 § 解析器:
///   - placeholder body is a tightly constrained YAML subset (single-line
///     `key: value` pairs only); a real YAML parser would silently coerce
///     values like `summary: yes` into booleans
///   - the parser must recover from corrupt input (return nil, let the
///     caller fall back to a raw markdown block); throwing parsers can't
///     do that
public enum FeishuPlaceholderEngine {
    /// First line of every placeholder magic comment. Exact match — no
    /// extra whitespace, no case variants.
    public static let openerLine = "<!-- feishu-placeholder"

    /// Last line of every placeholder magic comment.
    public static let closerLine = "-->"

    /// Field names Done.md recognizes today. Anything else lands in
    /// `unknownFields` and round-trips untouched.
    public static let knownFields: Set<String> = [
        "type",
        "block_id",
        "block_token",
        "title",
        "summary",
        "url",
        "created_in_feishu_at",
    ]

    /// Field names that must be present and non-empty for the parse to
    /// succeed. Missing → return nil → caller renders as a raw markdown
    /// block instead, preserving the original bytes.
    ///
    /// `url` is deliberately NOT required (#89): for feishu-native blocks it
    /// equals `feishu://<type>/<block_token>` and is fully derivable from the
    /// fields that remain, so we omit it on disk and backfill on parse. Only
    /// `embed` carries a non-derivable external url — and an embed with no
    /// url line is genuinely corrupt, but that degrades gracefully (backfills
    /// to "", the "open in Feishu" button just doesn't render) rather than
    /// dropping the whole block to a raw comment.
    public static let requiredFields: Set<String> = [
        "type",
        "block_id",
        "title",
    ]

    /// Derive the canonical internal-reference url for a feishu-native
    /// placeholder from its `type` + `block_token`. Returns `nil` when the
    /// url is NOT derivable and must therefore be persisted explicitly:
    ///   - `embed` (and any unknown type) — url is a real external link
    ///     captured from the Feishu iframe block, not a `feishu://` ref
    ///   - missing / empty `block_token` — nothing to build the ref from
    ///
    /// The type→segment map mirrors `FeishuBlockEncoder` (attachment blocks
    /// serialize as `feishu://file/<token>` — segment "file" ≠ type
    /// "attachment"; every other native type uses its own name).
    public static func canonicalURL(type: String, blockToken: String?) -> String? {
        guard let token = blockToken, !token.isEmpty else { return nil }
        let segment: String
        switch type {
        case "board", "sheet", "bitable", "mindnote", "video":
            segment = type
        case "attachment":
            segment = "file"
        default:
            return nil
        }
        return "feishu://\(segment)/\(token)"
    }

    // MARK: - Parse

    /// Parse the literal source of an HTML block. Returns `nil` when:
    ///   - the first non-empty line isn't `<!-- feishu-placeholder`
    ///     (it's some other HTML comment, not ours)
    ///   - the closer `-->` isn't on its own line
    ///   - any body line isn't `key: value` shaped
    ///   - a required field is missing or empty
    ///
    /// On nil the caller is expected to fall back to a raw markdown block
    /// — the bytes survive even when our parser can't make sense of them.
    public static func parse(_ rawHTML: String) -> FeishuPlaceholder? {
        let lines = rawHTML
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        // Trim empty leading / trailing lines (lenient — parser is the
        // forgiving end of the contract).
        var start = 0
        while start < lines.count, lines[start].isEmpty { start += 1 }
        var end = lines.count
        while end > start, lines[end - 1].isEmpty { end -= 1 }
        guard end - start >= 2 else { return nil }
        guard lines[start] == openerLine else { return nil }
        guard lines[end - 1] == closerLine else { return nil }

        var fields: [String: String] = [:]
        var unknown: [UnknownPlaceholderField] = []

        for i in (start + 1)..<(end - 1) {
            let line = lines[i]
            if line.isEmpty { continue }
            guard let colonRange = line.range(of: ":") else { return nil }
            let key = String(line[..<colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if key.isEmpty { return nil }
            if knownFields.contains(key) {
                fields[key] = value
            } else {
                unknown.append(UnknownPlaceholderField(key: key, value: value))
            }
        }

        for required in requiredFields {
            guard let value = fields[required], !value.isEmpty else { return nil }
            _ = value
        }

        let type = fields["type"] ?? ""
        let blockToken = fields["block_token"]
        // Backfill an omitted url from the canonical form (#89) so in-memory
        // `url` always has a value — ASTConverter → attrs["url"] → the web
        // NodeView's "在飞书中编辑 ↗" button keep working with no changes.
        let url = fields["url"] ?? (canonicalURL(type: type, blockToken: blockToken) ?? "")

        return FeishuPlaceholder(
            type: type,
            blockId: fields["block_id"] ?? "",
            blockToken: blockToken,
            title: fields["title"] ?? "",
            summary: fields["summary"],
            url: url,
            createdInFeishuAt: fields["created_in_feishu_at"],
            unknownFields: unknown
        )
    }

    // MARK: - Serialize

    /// Emit a placeholder back to its magic-comment text form. Field order
    /// is fixed (ADR-0007 § 字段 schema): known fields in the canonical
    /// order, then unknown fields in their original order.
    ///
    /// Values must not contain newlines or `--` (the latter would corrupt
    /// the surrounding HTML comment). v2-1 enforces both with
    /// `precondition` — caller is expected to sanitize on the way in.
    /// v2-2 adds a sanitize fallback per ADR-0007 § 已知限制 #6.
    public static func serialize(_ placeholder: FeishuPlaceholder) -> String {
        var lines: [String] = [openerLine]

        appendField(&lines, key: "type", value: placeholder.type)
        appendField(&lines, key: "block_id", value: placeholder.blockId)
        if let token = placeholder.blockToken {
            appendField(&lines, key: "block_token", value: token)
        }
        appendField(&lines, key: "title", value: placeholder.title)
        if let summary = placeholder.summary {
            appendField(&lines, key: "summary", value: summary)
        }
        // #89: omit the url line when it equals the canonical form derivable
        // from type + block_token (feishu-native blocks). embed external
        // links, non-canonical urls, and token-less blocks fall through and
        // are written explicitly — never dropped.
        if placeholder.url != canonicalURL(type: placeholder.type, blockToken: placeholder.blockToken) {
            appendField(&lines, key: "url", value: placeholder.url)
        }
        if let created = placeholder.createdInFeishuAt {
            appendField(&lines, key: "created_in_feishu_at", value: created)
        }
        for field in placeholder.unknownFields {
            appendField(&lines, key: field.key, value: field.value)
        }

        lines.append(closerLine)
        return lines.joined(separator: "\n")
    }

    private static func appendField(_ lines: inout [String], key: String, value: String) {
        precondition(
            !key.contains("\n") && !key.contains(":"),
            "FeishuPlaceholder field key '\(key)' must be single-line and contain no colon"
        )
        precondition(
            !value.contains("\n"),
            "FeishuPlaceholder field '\(key)' value contains a newline; values must be single-line"
        )
        precondition(
            !value.contains("--"),
            "FeishuPlaceholder field '\(key)' value contains '--' which would corrupt the HTML comment; sanitize before serializing"
        )
        lines.append("\(key): \(value)")
    }
}
