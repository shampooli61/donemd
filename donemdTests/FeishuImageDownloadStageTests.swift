import XCTest
@testable import donemd

final class FeishuImageDownloadStageTests: XCTestCase {

    // MARK: - happy paths

    /// Single feishu://image/<token> img node → download once,
    /// rewrite src to donemd-asset://<filename>, report 1 download.
    func testProcessRewritesSingleFeishuImage() async throws {
        let api = MockFeishuAPIClient()
        api.downloadImageBytes = (data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        let writer = InMemoryImageWriter()
        let stage = FeishuImageDownloadStage(api: api, writer: writer)

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/TOKEN_a")]),
        ])

        let (rewritten, report) = await stage.process(body: body)

        XCTAssertEqual(api.downloadCalls, ["TOKEN_a"])
        XCTAssertEqual(report.downloadedCount, 1)
        XCTAssertTrue(report.failedTokens.isEmpty)
        // Rewritten src points at a donemd-asset:// URL.
        let imgNode = try XCTUnwrap(rewritten.content?.first)
        guard case .string(let newSrc)? = imgNode.attrs?["src"] else {
            XCTFail("expected rewritten src"); return
        }
        XCTAssertTrue(newSrc.hasPrefix("donemd-asset://"),
            "src must rewrite to a local asset URL — got \(newSrc)")
    }

    /// Same token appearing twice deduplicates: one download, both
    /// img nodes get the same rewritten src.
    func testProcessDeduplicatesRepeatedTokenWithinSinglePull() async throws {
        let api = MockFeishuAPIClient()
        api.downloadImageBytes = (data: Data([0x01, 0x02]), mimeType: "image/jpeg")
        let writer = InMemoryImageWriter()
        let stage = FeishuImageDownloadStage(api: api, writer: writer)

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/TOKEN_dup")]),
            TiptapNode(type: "paragraph", content: [TiptapNode.text("between")]),
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/TOKEN_dup")]),
        ])

        let (rewritten, report) = await stage.process(body: body)

        XCTAssertEqual(api.downloadCalls, ["TOKEN_dup"],
            "same token across two nodes downloads once")
        XCTAssertEqual(report.downloadedCount, 1)
        let imgs = (rewritten.content ?? []).filter { $0.type == "image" }
        XCTAssertEqual(imgs.count, 2)
        let src1: String? = {
            if case .string(let s)? = imgs[0].attrs?["src"] { return s }; return nil
        }()
        let src2: String? = {
            if case .string(let s)? = imgs[1].attrs?["src"] { return s }; return nil
        }()
        XCTAssertEqual(src1, src2,
            "deduped tokens must resolve to the same asset URL")
    }

    /// Non-feishu srcs left untouched: https / donemd-asset / empty.
    func testProcessLeavesNonFeishuSrcsAlone() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageDownloadStage(api: api, writer: InMemoryImageWriter())

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("https://x.com/y.png")]),
            TiptapNode(type: "image", attrs: ["src": .string("donemd-asset://abc.png")]),
            TiptapNode(type: "image", attrs: ["src": .string("")]),
        ])

        let (rewritten, report) = await stage.process(body: body)

        XCTAssertEqual(api.downloadCalls, [],
            "no feishu:// img → no downloads")
        XCTAssertEqual(report.downloadedCount, 0)
        // Original srcs preserved.
        let srcs: [String] = (rewritten.content ?? []).compactMap { node in
            guard case .string(let s)? = node.attrs?["src"] else { return nil }
            return s
        }
        XCTAssertEqual(srcs, ["https://x.com/y.png", "donemd-asset://abc.png", ""])
    }

    // MARK: - failure paths

    /// Network failure on download → token added to failedTokens,
    /// src stays as feishu://image/<token> so user can retry by
    /// re-pulling.
    func testProcessSurfacesDownloadFailureWithoutRewriting() async throws {
        let api = MockFeishuAPIClient()
        api.downloadImageError = .networkUnreachable("offline")
        let stage = FeishuImageDownloadStage(api: api, writer: InMemoryImageWriter())

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/BAD_TOKEN")]),
        ])

        let (rewritten, report) = await stage.process(body: body)

        XCTAssertEqual(report.failedTokens, ["BAD_TOKEN"])
        XCTAssertEqual(report.downloadedCount, 0)
        // src unchanged so the next pull can retry.
        let imgNode = try XCTUnwrap(rewritten.content?.first)
        guard case .string(let src)? = imgNode.attrs?["src"] else {
            XCTFail("expected src"); return
        }
        XCTAssertEqual(src, "feishu://image/BAD_TOKEN",
            "failed downloads must keep the feishu:// src for retry")
    }

    /// Writer-side failure (disk full / permission denied) on a
    /// successful download → also surfaces as failedTokens.
    func testProcessSurfacesWriterFailure() async throws {
        let api = MockFeishuAPIClient()
        api.downloadImageBytes = (Data([0x01]), "image/png")
        let writer = InMemoryImageWriter()
        writer.shouldFail = true
        let stage = FeishuImageDownloadStage(api: api, writer: writer)

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/T")]),
        ])

        let (_, report) = await stage.process(body: body)

        XCTAssertEqual(report.failedTokens, ["T"])
        XCTAssertEqual(report.downloadedCount, 0)
    }

    /// One image fails, another succeeds — partial-progress report.
    func testProcessPartialFailure() async throws {
        // For this test we configure the api to fail only on the
        // second token — but the mock's downloadImageError is a
        // simple slot. So instead, we use a wrapping mock that
        // counts calls and fails a specific one.
        let api = ConditionalDownloadAPIMock(failOnTokens: ["BAD"])
        let stage = FeishuImageDownloadStage(api: api, writer: InMemoryImageWriter())

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/GOOD")]),
            TiptapNode(type: "image", attrs: ["src": .string("feishu://image/BAD")]),
        ])

        let (_, report) = await stage.process(body: body)

        XCTAssertEqual(report.downloadedCount, 1)
        XCTAssertEqual(report.failedTokens, ["BAD"])
    }
}

