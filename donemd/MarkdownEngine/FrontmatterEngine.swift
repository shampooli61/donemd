import Foundation
import Yams

/// Splits a `.md` source into (Frontmatter, body) and rebuilds it
/// losslessly. Sits in front of swift-markdown so the parser never
/// sees the leading `---\n…\n---` block (which it would otherwise
/// flatten into thematic-break + paragraph + thematic-break).
///
/// Promises (per ADR-0005 + ADR-0002 § Frontmatter):
///
/// - `parse → serialize` is a fixed point. Original fence and user-field
///   text round-trip byte-for-byte; only the `feishu:` subtree is
///   regenerated from typed state.
/// - Bad YAML doesn't crash — falls back to "no frontmatter, whole
///   source is body".
/// - `+++` (TOML fence) is rejected: file is treated as plain body.
/// - Scan is bounded (1 MB) so a pathological un-closed fence can't
///   stall the editor.
public enum FrontmatterEngine {
    /// Cap on the body region scanned for a closing `---`. 1 MB is far
    /// past any plausible legitimate frontmatter; documents past this
    /// point are treated as having no frontmatter (open fence = malformed).
    public static let maxFenceScanBytes = 1_048_576

    public struct ParseResult: Equatable {
        public let frontmatter: Frontmatter
        public let body: String

        public init(frontmatter: Frontmatter, body: String) {
            self.frontmatter = frontmatter
            self.body = body
        }
    }

    // MARK: parse

    /// Detect a leading YAML frontmatter block, decode it, and return
    /// the residual body. On any failure (no fence / malformed YAML /
    /// missing closing fence), returns `(.empty, source)` so callers can
    /// hand the raw source to the markdown parser unchanged.
    public static func parse(_ source: String) -> ParseResult {
        guard let bounds = findFenceBounds(source) else {
            return ParseResult(frontmatter: .empty, body: source)
        }
        let yamlBody = String(source[bounds.bodyStart..<bounds.closingStart])
        let bodyText = sliceBody(source, after: bounds.closingStart)

        do {
            let frontmatter = try parseYAMLBody(yamlBody)
            return ParseResult(frontmatter: frontmatter, body: bodyText)
        } catch {
            // Malformed YAML degrades to "no frontmatter" — the user's
            // original `---` lines stay in the body and end up as a
            // thematic break + paragraph (Phase 1 behavior preserved).
            return ParseResult(frontmatter: .empty, body: source)
        }
    }

    // MARK: serialize

    /// Re-emit `(frontmatter, body)` as a single `.md` source. The
    /// frontmatter section is byte-identical to its parsed input on
    /// round-trip, modulo the `feishu:` subtree which is regenerated
    /// from typed state in canonical key order.
    public static func serialize(_ frontmatter: Frontmatter, body: String) -> String {
        let yamlBody = emitYAMLBody(frontmatter)
        if yamlBody == nil {
            return body
        }
        // Frontmatter is present (or fence was explicitly preserved).
        // Wrap with the canonical `---\n…\n---\n` fence and prepend.
        var out = "---\n"
        out += yamlBody ?? ""
        out += "---\n"
        out += body
        return out
    }

    // MARK: merge

    /// Combine an existing frontmatter (parsed from the file on disk)
    /// with an incoming patch (typically: only the `feishu:` subtree
    /// just produced by a sync coordinator). User fields are preserved
    /// verbatim; the `feishu:` namespace is replaced wholesale.
    ///
    /// If the existing frontmatter has no `feishu:` key, the patch's
    /// `feishu:` is appended after the last user field — its block
    /// always ends up at the bottom of the YAML body, never injected
    /// in the middle of the user's keys.
    public static func merge(existing: Frontmatter, incoming: Frontmatter) -> Frontmatter {
        var result = existing
        if let newFeishu = incoming.feishu {
            result.feishu = newFeishu
            if result.feishuOriginalIndex == nil {
                result.feishuOriginalIndex = result.userFields.count
            }
            result.hasFence = true
        }
        return result
    }

    // MARK: - private: parse helpers

    private struct FenceBounds {
        let bodyStart: String.Index    // index just past the opening "---\n"
        let closingStart: String.Index // index of the closing "---" line start
    }

