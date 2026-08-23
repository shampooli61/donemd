import Foundation

/// Side-by-side line-level diff between two Markdown texts. Each line is
/// tagged with whether it survived, was removed (left-only), or added
/// (right-only). Uses Foundation's `CollectionDifference` so we don't
/// have to ship a Myers implementation.
public struct LineDiff: Equatable {
    public enum Status: Equatable {
        case unchanged
        case removed   // line existed in `before` but not in `after`
        case added     // line exists in `after` but not in `before`
    }

    public struct AnnotatedLine: Equatable {
        public let text: String
        public let status: Status
    }

    public let beforeLines: [AnnotatedLine]
    public let afterLines: [AnnotatedLine]

    public var hasAnyChange: Bool {
        beforeLines.contains(where: { $0.status != .unchanged })
            || afterLines.contains(where: { $0.status != .unchanged })
    }
}

public enum LineDiffComputer {
    public static func compute(before: String, after: String) -> LineDiff {
        let beforeLines = before.components(separatedBy: "\n")
        let afterLines = after.components(separatedBy: "\n")

        let diff = afterLines.difference(from: beforeLines)

        var removedIndices = Set<Int>()
        var addedIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedIndices.insert(offset)
            case .insert(let offset, _, _):
                addedIndices.insert(offset)
            }
        }

        let annotatedBefore = beforeLines.enumerated().map { idx, line in
            LineDiff.AnnotatedLine(
                text: line,
                status: removedIndices.contains(idx) ? .removed : .unchanged
            )
        }
        let annotatedAfter = afterLines.enumerated().map { idx, line in
            LineDiff.AnnotatedLine(
                text: line,
                status: addedIndices.contains(idx) ? .added : .unchanged
            )
        }
        return LineDiff(beforeLines: annotatedBefore, afterLines: annotatedAfter)
    }
}
