import XCTest
@testable import donemd

/// v2 Slice 9a-step2 (#50) — image upload + src rewrite stage.
///
/// Scope:
///   - local `donemd-asset://` images get uploaded and rewritten to
///     `feishu://image/<token>`
///   - http(s) and already-feishu srcs are skipped untouched
///   - missing files soft-skip (don't abort the push) and surface in the
///     report's `skippedMissing` list
///   - same filename twice in one body uploads once, both nodes get the
///     same token (per-push dedup)
///   - nested images (image inside listItem.paragraph) are reached
///   - API errors propagate so the PushCoordinator can wrap them
final class FeishuImageUploadStageTests: XCTestCase {

    // MARK: - happy path

    func testUploadsLocalAssetsAndRewritesSrc() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_TOKEN_42"
        let reader = InMemoryAssetReader()
        reader.put(filename: "cat.png", data: Data([0xDE, 0xAD]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let body = doc(content: [
            paragraph(image(src: "donemd-asset://cat.png", alt: "kitty"))
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 1)
        XCTAssertEqual(api.uploadCalls.first?.fileName, "cat.png")
        XCTAssertEqual(api.uploadCalls.first?.mimeType, "image/png")
        XCTAssertEqual(api.uploadCalls.first?.data, Data([0xDE, 0xAD]))

        let imgNode = rewritten.content?[0].content?[0]
        XCTAssertEqual(imgNode?.type, "image")
        XCTAssertEqual(imgNode?.attrs?["src"], .string("feishu://image/img_TOKEN_42"))
        XCTAssertEqual(imgNode?.attrs?["alt"], .string("kitty"))

        XCTAssertEqual(report.uploadedCount, 1)
        XCTAssertEqual(report.skippedRemote, 0)
        XCTAssertEqual(report.skippedMissing, [])
    }

    // MARK: - dedup + skips

    func testSameFilenameTwiceUploadsOnce() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_DUP"
        let reader = InMemoryAssetReader()
        reader.put(filename: "x.png", data: Data([0x01]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let body = doc(content: [
            paragraph(image(src: "donemd-asset://x.png")),
            paragraph(image(src: "donemd-asset://x.png")),
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 1, "per-push dedup: same filename uploads once")
        XCTAssertEqual(report.uploadedCount, 1)
        let first = rewritten.content?[0].content?[0].attrs?["src"]
        let second = rewritten.content?[1].content?[0].attrs?["src"]
        XCTAssertEqual(first, .string("feishu://image/img_DUP"))
        XCTAssertEqual(second, .string("feishu://image/img_DUP"))
    }

    func testHTTPSrcIsSkipped() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())
        let body = doc(content: [
            paragraph(image(src: "https://example.com/cat.png"))
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 0)
        XCTAssertEqual(report.skippedRemote, 1)
        XCTAssertEqual(
            rewritten.content?[0].content?[0].attrs?["src"],
            .string("https://example.com/cat.png"),
            "http(s) src must round-trip untouched"
        )
    }

    func testFeishuSrcIsSkipped() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())
        let body = doc(content: [
            paragraph(image(src: "feishu://image/img_PRE"))
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 0)
        XCTAssertEqual(report.skippedRemote, 1)
        XCTAssertEqual(
            rewritten.content?[0].content?[0].attrs?["src"],
            .string("feishu://image/img_PRE")
        )
    }

    func testMissingAssetSoftSkips() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())
        let body = doc(content: [
            paragraph(image(src: "donemd-asset://gone.png"))
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 0,
            "missing file must not trigger an upload of empty bytes")
        XCTAssertEqual(report.skippedMissing, ["gone.png"])
        XCTAssertEqual(report.uploadedCount, 0)
        XCTAssertEqual(
            rewritten.content?[0].content?[0].attrs?["src"],
            .string("donemd-asset://gone.png"),
            "missing file: src is left as-is so the WebView still resolves locally"
        )
    }

    func testNestedImagesInListAreProcessed() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_NESTED"
        let reader = InMemoryAssetReader()
        reader.put(filename: "inside.png", data: Data([0x42]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        // bulletList → listItem → paragraph → image
        let body = doc(content: [
            TiptapNode(type: "bulletList", content: [
                TiptapNode(type: "listItem", content: [
                    paragraph(image(src: "donemd-asset://inside.png"))
                ])
            ])
        ])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 1)
        XCTAssertEqual(report.uploadedCount, 1)
        let img = rewritten.content?[0].content?[0].content?[0].content?[0]
        XCTAssertEqual(img?.type, "image")
        XCTAssertEqual(img?.attrs?["src"], .string("feishu://image/img_NESTED"))
    }

    // MARK: - report sanity

    func testReportAccountsAllPaths() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_OK"
        let reader = InMemoryAssetReader()
        reader.put(filename: "ok.png", data: Data([0xAA]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let body = doc(content: [
            paragraph(image(src: "donemd-asset://ok.png")),
            paragraph(image(src: "donemd-asset://missing.png")),
            paragraph(image(src: "https://x.com/y.png")),
            paragraph(image(src: "feishu://image/img_PRE")),
        ])

        let (_, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(report.uploadedCount, 1)
        XCTAssertEqual(report.skippedMissing, ["missing.png"])
        XCTAssertEqual(report.skippedRemote, 2,
            "https + feishu:// both count as remote-skip")
    }

    // MARK: - error propagation

    func testAPIErrorPropagates() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageError = .rateLimited
        let reader = InMemoryAssetReader()
        reader.put(filename: "a.png", data: Data([0x01]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let body = doc(content: [paragraph(image(src: "donemd-asset://a.png"))])

        do {
            _ = try await stage.process(body: body, documentId: "doxc_TEST")
            XCTFail("expected FeishuAPIError.rateLimited to bubble up")
        } catch let error as FeishuAPIError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testEmptyBodyIsNoOp() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())

        let (rewritten, report) = try await stage.process(body: doc(content: []), documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 0)
        XCTAssertEqual(report, FeishuImageUploadStage.Report())
        XCTAssertEqual(rewritten.content, [])
    }

    // MARK: - local video skip (#88)

    func testLocalVideoIsSkippedAndRecorded() async throws {
        let api = MockFeishuAPIClient()
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())
        let body = doc(content: [video(src: "donemd-asset://clip.mp4")])

        let (rewritten, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(api.uploadCalls.count, 0, "local video is never uploaded")
        XCTAssertEqual(report.skippedVideos, ["clip.mp4"])
        XCTAssertEqual(report.uploadedCount, 0)
        // Node left untouched — src not rewritten, local asset kept.
        XCTAssertEqual(
            rewritten.content?[0].attrs?["src"],
            .string("donemd-asset://clip.mp4"),
            "skipped video src must round-trip untouched"
        )
    }

    func testVideoSkipCountsAlongsideImageUpload() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_OK"
        let reader = InMemoryAssetReader()
        reader.put(filename: "pic.png", data: Data([0x01]), mimeType: "image/png")

        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let body = doc(content: [
            paragraph(image(src: "donemd-asset://pic.png")),
            video(src: "donemd-asset://a.mov"),
            video(src: "donemd-asset://b.webm"),
        ])

        let (_, report) = try await stage.process(body: body, documentId: "doxc_TEST")

        XCTAssertEqual(report.uploadedCount, 1, "the image still uploads")
        XCTAssertEqual(report.skippedVideos, ["a.mov", "b.webm"])
    }

    // MARK: - helpers

    private func doc(content: [TiptapNode]) -> TiptapNode {
        TiptapNode(type: "doc", content: content)
    }
    private func paragraph(_ child: TiptapNode) -> TiptapNode {
        TiptapNode(type: "paragraph", content: [child])
    }
    private func image(src: String, alt: String? = nil) -> TiptapNode {
        var attrs: [String: AttrValue] = ["src": .string(src)]
        if let alt { attrs["alt"] = .string(alt) }
        return TiptapNode(type: "image", attrs: attrs)
    }
    private func video(src: String) -> TiptapNode {
        TiptapNode(type: "video", attrs: ["src": .string(src)])
    }
}

// MARK: - in-memory asset reader

final class InMemoryAssetReader: FeishuImageUploadStage.AssetReader {
    private var store: [String: (data: Data, mimeType: String)] = [:]

    func put(filename: String, data: Data, mimeType: String) {
        store[filename] = (data, mimeType)
    }

    func readAsset(filename: String) -> (data: Data, mimeType: String)? {
        store[filename]
    }
}