    /// Locate the opening `---\n` and matching closing `---` line.
    /// `+++` and other variants are rejected at this layer.
    private static func findFenceBounds(_ source: String) -> FenceBounds? {
        guard source.hasPrefix("---\n") else { return nil }
        let bodyStart = source.index(source.startIndex, offsetBy: 4)
        let scanEnd = source.index(bodyStart, offsetBy: maxFenceScanBytes, limitedBy: source.endIndex)
            ?? source.endIndex

        var idx = bodyStart
        while idx < scanEnd {
            let lineEnd = source[idx..<scanEnd].firstIndex(of: "\n") ?? scanEnd
            let line = source[idx..<lineEnd]
            if line == "---" {
                return FenceBounds(bodyStart: bodyStart, closingStart: idx)
            }
            if lineEnd >= scanEnd { break }
            idx = source.index(after: lineEnd)
        }
        return nil
    }

    /// Body text starts on the line *after* the closing fence — or is
    /// empty if the closing fence sits at EOF.
    private static func sliceBody(_ source: String, after closingStart: String.Index) -> String {
        let afterClose = source[closingStart...]
        guard let nl = afterClose.firstIndex(of: "\n") else {
            return ""
        }
        return String(source[source.index(after: nl)...])
    }

    /// Decode the YAML between the two `---` fences. Caller treats any
    /// thrown error as "fall back to no frontmatter".
    private static func parseYAMLBody(_ yamlBody: String) throws -> Frontmatter {
        // Empty / whitespace-only body: fence was present but carried
        // no fields. We keep `hasFence = true` so serialize re-emits
        // the empty fence and the user sees their original markup.
        if yamlBody.isEmpty || yamlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Frontmatter(userFields: [], feishu: nil, feishuOriginalIndex: nil, hasFence: true)
        }

        let composed: Node?
        do {
            composed = try Yams.compose(yaml: yamlBody)
        } catch {
            throw FrontmatterParseError.invalidYAML(error)
        }
        guard let node = composed else {
            // Yams returned nil: empty document. Treat as fence-with-no-fields.
            return Frontmatter(userFields: [], feishu: nil, feishuOriginalIndex: nil, hasFence: true)
        }
        guard case .mapping(let topMapping) = node else {
            // Top-level non-mapping (e.g. just a scalar or a sequence).
            // Reject — Done.md frontmatter is always a key/value mapping.
            throw FrontmatterParseError.notMapping
        }

        let keyPositions = topLevelKeyPositions(in: yamlBody)
        let lines = yamlBody.components(separatedBy: "\n")

        var userFields: [UserField] = []
        var feishuIndex: Int? = nil
        var feishu: FeishuFrontmatter? = nil

        for (i, pos) in keyPositions.enumerated() {
            let startLine = (i == 0) ? 0 : pos.lineIndex
            let endLine = (i + 1 < keyPositions.count) ? keyPositions[i + 1].lineIndex : lines.count
            var rawBlock = lines[startLine..<endLine].joined(separator: "\n")
            // `joined` reconstructs the inner separators exactly. If the
            // block isn't the last in the file we need to put back the
            // separator that bordered the next block.
            if endLine < lines.count {
                rawBlock += "\n"
            }

            if pos.key == "feishu" {
                feishuIndex = i
                if let feishuValue = lookup(topMapping, key: "feishu"),
                   case .mapping(let feishuMapping) = feishuValue {
                    feishu = parseFeishuMapping(feishuMapping)
                } else {
                    // Present but not a mapping (e.g. `feishu: ~`).
                    // Treat as empty subtree — round-trip will normalize.
                    feishu = FeishuFrontmatter()
                }
            } else {
                userFields.append(UserField(key: pos.key, rawBlock: rawBlock))
            }
        }

