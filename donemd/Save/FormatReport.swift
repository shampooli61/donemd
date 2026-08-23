import Foundation

/// Human-readable summary of what Done.md's canonical-form pass will
/// change about a file. Computed by scanning the original Markdown for
/// known non-canonical patterns. Used by the first-save prompt's
/// "看看改了哪些" sheet as the trust-building "promise visualized"
/// header.
///
/// Scanning is heuristic (we don't re-parse — that would just give us
/// canonical output again with no record of what was different). The
/// counts catch the common cases the user notices in PRs.
public struct FormatReport: Equatable {
    public var setextHeadings: Int           // === / --- under text → # / ##
    public var bulletNormalization: Int      // * or + bullet items → -
    public var emphasisNormalization: Int    // _x_ → *x*, __x__ → **x**
    public var blankLinesCollapsed: Int      // runs of ≥2 blank lines → 1
    public var trailingWhitespaceLines: Int  // lines ending with whitespace
    public var trailingNewlineFix: Bool      // file didn't end with \n

    public var hasAnyChange: Bool {
        setextHeadings > 0
            || bulletNormalization > 0
            || emphasisNormalization > 0
            || blankLinesCollapsed > 0
            || trailingWhitespaceLines > 0
            || trailingNewlineFix
    }

    /// User-facing bullet list: ["标题格式统一（3 处）", ...] in Chinese.
    public var summaryItems: [String] {
        var items: [String] = []
        if setextHeadings > 0 {
            items.append("标题格式统一（\(setextHeadings) 处）")
        }
        if bulletNormalization > 0 {
            items.append("列表符号标准化（\(bulletNormalization) 处）")
        }
        if emphasisNormalization > 0 {
            items.append("强调写法统一（\(emphasisNormalization) 处）")
        }
        if blankLinesCollapsed > 0 {
            items.append("空行清理（\(blankLinesCollapsed) 处）")
        }
        if trailingWhitespaceLines > 0 {
            items.append("行尾空白清理（\(trailingWhitespaceLines) 行）")
        }
        if trailingNewlineFix {
            items.append("文件末尾补齐换行")
        }
        return items
    }
}

public enum FormatReportComputer {
    /// Compute a `FormatReport` by scanning the original Markdown for
    /// non-canonical patterns Done.md normalizes on save.
    public static func compute(originalMarkdown: String) -> FormatReport {
        let lines = originalMarkdown.components(separatedBy: "\n")
        var report = FormatReport(
            setextHeadings: 0,
            bulletNormalization: 0,
            emphasisNormalization: 0,
            blankLinesCollapsed: 0,
            trailingWhitespaceLines: 0,
            trailingNewlineFix: false
        )

        // 1. Setext headings — a line of === or --- (≥3 chars) preceded by
        //    a non-empty text line that isn't itself a heading.
        for i in 1..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { continue }
            let isAllEq = trimmed.allSatisfy { $0 == "=" }
            let isAllDash = trimmed.allSatisfy { $0 == "-" }
            guard isAllEq || isAllDash else { continue }
            let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
            if !prev.isEmpty && !prev.hasPrefix("#") {
                report.setextHeadings += 1
            }
        }

        // 2. `*` / `+` bullets at the start of a list item line.
        //    Allow leading whitespace for nested lists.
        let bulletPattern = #"^\s*[*+]\s+"#
        if let regex = try? NSRegularExpression(pattern: bulletPattern) {
            for line in lines {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    report.bulletNormalization += 1
                }
            }
        }

        // 3. Underscore emphasis (`_x_` / `__x__`). These are
        //    word-boundary anchored to avoid matching inside identifiers.
        //    Bold first (longer match wins), then italic minus the
        //    already-matched bold ranges.
        let boldUnderscore = #"(?<![\w_])__([^_]|_(?!_))+__(?![\w_])"#
        let italicUnderscore = #"(?<![\w_])_([^_]+)_(?![\w_])"#
        let combined = "\(boldUnderscore)|\(italicUnderscore)"
        if let regex = try? NSRegularExpression(pattern: combined) {
            let nsRange = NSRange(originalMarkdown.startIndex..<originalMarkdown.endIndex, in: originalMarkdown)
            report.emphasisNormalization = regex.numberOfMatches(in: originalMarkdown, range: nsRange)
        }

        // 4. Runs of 2+ consecutive blank lines.
        var blankRun = 0
        var totalExcessRuns = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
            } else {
                if blankRun >= 2 { totalExcessRuns += 1 }
                blankRun = 0
            }
        }
        if blankRun >= 2 { totalExcessRuns += 1 }
        report.blankLinesCollapsed = totalExcessRuns

        // 5. Lines with trailing whitespace (excluding fully-blank lines).
        for line in lines {
            guard !line.isEmpty else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if line.last == " " || line.last == "\t" {
                report.trailingWhitespaceLines += 1
            }
        }

        // 6. Trailing newline at EOF.
        report.trailingNewlineFix = !originalMarkdown.isEmpty && !originalMarkdown.hasSuffix("\n")

        return report
    }
}