// MARK: - test helpers

final class InMemoryImageWriter: FeishuImageDownloadStage.ImageWriter {
    var written: [(data: Data, mimeType: String)] = []
    var shouldFail = false

    func writeDownloadedImage(data: Data, mimeType: String) throws -> URL {
        if shouldFail {
            throw NSError(domain: "test", code: -1, userInfo: nil)
        }
        written.append((data, mimeType))
        // Deterministic asset URL based on call order — good enough for tests.
        let filename = "test_\(written.count).png"
        return URL(string: "donemd-asset://\(filename)")!
    }
}

/// MockFeishuAPIClient wrapper that fails downloadImage only for
/// specific tokens. Forwards everything else to the underlying mock
/// so tests don't need to re-stub upload/push/etc.
final class ConditionalDownloadAPIMock: FeishuAPIClient {
    let underlying = MockFeishuAPIClient()
    let failOnTokens: Set<String>

    init(failOnTokens: [String]) {
        self.failOnTokens = Set(failOnTokens)
    }

    func pullDocument(documentId: String) async throws -> (blocks: [FeishuBlock], revisionId: Int) {
        try await underlying.pullDocument(documentId: documentId)
    }
    func pushDocument(documentId: String, blocks: [FeishuBlock]) async throws {
        try await underlying.pushDocument(documentId: documentId, blocks: blocks)
    }
    func deleteChildrenRange(documentId: String, parentBlockId: String, startIndex: Int, endIndex: Int) async throws {
        try await underlying.deleteChildrenRange(
            documentId: documentId, parentBlockId: parentBlockId,
            startIndex: startIndex, endIndex: endIndex
        )
    }
    func insertChildrenAt(documentId: String, parentBlockId: String, index: Int, blocks: [FeishuBlock]) async throws {
        try await underlying.insertChildrenAt(
            documentId: documentId, parentBlockId: parentBlockId,
            index: index, blocks: blocks
        )
    }
    func createDocument(title: String, parentToken: String?) async throws -> String {
        try await underlying.createDocument(title: title, parentToken: parentToken)
    }
    func updateDocumentTitle(documentId: String, title: String) async throws {
        try await underlying.updateDocumentTitle(documentId: documentId, title: title)
    }
    func uploadImage(
        data: Data,
        mimeType: String,
        fileName: String,
        documentId: String
    ) async throws -> String {
        try await underlying.uploadImage(
            data: data, mimeType: mimeType, fileName: fileName, documentId: documentId
        )
    }
    func downloadImage(token: String) async throws -> (data: Data, mimeType: String) {
        if failOnTokens.contains(token) {
            throw FeishuAPIError.notFound(resource: token)
        }
        return (Data([0x01]), "image/png")
    }
    func resolveWikiNode(token: String) async throws -> WikiNodeResolution {
        // Image download stage tests don't exercise wiki resolution; the
        // import command builds a fresh client per call. Stub deflects
        // to the underlying mock so any cross-wired test still works.
        try await underlying.resolveWikiNode(token: token)
    }
    func getDocumentRevision(documentId: String) async throws -> Int {
        try await underlying.getDocumentRevision(documentId: documentId)
    }
}