        return Frontmatter(
            userFields: userFields,
            feishu: feishu,
            feishuOriginalIndex: feishuIndex,
            hasFence: true
        )
    }

    /// Find every top-level key in the YAML body, in source order, by
    /// scanning for `^<ident>:` lines. Quoted keys, dotted paths, and
    /// other YAML exotica fall outside the v2-1 schema and aren't
    /// recognized here — Yams will still parse them, but their raw
    /// blocks won't be captured (the field would silently lose its
    /// original text on round-trip). Phase 2 v2 schema only uses simple
    /// identifiers (`title`, `tags`, `authors`, `feishu`), so this is
    /// good enough; revisit when broader frontmatter is needed.
    private static func topLevelKeyPositions(in yamlBody: String) -> [(key: String, lineIndex: Int)] {
        let lines = yamlBody.components(separatedBy: "\n")
        var positions: [(key: String, lineIndex: Int)] = []
        for (i, line) in lines.enumerated() {
            guard let key = matchTopLevelKey(line) else { continue }
            positions.append((key: key, lineIndex: i))
        }
        return positions
    }

    private static func matchTopLevelKey(_ line: String) -> String? {
        // Top-level (column 0) `<ident>:` … where <ident> is a simple
        // YAML identifier. Fail fast on any indented line — that's
        // either nested data or part of a previous block scalar.
        guard let first = line.unicodeScalars.first else { return nil }
        guard isIdentifierStart(first) else { return nil }
        var idx = line.unicodeScalars.startIndex
        let end = line.unicodeScalars.endIndex
        while idx < end, isIdentifierPart(line.unicodeScalars[idx]) {
            idx = line.unicodeScalars.index(after: idx)
        }
        guard idx < end, line.unicodeScalars[idx] == ":" else { return nil }
        // After the colon: must be whitespace or end of line (YAML
        // requires this for a block-mapping key). `key:value` (no
        // space) is technically valid YAML for a string value with a
        // trailing colon in some flavors but we don't accept it here.
        let afterColon = line.unicodeScalars.index(after: idx)
        if afterColon == end {
            return String(line.unicodeScalars[line.unicodeScalars.startIndex..<idx])
        }
        let next = line.unicodeScalars[afterColon]
        if next == " " || next == "\t" {
            return String(line.unicodeScalars[line.unicodeScalars.startIndex..<idx])
        }
        return nil
    }

    private static func isIdentifierStart(_ s: Unicode.Scalar) -> Bool {
        return (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || s == "_"
    }

    private static func isIdentifierPart(_ s: Unicode.Scalar) -> Bool {
        return isIdentifierStart(s) || (s >= "0" && s <= "9") || s == "-"
    }

    private static func lookup(_ mapping: Node.Mapping, key: String) -> Node? {
        for (k, v) in mapping {
            if k.string == key { return v }
        }
        return nil
    }

    // MARK: - private: feishu parse

    private static let recognizedFeishuKeys: Set<String> = [
        "doc_token",
        "doc_url",
        "last_pulled_revision",
        "last_pushed_at",
        "placeholder_blocks",
    ]

    private static func parseFeishuMapping(_ mapping: Node.Mapping) -> FeishuFrontmatter {
        var result = FeishuFrontmatter()
        var unknownFields: [UnknownField] = []

        for (keyNode, valueNode) in mapping {
            guard let key = keyNode.string else { continue }
            switch key {
            case "doc_token":
                if let s = valueNode.string {
                    result.docToken = DocToken(s)
                }
            case "doc_url":
                if let s = valueNode.string, let url = URL(string: s) {
                    result.docURL = url
                }
            case "last_pulled_revision":
                if let n = valueNode.int {
                    result.lastPulledRevision = n
                }
            case "last_pushed_at":
                if let s = valueNode.string,
                   let date = parseISO8601(s) {
                    result.lastPushedAt = date
                }
            case "placeholder_blocks":
                if let seq = valueNode.sequence {
                    for entry in seq {
                        guard case .mapping(let entryMapping) = entry,
                              let blockId = lookup(entryMapping, key: "block_id")?.string,
                              let type = lookup(entryMapping, key: "type")?.string else {
                            continue
                        }
                        let title = lookup(entryMapping, key: "title")?.string
                        result.placeholderBlocks.append(
                            PlaceholderBlockRef(blockId: blockId, type: type, title: title)
                        )
                    }
                }
            default:
                if let yaml = encodeUnknownField(key: key, value: valueNode) {
                    unknownFields.append(UnknownField(key: key, yamlValue: yaml))
                }
            }
        }
        result.unknownFields = unknownFields
        return result
    }

    /// Turn one unrecognized `feishu:` sub-key/value pair into the YAML
    /// text we'll splice back in on serialize. Stored ready-to-emit so
    /// we don't keep a Yams Node alive on the model type.
    private static func encodeUnknownField(key: String, value: Node) -> String? {
        guard let serialized = try? Yams.serialize(node: value) else {
            return nil
        }
        let trimmed = trimTrailingNewlines(serialized)
        switch value {
        case .scalar:
            return "\(key): \(trimmed)\n"
        case .sequence, .mapping:
            // Indent the multi-line sub-block under the key. Yams emits
            // sequences and mappings starting in column 0; we shift them
            // by 2 spaces to nest under `<key>:`.
            let indented = trimmed
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? "" : "  " + $0 }
                .joined(separator: "\n")
            return "\(key):\n\(indented)\n"
        case .alias:
            // YAML aliases inside frontmatter aren't part of v2 schema —
            // emit raw and hope for the best (round-trip not guaranteed).
            return "\(key): \(trimmed)\n"
        }
    }

    // MARK: - private: serialize helpers

    /// Build the YAML text that goes between the two `---` fences. Returns
    /// `nil` when the frontmatter has no fence and no content — i.e. the
    /// file shouldn't carry a frontmatter block at all.
    private static func emitYAMLBody(_ frontmatter: Frontmatter) -> String? {
        if !frontmatter.hasFence && frontmatter.isEffectivelyEmpty {
            return nil
        }
        let userFields = frontmatter.userFields
        guard let feishu = frontmatter.feishu else {
            return userFields.map { $0.rawBlock }.joined()
        }
        // Splice the regenerated `feishu:` subtree back at its original
        // index. `feishuOriginalIndex` counts among all keys (including
        // feishu itself), so dropping feishu makes that same index land
        // between the right pair of user fields.
        let insertAt = max(0, min(frontmatter.feishuOriginalIndex ?? userFields.count, userFields.count))
        var output = ""
        for i in 0..<insertAt {
            output += userFields[i].rawBlock
        }
        output += emitFeishuSubtree(feishu)
        for i in insertAt..<userFields.count {
            output += userFields[i].rawBlock
        }
        return output
    }

    private static func emitFeishuSubtree(_ feishu: FeishuFrontmatter) -> String {
        if feishu.isEmpty {
            return "feishu: {}\n"
        }
        var s = "feishu:\n"
        if let token = feishu.docToken {
            s += "  doc_token: \(yamlEmitScalar(token.rawValue))\n"
        }
        if let url = feishu.docURL {
            s += "  doc_url: \(yamlEmitScalar(url.absoluteString))\n"
        }
        if let rev = feishu.lastPulledRevision {
            s += "  last_pulled_revision: \(rev)\n"
        }
        if let date = feishu.lastPushedAt {
            s += "  last_pushed_at: \(yamlEmitScalar(formatISO8601(date)))\n"
        }
        if !feishu.placeholderBlocks.isEmpty {
            s += "  placeholder_blocks:\n"
            for block in feishu.placeholderBlocks {
                s += "    - block_id: \(yamlEmitScalar(block.blockId))\n"
                s += "      type: \(yamlEmitScalar(block.type))\n"
                if let title = block.title {
                    s += "      title: \(yamlEmitScalar(title))\n"
                }
            }
        }
        for unknown in feishu.unknownFields {
            s += indentUnknownField(unknown.yamlValue)
        }
        return s
    }

    /// Re-indent an unknown-field block by 2 spaces so it nests under
    /// `feishu:`. The stored form is column-0; this only adjusts the
    /// indentation, leaving content otherwise verbatim.
    private static func indentUnknownField(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        // `components(separatedBy:)` of "a\n" gives ["a", ""] — drop the
        // trailing empty so we don't emit a blank line for it; we re-add
        // a single trailing newline below.
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n") + "\n"
    }

    /// Emit a single string scalar in the form Yams would: plain when
    /// safe, single-quoted otherwise. Cheap path — falls back to raw
    /// passthrough if Yams ever fails (which it doesn't for strings).
    private static func yamlEmitScalar(_ s: String) -> String {
        guard let serialized = try? Yams.serialize(node: Node(s)) else {
            return s
        }
        return trimTrailingNewlines(serialized)
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)] == "\n" {
            end = s.index(before: end)
        }
        return String(s[..<end])
    }

    // MARK: - dates

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = iso8601Formatter.date(from: s) { return d }
        // Allow fractional seconds too — incoming sync timestamps may
        // carry milliseconds depending on Feishu's emit.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withTimeZone, .withFractionalSeconds]
        return withFractional.date(from: s)
    }

    private static func formatISO8601(_ date: Date) -> String {
        return iso8601Formatter.string(from: date)
    }
}

// MARK: - Errors

enum FrontmatterParseError: Error, Equatable {
    case notMapping
    case invalidYAML(Error)

    static func == (lhs: FrontmatterParseError, rhs: FrontmatterParseError) -> Bool {
        switch (lhs, rhs) {
        case (.notMapping, .notMapping):
            return true
        case (.invalidYAML, .invalidYAML):
            return true
        default:
            return false
        }
    }
}
