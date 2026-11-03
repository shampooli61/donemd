import Foundation
import Combine

/// Display-only projection of accepted document transactions. Never flushes or saves the editor.
@MainActor
final class MobileSourceMirror: ObservableObject {
    @Published private(set) var source = ""
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var identity = ""
    @Published private(set) var revision = -1
    @Published private(set) var stale = false
    private(set) var sequence = 0
    private(set) var folded: [Int] = []
    private(set) var badMath: [String] = []
    var send: ((String, [String: Any]) -> Void)?
    var retry: (() -> Void)?
    var toggleFold: ((Int, Bool) -> Void)?
    private var hasRendered = false
    nonisolated init() {}

    func accept(source: String, identity: String, revision: Int) {
        guard identity != self.identity || revision >= self.revision else { return }
        let changedDocument = identity != self.identity || revision != self.revision
        guard changedDocument || source != self.source else { return }
        if changedDocument {
            ready = false
            hasRendered = false
            folded = []
            badMath = []
            stale = false
            error = nil
        }
        self.identity = identity
        self.revision = revision
        self.source = source
        sequence += 1
        push()
    }
    func push() {
        sequence += 1
        send?("setMarkdownSource", ["text": source, "identity": identity, "revision": revision, "sequence": sequence])
    }
    @discardableResult
    func acknowledge(identity: String, revision: Int, sequence: Int) -> Bool {
        guard matches(identity: identity, revision: revision, sequence: sequence) else { return false }
        ready = true
        hasRendered = true
        stale = false
        error = nil
        setFolded(folded)
        setBadMath(badMath)
        return true
    }
    func matches(identity: String, revision: Int, sequence: Int) -> Bool {
        self.identity == identity && self.revision == revision && self.sequence == sequence
    }
    func failed(_ message: String = "Markdown 源暂时无法更新") {
        error = message
        stale = hasRendered
        if !hasRendered { ready = false }
    }
    func disconnected() { ready = false; send = nil }
    func requestRefresh() { error = nil; retry?() }
    func jump(to index: Int) {
        guard index >= 0 else { return }
        send?("scrollToHeading", ["index": index, "smooth": false])
    }
    func setFolded(_ ordinals: [Int]) {
        folded = ordinals.filter { $0 >= 0 }.sorted()
        send?("applyFold", ["collapsed": folded])
    }
    func setBadMath(_ formulas: [String]) {
        badMath = formulas
        send?("badMathFormulas", ["latex": formulas])
    }
    func receiveFold(ordinal: Int, collapse: Bool, identity: String, revision: Int, sequence: Int) {
        guard ready, ordinal >= 0, matches(identity: identity, revision: revision, sequence: sequence) else { return }
        toggleFold?(ordinal, collapse)
    }
}
