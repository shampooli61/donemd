import Foundation

/// In-memory `[DocToken: URL]` index over the `.md` files under a list of
/// user-declared sync root directories — the single source of truth for
/// "paste a Feishu URL → already have a local copy?" lookup. ADR-0006 is
/// the contract; this actor is the implementation.
///
/// Single responsibility, by design: the public surface is `start` /
/// `lookup` / `stop` (+ `addRoot` / `removeRoot` for runtime mutation).
/// **Deliberately no** `list / find / search / iterate` — exposing those
/// would slide the module towards "vault / file browser", which ADR-0001
/// permanently rules out. The lookup-only contract is the sole guard
/// against that drift.
///
/// Concurrency: `actor` so the index can't be observed mid-mutation while
/// watcher events fire on a background dispatch queue.
public final actor SyncRootScanner {

    /// Per-root soft cap — beyond this, scan stops gracefully and emits a
    /// warning. ADR-0006: "单根 ≤ 5000 个 .md 文件; 超出阈值时
    /// SyncRootStore.add(URL) 拒绝并提示用户拆分子目录." We currently
    /// honor this in the scanner side only; Settings UI enforcement lands
    /// with v2-10.
    public static let perRootFileLimit = 5_000

    /// Watcher debounce window — coalesces bursts of write events into one
    /// re-scan. ADR-0006: "增量去抖 200ms".
    public static let watcherDebounceNanoseconds: UInt64 = 200_000_000

    /// Token format guard. Feishu doc tokens we've seen all match this
    /// shape (`doxcn…`, `doxbe…`, `dochk…`, …). Anything else is treated
    /// as junk frontmatter and skipped — protecting the index against
    /// users typing nonsense into `feishu.doc_token`.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9_-]{5,}$"#
    )

    // MARK: index state

    /// User-declared root order. Lower index = higher priority for token
    /// conflict resolution (ADR-0006 § 冲突解决: "按 SyncRootStore.list()
    /// 顺序优先匹配").
    private var rootOrder: [URL] = []

    /// `[DocToken: URL]` — the only thing `lookup` reads.
    private var index: [DocToken: URL] = [:]

    /// Reverse index: which file produced which token, scoped per root so
    /// `removeRoot` can drop just that root's entries.
    private var rootToFiles: [URL: [URL: DocToken?]] = [:]

    /// File-level mtime cache. Watcher diffs against this to skip
    /// unchanged files on re-scan. ADR-0006 § watcher: "对比上次扫描的
    /// file path → mtime 快照". Stored as Date to keep test-time
    /// FileManager fakes simple.
    private var mtimeSnapshot: [URL: Date] = [:]

    /// Live `DispatchSource` per root. Cancelled on `stop` / `removeRoot`.
    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]

    /// Per-root debounce task. New events cancel and replace.
    private var debounceTasks: [URL: Task<Void, Never>] = [:]

    // MARK: deps

    private let fileManager: FileManager
    private let logger: @Sendable (String) -> Void
    private let now: @Sendable () -> Date

    public init(
        fileManager: FileManager = .default,
        logger: @escaping @Sendable (String) -> Void = { print("[SyncRootScanner] \($0)") },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.logger = logger
        self.now = now
    }

    // MARK: public surface

    /// Initial bring-up. Scans each root in order, then arms a watcher
    /// per root so subsequent file system events keep the index live.
    /// Always calls `stop` first so a second `start` isn't additive.
    public func start(_ roots: [URL]) async {
        await stopInternal()
        let canonical = roots.map { $0.standardizedFileURL }
        rootOrder = canonical
        for root in canonical {
            scanRootSync(root)
        }
        for root in canonical {
            startWatcher(for: root)
        }
    }

    /// O(1) lookup — the whole reason this module exists.
    public func lookup(_ token: DocToken) -> URL? {
        index[token]
    }

    /// Number of files under `root` that carry a `feishu.doc_token`
    /// (i.e. are actually bound to a Feishu document). v2-10 Settings
    /// shows this as the count badge on each sync root row — it answers
    /// "how many files in this folder are managed by Done.md's Feishu
    /// sync?", not "how many .md files exist under this folder".
    /// Returns 0 when `root` isn't tracked.
    public func boundFileCount(for root: URL) -> Int {
        let canonical = root.standardizedFileURL
        guard let files = rootToFiles[canonical] else { return 0 }
        return files.values.reduce(into: 0) { acc, token in
            if token != nil { acc += 1 }
        }
    }

    /// All files claiming `token`, returned in user-declared root priority
    /// order. The single-URL `lookup` only reveals the winner of token-conflict
    /// resolution — `lookupAll` is what `SyncBindingResolver` needs to surface
    /// the `.ambiguous` case (multiple roots holding the same doc_token,
    /// rare but per ADR-0006 the user must disambiguate).
    public func lookupAll(_ token: DocToken) -> [URL] {
        var hits: [URL] = []
        for root in rootOrder {
            guard let files = rootToFiles[root] else { continue }
            for (file, maybeToken) in files where maybeToken == token {
                hits.append(file)
            }
        }
        return hits
    }

    /// Tear everything down. Drops the index (no persistence — ADR-0006:
    /// "不持久化到磁盘——索引是冷启动后从同步根目录现扫出来的").
    public func stop() async {
        await stopInternal()
    }

    /// Add a new root at lowest priority — matches `SyncRootStore.add`'s
    /// append-to-end semantics.
    public func addRoot(_ root: URL) async {
        let canonical = root.standardizedFileURL
        guard !rootOrder.contains(canonical) else { return }
        rootOrder.append(canonical)
        scanRootSync(canonical)
        startWatcher(for: canonical)
    }

    /// Remove a root: drop all its entries from the index, cancel its
    /// watcher. Conflicting tokens that pointed to a now-removed root
    /// are not auto-rebuilt from a lower-priority root — `lookup` will
    /// miss until the next watcher tick on that lower-priority root, or
    /// until `start` is called again. Acceptable: removeRoot is a rare
    /// admin action.
    public func removeRoot(_ root: URL) async {
        let canonical = root.standardizedFileURL
        rootOrder.removeAll { $0 == canonical }
        watchers[canonical]?.cancel()
        watchers[canonical] = nil
        debounceTasks[canonical]?.cancel()
        debounceTasks[canonical] = nil
        if let files = rootToFiles[canonical] {
            for (file, maybeToken) in files {
                // Only drop if the token still maps to a file under this
                // root. A higher-priority root may have shadowed it during
                // initial scan, in which case index[token] points elsewhere
                // and we leave it alone.
                if let token = maybeToken, index[token] == file {
                    index[token] = nil
                }
            }
        }
        rootToFiles[canonical] = nil
        // Drop mtime entries for files we no longer track.
        if let urls = mtimeSnapshot.keys.filter({ $0.path.hasPrefix(canonical.path) }) as [URL]? {
            for url in urls { mtimeSnapshot[url] = nil }
        }
    }

    /// Test hook — force a synchronous re-scan of one root, bypassing
    /// the DispatchSource watcher. Production code never calls this; the
    /// watcher path is the live one. Lets unit tests exercise the diff
    /// logic without DispatchSource non-determinism.
    public func _rescanRootForTesting(_ root: URL) async {
        let canonical = root.standardizedFileURL
        rescanAndDiff(canonical)
    }

    // MARK: scan

    private func scanRootSync(_ root: URL) {
        guard let files = enumerateMarkdownFiles(under: root) else {
            logger("Cannot enumerate \(root.path)")
            return
        }
        var rootFiles: [URL: DocToken?] = [:]
        for file in files {
            let token = readDocToken(at: file)
            rootFiles[file] = token
            mtimeSnapshot[file] = modificationDate(of: file)
            if let token {
                insertOrSkip(token: token, file: file, root: root)
            }
        }
        rootToFiles[root] = rootFiles
    }

    /// Attempt to claim `token → file`. If a higher-priority root already
    /// owns it, log and leave the existing entry. If the current root is
    /// higher-priority, replace.
    private func insertOrSkip(token: DocToken, file: URL, root: URL) {
        guard let existing = index[token] else {
            index[token] = file
            return
        }
        if existing == file { return }
        let existingRoot = rootForFile(existing)
        let existingPriority = existingRoot.flatMap { rootOrder.firstIndex(of: $0) } ?? Int.max
        let newPriority = rootOrder.firstIndex(of: root) ?? Int.max
        if newPriority < existingPriority {
            logger("Token conflict: \(token.rawValue) — promoting \(file.path) over \(existing.path)")
            index[token] = file
        } else {
            logger("Token conflict: \(token.rawValue) at \(file.path) ignored, kept \(existing.path)")
        }
    }

    private func rootForFile(_ file: URL) -> URL? {
        // Linear scan over rootOrder (≤ 10 in practice per ADR's fd budget).
        for root in rootOrder where file.path.hasPrefix(root.path) {
            return root
        }
        return nil
    }

    /// FileManager.enumerator over `.md` files. Returns nil only when the
    /// root itself is unreadable; soft-caps at `perRootFileLimit`.
    private func enumerateMarkdownFiles(under root: URL) -> [URL]? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if files.count >= Self.perRootFileLimit {
                logger("Per-root file cap (\(Self.perRootFileLimit)) hit at \(root.path); truncating scan")
                break
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            // Skip iCloud placeholder files (.icloud) — ADR-0006 § 已知限制.
            if url.lastPathComponent.hasPrefix(".") { continue }
            files.append(url.standardizedFileURL)
        }
        return files
    }

    /// Read just enough of `file` to extract `feishu.doc_token`. Returns
    /// nil for: missing file, unreadable, no frontmatter, no `feishu`
    /// namespace, missing `doc_token`, malformed token format. All paths
    /// are warnings, never throws — single-file errors must not abort the
    /// scan (ADR-0006 § frontmatter 损坏).
    private func readDocToken(at file: URL) -> DocToken? {
        let source: String
        do {
            source = try String(contentsOf: file, encoding: .utf8)
        } catch {
            logger("Skip \(file.path): cannot read (\(error))")
            return nil
        }
        let parsed = FrontmatterEngine.parse(source)
        guard let token = parsed.frontmatter.feishu?.docToken else { return nil }
        let raw = token.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard Self.tokenPattern.firstMatch(in: raw, options: [], range: range) != nil else {
            logger("Skip \(file.path): doc_token \"\(raw)\" doesn't match expected format")
            return nil
        }
        return DocToken(raw)
    }

    private func modificationDate(of file: URL) -> Date? {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    // MARK: watcher

    private func startWatcher(for root: URL) {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else {
            logger("open() failed for \(root.path), watcher disabled")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleWatcherEvent(for: root) }
        }
        source.resume()
        watchers[root] = source
    }

    private func handleWatcherEvent(for root: URL) {
        debounceTasks[root]?.cancel()
        let task = Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: SyncRootScanner.watcherDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.rescanAndDiffEntry(root)
        }
        debounceTasks[root] = task
    }

    private func rescanAndDiffEntry(_ root: URL) async {
        rescanAndDiff(root)
    }

    /// Diff current state of `root` against `mtimeSnapshot` + `rootToFiles`,
    /// patch `index` and snapshots accordingly. Only re-reads frontmatter
    /// for files whose mtime changed or that are new — unchanged files
    /// short-circuit (the 5000-file budget would otherwise blow latency).
    private func rescanAndDiff(_ root: URL) {
        guard let currentFiles = enumerateMarkdownFiles(under: root) else { return }
        let previousFilesAndTokens = rootToFiles[root] ?? [:]
        let currentSet = Set(currentFiles)
        let previousSet = Set(previousFilesAndTokens.keys)

        let added = currentSet.subtracting(previousSet)
        let removed = previousSet.subtracting(currentSet)
        let possiblyModified = currentSet.intersection(previousSet)

        var rootFiles: [URL: DocToken?] = [:]

        for file in removed {
            if let token = previousFilesAndTokens[file] ?? nil {
                if let mapped = index[token], mapped == file {
                    index[token] = nil
                }
            }
            mtimeSnapshot[file] = nil
        }

        for file in possiblyModified {
            let oldMtime = mtimeSnapshot[file]
            let newMtime = modificationDate(of: file)
            if oldMtime == newMtime, let oldToken = previousFilesAndTokens[file] {
                rootFiles[file] = oldToken
                continue
            }
            let oldToken = previousFilesAndTokens[file] ?? nil
            if let oldToken, let mapped = index[oldToken], mapped == file {
                index[oldToken] = nil
            }
            let newToken = readDocToken(at: file)
            mtimeSnapshot[file] = newMtime
            rootFiles[file] = newToken
            if let newToken {
                insertOrSkip(token: newToken, file: file, root: root)
            }
        }

        for file in added {
            let token = readDocToken(at: file)
            mtimeSnapshot[file] = modificationDate(of: file)
            rootFiles[file] = token
            if let token {
                insertOrSkip(token: token, file: file, root: root)
            }
        }

        rootToFiles[root] = rootFiles
    }

    // MARK: teardown

    private func stopInternal() async {
        for (_, watcher) in watchers { watcher.cancel() }
        watchers.removeAll()
        for (_, task) in debounceTasks { task.cancel() }
        debounceTasks.removeAll()
        index.removeAll()
        rootToFiles.removeAll()
        mtimeSnapshot.removeAll()
        rootOrder.removeAll()
    }
}
