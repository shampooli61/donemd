import XCTest
@testable import donemd

/// v2 Slice 9a-step1 (#50) — happy-path PushCoordinator.
///
/// Scope of this suite:
///   - new doc:   no docToken → createDocument → pushDocument → frontmatter
///                gains docToken + lastPushedAt
///   - existing:  docToken present → pushDocument only → lastPushedAt updates
///   - errors:    create-fail, push-fail-after-create (orphaned doc),
///                push-fail-with-existing-token
///   - body wire: pushed markdown is body-only (no frontmatter mixed in)
///   - parent:    parentToken forwards through to createDocument
///
/// Out of scope (deferred to step2/3/9b):
///   - image extraction + uploadImage + src rewrite
///   - placeholder preserve_existing structural push
///   - progress UI / cancellation
///   - revision conflict detection
final class FeishuPushCoordinatorTests: XCTestCase {

    // MARK: - happy paths

    func testPushNewDocumentCreatesAndPushes() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let input = parsedDocument(
            frontmatterYAML: "title: Hello\n",
            body: "# Hello\n\nworld\n"
        )
        let result = try await coordinator.push(
            input, title: "Hello", parentToken: nil
        )

        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.createCalls.first?.title, "Hello")
        XCTAssertNil(api.createCalls.first?.parentToken)
        XCTAssertEqual(api.pushCalls.count, 1)
        XCTAssertEqual(api.pushCalls.first?.documentId, "doxc_NEW")

        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.docToken,
            DocToken("doxc_NEW")
        )
        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.lastPushedAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testPushExistingDocumentSkipsCreate() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let input = parsedDocument(
            frontmatterYAML: """
            title: Hello
            feishu:
              doc_token: doxc_EXISTING
            """,
            body: "# Hello\n"
        )
        let result = try await coordinator.push(
            input, title: "Hello", parentToken: nil
        )

        XCTAssertEqual(api.createCalls.count, 0,
            "must not create when docToken already present")
        XCTAssertEqual(api.pushCalls.count, 1)
        XCTAssertEqual(api.pushCalls.first?.documentId, "doxc_EXISTING")
        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.docToken,
            DocToken("doxc_EXISTING"),
            "existing docToken must round-trip unchanged"
        )
    }

    func testPushExistingDocumentUpdatesLastPushedAt() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let input = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_EXISTING
              last_pushed_at: 2020-01-01T00:00:00Z
            """,
            body: "# Hello\n"
        )
        let result = try await coordinator.push(
            input, title: "Hello", parentToken: nil
        )

        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.lastPushedAt,
            Date(timeIntervalSince1970: 1_700_000_000),
            "lastPushedAt must advance to coordinator's now()"
        )
    }

    // MARK: - body wire shape

    func testPushedBlocksAreBodyOnlyNoFrontmatter() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date() }
        )

        // h2, not h1: leading-H1 extraction kicks in only at level 1, so
        // an h2 still rides through into the block payload — keeping this
        // test focused on "no frontmatter leakage", separate from the
        // title-extraction tests further down.
        let input = parsedDocument(
            frontmatterYAML: "title: Hello\n",
            body: "## Heading\n\nbody text\n"
        )
        _ = try await coordinator.push(
            input, title: "Hello", parentToken: nil
        )

        let blocks = try XCTUnwrap(api.pushCalls.first?.blocks)
        let allText = flattenText(blocks)
        XCTAssertFalse(allText.contains("title: Hello"),
            "block payloads must not carry frontmatter keys")
        XCTAssertFalse(allText.contains("---"),
            "block payloads must not carry frontmatter fences")
        XCTAssertTrue(allText.contains("Heading"),
            "heading text must round-trip into a block payload")
        XCTAssertTrue(allText.contains("body text"),
            "paragraph body must round-trip into a block payload")
    }

    /// Concatenate every text-run content across every block's payload —
    /// good enough for "did this string make it into the push?" assertions
    /// without locking the test to a specific block-tree shape.
    private func flattenText(_ blocks: [FeishuBlock]) -> String {
        blocks.flatMap { block -> [String] in
            switch block.payload {
            case .text(let p), .heading(_, let p),
                 .bullet(let p), .ordered(let p),
                 .quote(let p), .todo(let p, _):
                return p.elements.map { runContent($0) }
            case .code(let c):
                return c.elements.map { runContent($0) }
            case .page(let p):
                return p.title.elements.map { runContent($0) }
            case .divider, .image, .callout, .table, .tableCell, .placeholder:
                return []
            }
        }.joined(separator: "\n")
    }

    private func runContent(_ element: FeishuBlock.TextElement) -> String {
        if case .textRun(let run) = element { return run.content }
        return ""
    }

    func testParentTokenForwardsToCreate() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date() }
        )

        let input = parsedDocument(frontmatterYAML: "", body: "# H\n")
        _ = try await coordinator.push(
            input, title: "H", parentToken: "fldr_PARENT"
        )

        XCTAssertEqual(api.createCalls.first?.parentToken, "fldr_PARENT")
    }

    // MARK: - error paths

    func testCreateFailureSurfacesAsAPIFailed() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .failure(.unauthorized)
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(frontmatterYAML: "", body: "# H\n")
        do {
            _ = try await coordinator.push(input, title: "H", parentToken: nil)
            XCTFail("expected PushError.apiFailed")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .apiFailed(.unauthorized) = error else {
                XCTFail("expected apiFailed(.unauthorized), got \(error)")
                return
            }
        }
        XCTAssertEqual(api.pushCalls.count, 0,
            "must not push if create failed")
    }

    func testPushFailureAfterCreateSurfacesAsPartialSuccess() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_ORPHAN")
        api.pushDocumentError = .networkUnreachable("offline")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(frontmatterYAML: "", body: "# H\n")
        do {
            _ = try await coordinator.push(input, title: "H", parentToken: nil)
            XCTFail("expected PushError.partialSuccess")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .partialSuccess(let token, let underlying) = error else {
                XCTFail("expected partialSuccess, got \(error)")
                return
            }
            XCTAssertEqual(token, DocToken("doxc_ORPHAN"))
            guard case .networkUnreachable = underlying else {
                XCTFail("expected networkUnreachable, got \(underlying)")
                return
            }
        }
    }

    func testPushFailureWithExistingTokenSurfacesAsAPIFailed() async throws {
        let api = MockFeishuAPIClient()
        api.pushDocumentError = .rateLimited
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_EXISTING
            """,
            body: "# H\n"
        )
        do {
            _ = try await coordinator.push(input, title: "H", parentToken: nil)
            XCTFail("expected PushError.apiFailed")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .apiFailed(.rateLimited) = error else {
                XCTFail("expected apiFailed(.rateLimited), got \(error)")
                return
            }
            // partialSuccess only fires when create just succeeded — an
            // existing-doc push failure has nothing to leak.
        }
    }

    // MARK: - frontmatter shape preservation

    func testUserFieldsRoundTripUntouched() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let input = parsedDocument(
            frontmatterYAML: """
            title: Hello
            tags: [foo, bar]
            """,
            body: "# Hello\n"
        )
        let result = try await coordinator.push(
            input, title: "Hello", parentToken: nil
        )

        let userKeys = result.updatedDocument.frontmatter.userFields.map(\.key)
        XCTAssertEqual(userKeys, ["title", "tags"],
            "user fields must round-trip in order, untouched by push")
    }

    // MARK: - title binding (Notion-style: leading H1 = page title)

    func testPushExtractsLeadingH1AsTitleOverridingCallerArg() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "",
            body: "# H1 Title\n\nbody\n"
        )
        _ = try await coordinator.push(
            input, title: "FilenameFallback", parentToken: nil
        )

        XCTAssertEqual(api.createCalls.first?.title, "H1 Title",
            "leading H1 must override the caller's filename-fallback title")
    }

    func testPushFallsBackToCallerTitleWhenNoLeadingH1() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "",
            body: "no heading here\n"
        )
        _ = try await coordinator.push(
            input, title: "FilenameFallback", parentToken: nil
        )

        XCTAssertEqual(api.createCalls.first?.title, "FilenameFallback",
            "no leading H1 → caller's title carries through")
    }

    func testPushedBlocksDoNotCarryExtractedH1() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "",
            body: "# Extracted\n\nremaining body\n"
        )
        _ = try await coordinator.push(
            input, title: "ignored", parentToken: nil
        )

        let blocks = try XCTUnwrap(api.pushCalls.first?.blocks)
        let allText = flattenText(blocks)
        XCTAssertFalse(allText.contains("Extracted"),
            "extracted H1 must not also appear in pushed blocks (no duplicate)")
        XCTAssertTrue(allText.contains("remaining body"),
            "everything after the extracted H1 must round-trip")
    }

    func testPushExistingDocumentSyncsTitleWhenH1Extracted() async throws {
        // #57 step4: title sync re-enabled. A bound doc with a leading
        // H1 calls updateDocumentTitle once before pushing the body.
        // Caller-supplied `title` is ignored when the body has its own H1.
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_EXISTING
            """,
            body: "# New Title\n\nbody\n"
        )
        let result = try await coordinator.push(
            input, title: "ignored", parentToken: nil
        )

        XCTAssertEqual(api.updateTitleCalls.count, 1,
            "bound doc with H1 must trigger one title PATCH")
        XCTAssertEqual(api.updateTitleCalls.first?.documentId, "doxc_EXISTING")
        XCTAssertEqual(api.updateTitleCalls.first?.title, "New Title",
            "title comes from the body's leading H1, not the caller arg")
        XCTAssertEqual(api.createCalls.count, 0)
        XCTAssertEqual(api.pushCalls.count, 1)
        XCTAssertNil(result.titleSyncFailure,
            "no failure on success path")
    }

    func testPushExistingDocumentNoH1SkipsTitle() async throws {
        // No leading H1 → title sync skipped (don't overwrite Feishu's
        // title with the file-name fallback).
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_EXISTING
            """,
            body: "no heading\n"
        )
        _ = try await coordinator.push(
            input, title: "ignored", parentToken: nil
        )

        XCTAssertEqual(api.updateTitleCalls.count, 0,
            "no H1 → no title sync; protects user's Feishu-side title from being clobbered")
        XCTAssertEqual(api.pushCalls.count, 1)
    }

    func testPushTitleSyncFailureSurfacesAsSoftWarning() async throws {
        // Real-device PATCH page block was rejected with 1770001 in
        // v2-9a. The fix is to NOT abort the push — surface the
        // failure on PushResult.titleSyncFailure so the success
        // dialog can show "标题同步飞书时被拒"; the body push runs
        // through to completion as normal.
        let api = MockFeishuAPIClient()
        api.updateTitleError = .badRequest(
            httpStatus: 400, code: 1770001, message: "invalid param"
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_EXISTING
            """,
            body: "# New Title\n\nbody\n"
        )
        let result = try await coordinator.push(
            input, title: "ignored", parentToken: nil
        )

        XCTAssertEqual(api.updateTitleCalls.count, 1,
            "title PATCH still attempted")
        XCTAssertEqual(api.pushCalls.count, 1,
            "body push runs even when title PATCH fails — content > title")
        guard case .badRequest(_, let code, _) = result.titleSyncFailure else {
            XCTFail("expected titleSyncFailure to carry the badRequest")
            return
        }
        XCTAssertEqual(code, 1770001)
    }

    // MARK: - image stage integration (step2)

    func testPushWithImageStageEmitsImageBlockWithToken() async throws {
        let api = MockFeishuAPIClient()
        api.uploadImageResponse = "img_PUSHED"
        let reader = InMemoryAssetReader()
        reader.put(filename: "logo.png", data: Data([0x89, 0x50]), mimeType: "image/png")
        let stage = FeishuImageUploadStage(api: api, reader: reader)

        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            imageUploadStage: stage,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // Mirror the ProseMirror webview shape: image is a block-level node
        // sitting directly under doc.content. (The on-disk parser nests it
        // inside a paragraph; that path is exercised by the converter test
        // suite separately.)
        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image",
                       attrs: ["src": .string("donemd-asset://logo.png")])
        ])
        let frontmatter = MarkdownEngine.parseDocument(
            source: "---\ntitle: P\n---\n\n"
        ).frontmatter
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        let result = try await coordinator.push(
            input, title: "P", parentToken: nil
        )

        XCTAssertEqual(api.uploadCalls.count, 1)
        XCTAssertEqual(api.uploadCalls.first?.fileName, "logo.png")

        // The image node survives the TiptapNode → blocks pipeline carrying
        // the token the stage installed (no markdown round-trip flattening).
        let blocks = api.pushCalls.first?.blocks ?? []
        var foundToken: String? = nil
        for block in blocks {
            if case let .image(payload) = block.payload {
                foundToken = payload.token
                break
            }
        }
        XCTAssertEqual(foundToken, "img_PUSHED")
        XCTAssertEqual(result.imageReport?.uploadedCount, 1)
    }

    func testPushWithoutImageStagePreservesPriorBehavior() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NOSTAGE")
        // No imageUploadStage in init → coordinator must not need a reader.
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "title: P\n",
            body: "# H\n\nplain\n"
        )
        let result = try await coordinator.push(
            input, title: "P", parentToken: nil
        )

        XCTAssertEqual(api.uploadCalls.count, 0)
        XCTAssertNil(result.imageReport,
            "no stage wired → no image report attached")
    }

    // MARK: - placeholder safety gate (step3 lite)

    func testPushWithPlaceholderBlockBailsBeforeAnyAPICall() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            paragraphNode(text: "Lead-in"),
            placeholderNode(blockId: "doxbcXXX_blk001", title: "Q2 OKR", type: "sheet"),
            paragraphNode(text: "Trail-out"),
        ])
        // Index matches body — step3.1 mismatch check passes, step3.3
        // safety gate is what fires.
        let frontmatter = makeFrontmatter(placeholderIds: [
            ("doxbcXXX_blk001", "sheet")
        ])
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected containsPlaceholderBlocks error")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .containsPlaceholderBlocks(let ids) = error else {
                XCTFail("expected containsPlaceholderBlocks, got \(error)")
                return
            }
            XCTAssertEqual(ids, ["doxbcXXX_blk001"])
        }

        XCTAssertEqual(api.createCalls.count, 0,
            "safety gate must fire before createDocument — no orphaned doc")
        XCTAssertEqual(api.pushCalls.count, 0)
        XCTAssertEqual(api.uploadCalls.count, 0,
            "safety gate must fire before image upload — no wasted bytes")
    }

    func testPlaceholderScanReturnsIdsInDocumentOrderDeduped() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "between"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
            // Same id again — dedupe should drop the second occurrence.
            placeholderNode(blockId: "blk_A", title: "A again", type: "sheet"),
        ])
        // Index lists each unique id once — step3.1 passes (deduped sets
        // match), step3.3 then collects the deduped scan order.
        let frontmatter = makeFrontmatter(placeholderIds: [
            ("blk_A", "sheet"),
            ("blk_B", "board"),
        ])
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected containsPlaceholderBlocks")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .containsPlaceholderBlocks(let ids) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(ids, ["blk_A", "blk_B"])
        }
    }

    // MARK: - #57 step1 preflight (placeholder sequence agreement)

    /// Local body has a placeholder, doc is bound, Feishu side has the
    /// same id at the same position → preflight passes, then segmented
    /// push runs: deletes + inserts only the non-placeholder segments
    /// flanking the placeholder, never touches the placeholder block_id
    /// itself. The legacy `pushDocument` (delete-then-create) is NOT
    /// called on this path.
    func testPreflightPassesAndSegmentedPushRuns() async throws {
        let api = MockFeishuAPIClient()
        // Feishu side: [blk_A (placeholder), blk_X (non-PH), blk_B (placeholder)]
        // i.e. one non-placeholder block sandwiched between two placeholders.
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["blk_A", "blk_X", "blk_B"],
            placeholderIds: ["blk_A", "blk_B"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        // Local body: [blk_A, paragraph "between", blk_B]
        // Three segments: [], [paragraph], [].
        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "between"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "P", parentToken: nil)

        // Two pulls on the bound docToken: the placeholder-sequence
        // preflight, then the #84/#85 Layer-1 body-landing re-read that
        // verifies the pushed body isn't suspiciously empty on the remote.
        XCTAssertEqual(api.pullCalls, ["doxc_BOUND", "doxc_BOUND"],
            "preflight pull + post-push body-verification re-read")
        XCTAssertEqual(api.pushCalls.count, 0,
            "segmented push must NOT call legacy pushDocument (which nukes placeholders)")
        // Three segments, processed back-to-front:
        //   trailing seg [2,3) — empty local → no delete (range empty), no insert
        //   middle  seg [1,2) — local 1 paragraph → delete [1,2), insert at 1
        //   leading seg [0,0) — empty local → no delete, no insert
        // So the only segmented calls are: delete[1..2), insert(idx=1).
        XCTAssertEqual(api.segmentedCalls, [
            .delete(parentBlockId: "doxc_BOUND", startIndex: 1, endIndex: 2),
            .insert(parentBlockId: "doxc_BOUND", index: 1, blockCount: 1),
        ])
    }

    /// Two placeholders, two non-placeholder runs flanking them:
    /// [non-PH x 2, blk_A, non-PH, blk_B, non-PH x 2]. Verifies the
    /// back-to-front sequencing: the last segment's delete/insert
    /// runs first, so earlier segments' indices remain stable.
    func testSegmentedPushRunsBackToFront() async throws {
        let api = MockFeishuAPIClient()
        // Feishu side: 7 children — indices [0,1] non-PH, [2] blk_A,
        // [3] non-PH, [4] blk_B, [5,6] non-PH.
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["r0", "r1", "blk_A", "r3", "blk_B", "r5", "r6"],
            placeholderIds: ["blk_A", "blk_B"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        // Local body, same shape but rewritten content.
        let body = TiptapNode(type: "doc", content: [
            paragraphNode(text: "L0"),
            paragraphNode(text: "L1"),
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "L3"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
            paragraphNode(text: "L5"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "P", parentToken: nil)

        // Segments (in document order):
        //   leading  remote [0,2), local 2 paragraphs
        //   middle   remote [3,4), local 1 paragraph
        //   trailing remote [5,7), local 1 paragraph
        // Back-to-front order:
        //   1. delete[5,7) + insert at 5 (1 block)
        //   2. delete[3,4) + insert at 3 (1 block)
        //   3. delete[0,2) + insert at 0 (2 blocks)
        XCTAssertEqual(api.segmentedCalls, [
            .delete(parentBlockId: "doxc_BOUND", startIndex: 5, endIndex: 7),
            .insert(parentBlockId: "doxc_BOUND", index: 5, blockCount: 1),
            .delete(parentBlockId: "doxc_BOUND", startIndex: 3, endIndex: 4),
            .insert(parentBlockId: "doxc_BOUND", index: 3, blockCount: 1),
            .delete(parentBlockId: "doxc_BOUND", startIndex: 0, endIndex: 2),
            .insert(parentBlockId: "doxc_BOUND", index: 0, blockCount: 2),
        ])
        XCTAssertEqual(api.pushCalls.count, 0,
            "legacy pushDocument must not be called when segmented path runs")
    }

    /// Empty local segment between two adjacent placeholders + empty
    /// remote segment between same. Both directions empty → no API
    /// calls for that segment. Tests that we don't emit a 0-length
    /// delete or an empty insert.
    func testSegmentedPushSkipsEmptyAdjacentSegment() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["blk_A", "blk_B"],
            placeholderIds: ["blk_A", "blk_B"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "P", parentToken: nil)

        XCTAssertEqual(api.segmentedCalls, [],
            "all three segments empty on both sides → no API calls at all")
        XCTAssertEqual(api.pushCalls.count, 0)
    }

    /// Bound doc, has placeholder, segmented push fails mid-way →
    /// surfaces as PushError.segmentFailed (carrying which segment was
    /// being attempted + how many had completed before, so the UI can
    /// route to a critical-style "Feishu side may be partially broken"
    /// alert and the user knows whether to retry or restore from
    /// history). Distinct from `.apiFailed`, which is reserved for
    /// pre-segmented-loop wire failures (preflight pull / image stage
    /// / title sync) where Feishu side is untouched.
    func testSegmentedPushDeleteFailureSurfacesAsSegmentFailed() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["blk_A", "r1"],
            placeholderIds: ["blk_A"]
        )
        api.deleteRangeError = .serverError(httpStatus: 500, code: nil, message: "boom")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "trailing"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected segmentFailed")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .segmentFailed(
                let completedBefore,
                let totalSegments,
                let attemptedIndex,
                .serverError(_, _, let msg)
            ) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(msg, "boom")
            XCTAssertEqual(completedBefore, 0,
                "fail on first segment touched (back-to-front, last in doc)")
            XCTAssertEqual(attemptedIndex, 1)
            // Two non-placeholder segments around blk_A: [..., blk_A, "trailing"]
            // → segments are [empty before A] + [paragraph after A] = 2.
            XCTAssertEqual(totalSegments, 2)
        }
    }

    /// Unbound document (no docToken) + placeholder body. Preflight is
    /// skipped (no Feishu side to compare with), so the legacy
    /// stop-ship still applies — placeholders on a brand-new doc have
    /// no Feishu-side blocks to preserve. This will be replaced by the
    /// createNew path (#58).
    func testUnboundDocumentWithPlaceholderStillRefuses() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeFrontmatter(placeholderIds: [("blk_A", "sheet")]),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected containsPlaceholderBlocks (unbound + placeholder)")
        } catch FeishuPushCoordinator.PushError.containsPlaceholderBlocks {
            // expected
        }
        XCTAssertEqual(api.segmentedCalls.count, 0,
            "unbound + placeholder must not run any segmented call")
        XCTAssertEqual(api.pushCalls.count, 0)
        XCTAssertEqual(api.pullCalls.count, 0,
            "preflight is skipped for unbound docs — no pull needed")
    }

    /// Local has placeholder id Feishu doesn't → placeholderMissingOnFeishu.
    /// This is the [跳过 / 取消] path in step3 (the dialog isn't built
    /// yet but the error case must surface so the UI can route).
    func testPreflightDetectsPlaceholderMissingOnFeishu() async throws {
        let api = MockFeishuAPIClient()
        // Feishu side has only blk_A; local has blk_A + blk_GHOST.
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND",
            placeholderIds: ["blk_A"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            placeholderNode(blockId: "blk_GHOST", title: "G", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_GHOST", "sheet")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderMissingOnFeishu")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderMissingOnFeishu(let ids) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(ids, ["blk_GHOST"],
                "missing-on-Feishu list must be the local-only ids in document order")
        }
    }

    /// Feishu has placeholder id local doesn't → placeholderRemovedLocally.
    /// User must pull or restore the magic comment locally.
    func testPreflightDetectsPlaceholderRemovedLocally() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND",
            placeholderIds: ["blk_A", "blk_FEISHU_ONLY"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            // No blk_FEISHU_ONLY.
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderRemovedLocally")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderRemovedLocally(let ids) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(ids, ["blk_FEISHU_ONLY"])
        }
    }

    /// Both sides have the same placeholder ids but in different
    /// document order → placeholderOrderMismatch. Feishu has no
    /// move-block API, so the only resolution is pull-then-edit.
    func testPreflightDetectsPlaceholderOrderMismatch() async throws {
        let api = MockFeishuAPIClient()
        // Feishu side: A → B
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND",
            placeholderIds: ["blk_A", "blk_B"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        // Local body: B → A (reordered)
        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_B", "board"), ("blk_A", "sheet")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderOrderMismatch")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderOrderMismatch(let local, let remote) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(local, ["blk_B", "blk_A"])
            XCTAssertEqual(remote, ["blk_A", "blk_B"])
        }
    }

    /// Unbound document (no docToken in frontmatter) — preflight is
    /// skipped, the existing step3-lite stop-ship still catches the
    /// placeholder. No pullDocument call should be made.
    func testPreflightSkippedForUnboundDocumentWithPlaceholder() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeFrontmatter(placeholderIds: [("blk_A", "sheet")]),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected containsPlaceholderBlocks (unbound + placeholder)")
        } catch FeishuPushCoordinator.PushError.containsPlaceholderBlocks {
            // expected
        }
        XCTAssertEqual(api.pullCalls.count, 0,
            "preflight must not pull for an unbound document")
    }

    /// Bound document with NO placeholder in body — the placeholder
    /// preflight is skipped and the existing pushDocument runs unchanged.
    /// The one pull that does happen is the #84/#85 Layer-1 body-landing
    /// re-read after the push (there is real body content to verify), not
    /// a placeholder-agreement preflight.
    func testPreflightSkippedForBoundDocumentWithoutPlaceholder() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            paragraphNode(text: "no placeholders here"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: []
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "P", parentToken: nil)

        XCTAssertEqual(api.pullCalls.count, 1,
            "no placeholder preflight pull; the single pull is the post-push body-verification re-read")
        XCTAssertEqual(api.pushCalls.count, 1,
            "push runs as before for placeholder-free docs")
    }

    /// Preflight pull failure (network down / 401 / etc.) must surface
    /// as PushError.apiFailed, not silently bypass. Reuses MockFeishuAPIClient's
    /// pullDocumentError slot.
    func testPreflightPullFailureSurfacesAsAPIFailed() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentError = .networkUnreachable("offline")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected apiFailed")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .apiFailed(.networkUnreachable(let detail)) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(detail, "offline")
        }
    }

    // MARK: - #57 step3 placeholder skip helper

    func testRemovePlaceholderBlocksDropsBodyNodesAndIndexEntries() {
        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_KEEP", title: "K", type: "sheet"),
            paragraphNode(text: "between"),
            placeholderNode(blockId: "blk_DROP", title: "D", type: "board"),
            paragraphNode(text: "trailing"),
        ])
        let frontmatter = makeBoundFrontmatter(
            docToken: "doxc_BOUND",
            placeholderIds: [("blk_KEEP", "sheet"), ("blk_DROP", "board")]
        )
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        let stripped = FeishuPushCoordinator.removePlaceholderBlocks(
            from: input, blockIdsToRemove: ["blk_DROP"]
        )

        // Body: blk_DROP gone, the rest in order.
        let topLevelTypes = (stripped.body.content ?? []).map(\.type)
        XCTAssertEqual(topLevelTypes,
            ["feishu_placeholder_block", "paragraph", "paragraph"],
            "blk_DROP must be removed from the body, blk_KEEP and surrounding text preserved")
        // Frontmatter index: only blk_KEEP left.
        let remainingIds = stripped.frontmatter.feishu?
            .placeholderBlocks.map(\.blockId) ?? []
        XCTAssertEqual(remainingIds, ["blk_KEEP"])
        // Original input untouched.
        XCTAssertEqual(input.body.content?.count, 4,
            "input must not be mutated — strip is a pure function")
    }

    func testRemovePlaceholderBlocksHandlesAllIdsRemoved() {
        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
        ])
        let frontmatter = makeBoundFrontmatter(
            docToken: "doxc_BOUND",
            placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
        )
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        let stripped = FeishuPushCoordinator.removePlaceholderBlocks(
            from: input, blockIdsToRemove: ["blk_A", "blk_B"]
        )

        XCTAssertEqual(stripped.body.content ?? [], [],
            "removing all placeholder ids must leave an empty body")
        XCTAssertEqual(stripped.frontmatter.feishu?.placeholderBlocks ?? [], [],
            "frontmatter index empty when all placeholders removed")
    }

    func testRemovePlaceholderBlocksIgnoresUnmatchedIds() {
        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "x"),
        ])
        let frontmatter = makeBoundFrontmatter(
            docToken: "doxc_BOUND",
            placeholderIds: [("blk_A", "sheet")]
        )
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        let stripped = FeishuPushCoordinator.removePlaceholderBlocks(
            from: input, blockIdsToRemove: ["blk_NEVER_EXISTED"]
        )

        // Nothing changes — the id wasn't in the body or index.
        XCTAssertEqual(stripped.body.content?.count, 2)
        XCTAssertEqual(
            stripped.frontmatter.feishu?.placeholderBlocks.map(\.blockId),
            ["blk_A"]
        )
    }

    /// Skip path end-to-end via coordinator: first push throws
    /// placeholderMissingOnFeishu; caller strips locally; second push
    /// (against a Feishu side that no longer reports the missing id)
    /// succeeds via segmented push.
    func testSkipPathRetryViaSegmentedPushSucceeds() async throws {
        let api = MockFeishuAPIClient()
        // First pull: Feishu has only blk_A; local has blk_A + blk_GHOST.
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["blk_A", "r1"],
            placeholderIds: ["blk_A"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "after-A"),
            placeholderNode(blockId: "blk_GHOST", title: "G", type: "sheet"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_GHOST", "sheet")]
            ),
            body: body
        )

        // Attempt 1 — preflight fails on blk_GHOST.
        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderMissingOnFeishu")
        } catch FeishuPushCoordinator.PushError.placeholderMissingOnFeishu(let ids) {
            XCTAssertEqual(ids, ["blk_GHOST"])
        }

        // Caller strips blk_GHOST locally...
        let stripped = FeishuPushCoordinator.removePlaceholderBlocks(
            from: input, blockIdsToRemove: ["blk_GHOST"]
        )
        // ...and re-runs push. This time preflight passes (no
        // GHOST locally), segmented push runs.
        _ = try await coordinator.push(stripped, title: "P", parentToken: nil)

        // Verify retry actually used segmented push (not legacy
        // pushDocument) — that's the whole point of the skip path
        // for bound docs with remaining placeholders.
        XCTAssertEqual(api.pushCalls.count, 0,
            "retry must use segmented push for bound docs with placeholders")
        XCTAssertGreaterThan(api.segmentedCalls.count, 0,
            "retry must emit segmented push calls")
    }

    // MARK: - #57 step5 cancel signal

    /// Cancel signal flipped before push() runs → coordinator throws
    /// .cancelled with completed=0/total=0 and never makes any API
    /// call. Verifies the early-exit fast path.
    func testCancelBeforeStartShortCircuits() async throws {
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let signal = FeishuSyncCancellationSignal()
        signal.cancel()

        let input = parsedDocument(
            frontmatterYAML: "title: P\n",
            body: "# H\n\nplain\n"
        )
        do {
            _ = try await coordinator.push(
                input, title: "P", parentToken: nil, signal: signal
            )
            XCTFail("expected cancelled")
        } catch FeishuPushCoordinator.PushError.cancelled(let completed, let total) {
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(total, 0)
        }
        XCTAssertEqual(api.createCalls.count, 0,
            "early-cancelled push must not call createDocument")
        XCTAssertEqual(api.pushCalls.count, 0)
        XCTAssertEqual(api.segmentedCalls.count, 0)
    }

    /// Segmented push with multi-segment doc + cancel after the first
    /// segment finishes → coordinator throws .cancelled(completed: 1,
    /// total: N) at the next-segment boundary, leaving partial state
    /// on Feishu. Earlier (later-in-doc) segments stay applied.
    func testCancelMidSegmentedPushSurfacesPartialProgress() async throws {
        // Use a recording mock that flips the signal as soon as one
        // segment's insert finishes, so the cancel check at the top
        // of the next iteration trips.
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["r0", "blk_A", "r2", "blk_B", "r4"],
            placeholderIds: ["blk_A", "blk_B"]
        )
        let signal = FeishuSyncCancellationSignal()
        api.afterInsertHook = { signal.cancel() }
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            paragraphNode(text: "L0"),
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "L2"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
            paragraphNode(text: "L4"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(
                input, title: "P", parentToken: nil, signal: signal
            )
            XCTFail("expected cancelled mid-segmented")
        } catch FeishuPushCoordinator.PushError.cancelled(let completed, let total) {
            XCTAssertEqual(total, 3,
                "three segments — leading L0, middle L2, trailing L4")
            XCTAssertEqual(completed, 1,
                "the trailing segment finished before signal flipped; subsequent segments aborted")
        }
        // legacy delete-then-create must not have been called
        XCTAssertEqual(api.pushCalls.count, 0)
    }

    /// Progress callback fires segmentStarted/segmentFinished pairs in
    /// the order segments complete (back-to-front in document order).
    func testSegmentedPushEmitsSegmentProgressEvents() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildrenMixed(
            docToken: "doxc_BOUND",
            childIds: ["blk_A", "r1", "blk_B"],
            placeholderIds: ["blk_A", "blk_B"]
        )
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_A", title: "A", type: "sheet"),
            paragraphNode(text: "between"),
            placeholderNode(blockId: "blk_B", title: "B", type: "board"),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [("blk_A", "sheet"), ("blk_B", "board")]
            ),
            body: body
        )

        var events: [FeishuPushCoordinator.Progress] = []
        _ = try await coordinator.push(input, title: "P", parentToken: nil) { event in
            events.append(event)
        }

        // Three segments (leading-empty, middle 1-block, trailing-empty).
        // Each emits segmentStarted + segmentFinished. Empty segments
        // still emit because the loop runs them all.
        let started = events.compactMap { evt -> Int? in
            if case .segmentStarted(let i, _) = evt { return i }; return nil
        }
        let finished = events.compactMap { evt -> Int? in
            if case .segmentFinished(let i, _) = evt { return i }; return nil
        }
        XCTAssertEqual(started, [1, 2, 3])
        XCTAssertEqual(finished, [1, 2, 3])
    }

    // MARK: - progress events (step4 lite)

    func testPushEmitsProgressEventsInOrderForNewDoc() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_PROG")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "title: P\n",
            body: "# H\n\nplain\n"
        )
        var events: [FeishuPushCoordinator.Progress] = []
        _ = try await coordinator.push(input, title: "P", parentToken: nil) { event in
            events.append(event)
        }

        // No image stage wired → no imageStageStarted/Finished. New doc
        // path → creatingDocument (not updatingTitle), then writingBody,
        // then done.
        XCTAssertEqual(events, [.creatingDocument, .writingBody, .done])
    }

    func testPushEmitsImageProgressWhenStageWired() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_IMG")
        api.uploadImageResponse = "img_TOK"
        let reader = InMemoryAssetReader()
        reader.put(filename: "a.png", data: Data([0x01]), mimeType: "image/png")
        reader.put(filename: "b.png", data: Data([0x02]), mimeType: "image/png")
        let stage = FeishuImageUploadStage(api: api, reader: reader)
        let coordinator = FeishuPushCoordinator(
            apiClient: api, imageUploadStage: stage
        )

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("donemd-asset://a.png")]),
            TiptapNode(type: "image", attrs: ["src": .string("donemd-asset://b.png")]),
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeFrontmatter(placeholderIds: []),
            body: body
        )

        var events: [FeishuPushCoordinator.Progress] = []
        _ = try await coordinator.push(input, title: "P", parentToken: nil) { event in
            events.append(event)
        }

        // #21 follow-up: image upload now runs AFTER createDocument so
        // each upload's parent_node carries the real document_id (the
        // drive endpoint 1061004s without it). New order:
        //   creatingDocument → imageStage* → writingBody → done.
        XCTAssertEqual(events, [
            .creatingDocument,
            .imageStageStarted(total: 2),
            .imageUploaded(index: 1, total: 2),
            .imageUploaded(index: 2, total: 2),
            .imageStageFinished,
            .writingBody,
            .done,
        ])
    }

    func testPushEmitsImageStageBracketEvenWhenNoUploads() async throws {
        // A doc with images that all get skipped (e.g. all https) — the
        // stage still emits started/finished so the UI's transition
        // off the image line works uniformly. uploadedCount = 0.
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NOUP")
        let stage = FeishuImageUploadStage(api: api, reader: InMemoryAssetReader())
        let coordinator = FeishuPushCoordinator(
            apiClient: api, imageUploadStage: stage
        )

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "image", attrs: ["src": .string("https://x.com/y.png")])
        ])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeFrontmatter(placeholderIds: []),
            body: body
        )

        var events: [FeishuPushCoordinator.Progress] = []
        _ = try await coordinator.push(input, title: "P", parentToken: nil) { event in
            events.append(event)
        }
        // #21 follow-up: createDocument now runs first; the image stage
        // bracket follows. Even when no uploads happen, the stage
        // emits started(0) + finished so the UI's transition logic
        // is uniform.
        XCTAssertEqual(events.first, .creatingDocument)
        XCTAssertTrue(events.contains(.imageStageStarted(total: 0)))
        XCTAssertEqual(events.last, .done)
        XCTAssertTrue(events.contains(.imageStageFinished))
    }

    func testPushBoundDocEmitsUpdatingTitleNotCreating() async throws {
        // Bound doc with leading H1 → no createDocument, but
        // updatingTitle now fires (#57 step4). Order:
        // updatingTitle → writingBody → done.
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            TiptapNode(type: "heading", attrs: ["level": .int(1)],
                       content: [TiptapNode.text("Title")]),
            TiptapNode(type: "paragraph", content: [TiptapNode.text("body")]),
        ])
        var feishu = FeishuFrontmatter()
        feishu.docToken = DocToken("doxc_BOUND")
        let frontmatter = Frontmatter(
            userFields: [],
            feishu: feishu,
            feishuOriginalIndex: 0,
            hasFence: true
        )
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        var events: [FeishuPushCoordinator.Progress] = []
        _ = try await coordinator.push(input, title: "fallback", parentToken: nil) { event in
            events.append(event)
        }
        XCTAssertTrue(events.contains(.updatingTitle),
            "bound doc with H1 → title PATCH triggers updatingTitle event")
        XCTAssertFalse(events.contains(.creatingDocument),
            "bound doc — should never createDocument")
        XCTAssertTrue(events.contains(.writingBody))
        XCTAssertEqual(events.last, .done)
        // Order matters: updatingTitle → writingBody.
        let titleIdx = events.firstIndex(of: .updatingTitle)
        let bodyIdx = events.firstIndex(of: .writingBody)
        XCTAssertNotNil(titleIdx)
        XCTAssertNotNil(bodyIdx)
        XCTAssertLessThan(titleIdx!, bodyIdx!,
            "title sync runs before body push")
    }

    func testProgressCallbackOptionalDefaultsToNoOp() async throws {
        // Existing call sites pass no progress arg; this is a regression
        // smoke-test that nil progress doesn't crash and the push still
        // succeeds. (All other tests already use the new signature; this
        // pins the default-arg contract.)
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_DEF")
        let coordinator = FeishuPushCoordinator(apiClient: api)
        let input = parsedDocument(frontmatterYAML: "title: P\n", body: "# H\n\np\n")
        _ = try await coordinator.push(input, title: "P", parentToken: nil)
        XCTAssertEqual(api.pushCalls.count, 1)
    }

    // MARK: - placeholder index integrity (step3.1)

    func testIndexMismatchMissingFromBodyBlocksPush() async throws {
        // The dangerous direction: frontmatter manifest claims a sheet
        // that the body has lost. A delete-then-create push would silently
        // delete the Feishu-side sheet (and its realtime collaboration
        // data). Coordinator must refuse before any side-effect.
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            paragraphNode(text: "user manually deleted the sheet placeholder")
        ])
        let frontmatter = makeFrontmatter(placeholderIds: [
            ("blk_LOST", "sheet")
        ])
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderIndexMismatch")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderIndexMismatch(let missingFromBody, let missingFromIndex) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(missingFromBody, ["blk_LOST"])
            XCTAssertEqual(missingFromIndex, [])
        }

        XCTAssertEqual(api.createCalls.count, 0)
        XCTAssertEqual(api.pushCalls.count, 0)
    }

    func testIndexMismatchMissingFromIndexBlocksPush() async throws {
        // The less dangerous direction: body has a placeholder the
        // frontmatter manifest doesn't list. Still blocks push so the
        // user notices the desync and can re-pull / repair.
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_NEW", title: "Surprise", type: "sheet")
        ])
        // Empty manifest.
        let frontmatter = makeFrontmatter(placeholderIds: [])
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected placeholderIndexMismatch")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderIndexMismatch(let missingFromBody, let missingFromIndex) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(missingFromBody, [])
            XCTAssertEqual(missingFromIndex, ["blk_NEW"])
        }
    }

    func testIntegrityCheckFiresBeforePlaceholderSafetyGate() async throws {
        // When both checks would trigger (body has placeholders + index
        // disagrees), the integrity error wins because it's strictly more
        // informative — the safety-gate dialog only says "this doc has
        // Feishu-only blocks", whereas the integrity dialog tells the user
        // *which* blocks are out of sync and which side is to blame.
        let api = MockFeishuAPIClient()
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [
            placeholderNode(blockId: "blk_X", title: "X", type: "sheet")
        ])
        let frontmatter = makeFrontmatter(placeholderIds: [
            ("blk_Y", "sheet")  // disjoint from body
        ])
        let input = MarkdownEngine.ParsedDocument(frontmatter: frontmatter, body: body)

        do {
            _ = try await coordinator.push(input, title: "P", parentToken: nil)
            XCTFail("expected error")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .placeholderIndexMismatch = error else {
                XCTFail("integrity check should win, got \(error)")
                return
            }
        }
    }

    func testIntegrityCheckPassesWhenIndexAndBodyAgreeOnEmptySet() async throws {
        // Both empty — common case, must not trip step3.1.
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_OK")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "title: P\n",
            body: "# H\n\nplain\n"
        )
        _ = try await coordinator.push(input, title: "P", parentToken: nil)
        XCTAssertEqual(api.pushCalls.count, 1)
    }

    func testPushWithoutPlaceholdersIsUnaffected() async throws {
        // A bare-bones smoke check that a body with zero placeholders
        // walks past the gate cleanly — the existing happy-path tests
        // already cover most of this, but pinning the gate's no-op behavior
        // here keeps the contract local to this MARK section.
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NOPHB")
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let input = parsedDocument(
            frontmatterYAML: "title: P\n",
            body: "# H\n\nplain text\n"
        )

        _ = try await coordinator.push(input, title: "P", parentToken: nil)
        XCTAssertEqual(api.createCalls.count, 1)
        XCTAssertEqual(api.pushCalls.count, 1)
    }

    // MARK: - helpers

    private func parsedDocument(
        frontmatterYAML: String, body: String
    ) -> MarkdownEngine.ParsedDocument {
        let source: String
        if frontmatterYAML.isEmpty {
            source = body
        } else {
            let trimmed = frontmatterYAML.hasSuffix("\n") ? frontmatterYAML : frontmatterYAML + "\n"
            source = "---\n\(trimmed)---\n\(body)"
        }
        return MarkdownEngine.parseDocument(source: source)
    }

    private func paragraphNode(text: String) -> TiptapNode {
        TiptapNode(type: "paragraph", content: [TiptapNode.text(text)])
    }

    private func placeholderNode(
        blockId: String, title: String, type: String, url: String = "https://x"
    ) -> TiptapNode {
        TiptapNode(type: "feishu_placeholder_block", attrs: [
            "type": .string(type),
            "block_id": .string(blockId),
            "title": .string(title),
            "url": .string(url),
        ])
    }

    /// Build a Frontmatter with a `feishu.placeholder_blocks` manifest of
    /// the supplied (block_id, type) pairs. Used by step3.1 tests to
    /// drive the integrity check; takes block_id + type so the harness
    /// reads naturally without yams.
    private func makeFrontmatter(
        placeholderIds pairs: [(String, String)]
    ) -> Frontmatter {
        let refs = pairs.map { PlaceholderBlockRef(blockId: $0.0, type: $0.1) }
        return Frontmatter(
            userFields: [],
            feishu: FeishuFrontmatter(placeholderBlocks: refs),
            feishuOriginalIndex: 0,
            hasFence: true
        )
    }

    /// Like `makeFrontmatter`, but stamps a `feishu.docToken` so the
    /// document looks bound. #57 step1 preflight only fires on bound
    /// docs (unbound docs go through createDocument, where there's
    /// nothing on Feishu to agree with).
    private func makeBoundFrontmatter(
        docToken: String,
        placeholderIds pairs: [(String, String)],
        lastPulledRevision: Int? = nil
    ) -> Frontmatter {
        let refs = pairs.map { PlaceholderBlockRef(blockId: $0.0, type: $0.1) }
        return Frontmatter(
            userFields: [],
            feishu: FeishuFrontmatter(
                docToken: DocToken(docToken),
                lastPulledRevision: lastPulledRevision,
                placeholderBlocks: refs
            ),
            feishuOriginalIndex: 0,
            hasFence: true
        )
    }

    /// Build a `[FeishuBlock]` shaped like a real `pullDocument`
    /// response: one page block whose `children` lists the supplied
    /// placeholder ids in order, plus one placeholder block per id.
    /// Enough for #57 preflight tests that only care about the
    /// placeholder id sequence — the rest of the converter shape isn't
    /// exercised here.
    private func feishuRootChildren(
        docToken: String,
        placeholderIds: [String]
    ) -> [FeishuBlock] {
        return feishuRootChildrenMixed(
            docToken: docToken,
            childIds: placeholderIds,
            placeholderIds: placeholderIds
        )
    }

    /// Build a `[FeishuBlock]` for `pullDocument` responses with mixed
    /// child types — placeholder ids vs. non-placeholder ids in
    /// arbitrary positions. Non-placeholder children get materialized
    /// as `.text` blocks (smallest non-placeholder payload that
    /// satisfies the encoder); placeholder children get `.placeholder`
    /// blocks. Used by segmented-push tests that need a remote child
    /// id sequence with both kinds at known positions.
    private func feishuRootChildrenMixed(
        docToken: String,
        childIds: [String],
        placeholderIds: [String]
    ) -> [FeishuBlock] {
        var blocks: [FeishuBlock] = []
        blocks.append(FeishuBlock(
            blockId: docToken,
            parentId: nil,
            children: childIds,
            payload: .page(.init())
        ))
        let placeholderSet = Set(placeholderIds)
        for id in childIds {
            if placeholderSet.contains(id) {
                blocks.append(FeishuBlock(
                    blockId: id,
                    parentId: docToken,
                    children: nil,
                    payload: .placeholder(.init(
                        subtype: .sheet,
                        title: id,
                        url: "https://example.com/\(id)"
                    ))
                ))
            } else {
                blocks.append(FeishuBlock(
                    blockId: id,
                    parentId: docToken,
                    children: nil,
                    payload: .text(.init(elements: [.textRun(.init(content: id))]))
                ))
            }
        }
        return blocks
    }

    // MARK: - #51 v2-9b revision conflict preflight

    /// Bound doc + lastPulledRevision matches Feishu side → push proceeds.
    /// Asserts getDocumentRevision was called once (preflight) and the
    /// rest of the push pipeline ran (the legacy delete-then-create
    /// path for non-placeholder bodies, exercised here).
    func testRevisionConflictPreflightAllowsPushWhenRevisionsMatch() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND", placeholderIds: []
        )
        api.pullDocumentRevision = 7
        api.getDocumentRevisionResult = 7  // remote unchanged
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [paragraphNode(text: "hello")])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [],
                lastPulledRevision: 7
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "T", parentToken: nil)

        XCTAssertEqual(api.getDocumentRevisionCalls, ["doxc_BOUND"],
            "preflight calls getDocumentRevision once")
    }

    /// Bound doc + lastPulledRevision behind Feishu side → push throws
    /// PushError.feishuRevisionConflict carrying both numbers.
    func testRevisionConflictPreflightBlocksPushWhenRemoteAhead() async throws {
        let api = MockFeishuAPIClient()
        api.getDocumentRevisionResult = 12  // remote has moved on
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [paragraphNode(text: "hi")])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [],
                lastPulledRevision: 7
            ),
            body: body
        )

        do {
            _ = try await coordinator.push(input, title: "T", parentToken: nil)
            XCTFail("expected feishuRevisionConflict")
        } catch let error as FeishuPushCoordinator.PushError {
            guard case .feishuRevisionConflict(let local, let remote) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(local, 7)
            XCTAssertEqual(remote, 12)
        }
        // Confirms preflight short-circuits before pullDocument /
        // segmented push — Feishu side must remain untouched.
        XCTAssertEqual(api.pullCalls.count, 0,
            "conflict short-circuits before pullDocument")
    }

    /// forceOverwrite=true skips the preflight entirely. Used by the
    /// "仍然覆盖" branch in PushCommand to retry without looping on
    /// the same conflict.
    func testRevisionConflictPreflightSkippedWhenForceOverwrite() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND", placeholderIds: []
        )
        api.pullDocumentRevision = 7
        api.getDocumentRevisionResult = 12  // remote ahead but irrelevant
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [paragraphNode(text: "hi")])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [],
                lastPulledRevision: 7
            ),
            body: body
        )

        _ = try await coordinator.push(
            input, title: "T", parentToken: nil,
            forceOverwrite: true
        )

        XCTAssertEqual(api.getDocumentRevisionCalls.count, 0,
            "forceOverwrite skips revision preflight entirely")
    }

    /// Bound doc with no lastPulledRevision (fresh binding via manual
    /// frontmatter edit, or partialSuccess recovery before the first
    /// pull) → preflight should not run, push should proceed.
    func testRevisionConflictPreflightSkippedWhenLocalRevisionMissing() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = feishuRootChildren(
            docToken: "doxc_BOUND", placeholderIds: []
        )
        api.pullDocumentRevision = 7
        api.getDocumentRevisionResult = 12
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [paragraphNode(text: "hi")])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: makeBoundFrontmatter(
                docToken: "doxc_BOUND",
                placeholderIds: [],
                lastPulledRevision: nil
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "T", parentToken: nil)

        XCTAssertEqual(api.getDocumentRevisionCalls.count, 0,
            "no localRevision means we have no baseline — push proceeds")
    }

    /// Unbound doc (no docToken) takes the createDocument path. Revision
    /// preflight makes no sense there — there is no prior Feishu doc.
    func testRevisionConflictPreflightSkippedWhenUnbound() async throws {
        let api = MockFeishuAPIClient()
        api.createDocumentResponse = .success("doxc_NEW")
        api.getDocumentRevisionResult = 99
        let coordinator = FeishuPushCoordinator(apiClient: api)

        let body = TiptapNode(type: "doc", content: [paragraphNode(text: "hi")])
        let input = MarkdownEngine.ParsedDocument(
            frontmatter: Frontmatter(
                userFields: [], feishu: nil,
                feishuOriginalIndex: nil, hasFence: false
            ),
            body: body
        )

        _ = try await coordinator.push(input, title: "T", parentToken: nil)

        XCTAssertEqual(api.getDocumentRevisionCalls.count, 0,
            "unbound docs skip the revision preflight entirely")
    }
}

// MARK: - mock API client

final class MockFeishuAPIClient: FeishuAPIClient {

    enum CreateResponse {
        case success(String)
        case failure(FeishuAPIError)
    }

    var createDocumentResponse: CreateResponse = .success("doxc_DEFAULT")
    var pushDocumentError: FeishuAPIError? = nil
    var pullDocumentResponse: [FeishuBlock] = []
    /// Remote document state after a successful `pushDocument`, modeling
    /// what a real Feishu re-read returns. Nil until the first push lands.
    /// The Layer-1 body-verification gate (#84/#85) re-reads via
    /// `pullDocument` right after pushing and refuses to mark the sync
    /// successful if the body came back empty; a fake that always returned
    /// `pullDocumentResponse` (empty by default) would trip that gate on
    /// every happy-path push. Echoing the just-pushed blocks here — the
    /// honest API behavior — lets the gate see the body it wrote, while a
    /// nil state before any push keeps preflight pulls reading the
    /// test-configured `pullDocumentResponse`.
    private var remoteStateAfterPush: [FeishuBlock]? = nil
    /// Revision returned alongside `pullDocumentResponse`. Push tests don't
    /// care about it; pull tests overwrite this slot to drive
    /// `lastPulledRevision` assertions.
    var pullDocumentRevision: Int = 0
    /// When non-nil, `pullDocument` throws this error instead of returning
    /// `pullDocumentResponse`. Mirrors `pushDocumentError`.
    var pullDocumentError: FeishuAPIError? = nil
    /// When non-nil, `updateDocumentTitle` throws this error. Tests verify
    /// the failure surfaces as `PushError.apiFailed` for existing-doc
    /// pushes, with no `pushDocument` follow-up.
    var updateTitleError: FeishuAPIError? = nil
    var uploadImageResponse: String = "img_DEFAULT"
    /// When non-nil, `uploadImage` throws this error. Drives the
    /// image-stage error-propagation tests (#50 step2).
    var uploadImageError: FeishuAPIError? = nil

    private(set) var createCalls: [(title: String, parentToken: String?)] = []
    private(set) var pushCalls: [(documentId: String, blocks: [FeishuBlock])] = []
    private(set) var pullCalls: [String] = []
    private(set) var updateTitleCalls: [(documentId: String, title: String)] = []
    private(set) var uploadCalls: [(data: Data, mimeType: String, fileName: String)] = []
    /// #57 segmented push observability — preserves the call order so
    /// tests can assert "delete then insert, back-to-front" semantics.
    private(set) var segmentedCalls: [SegmentedCall] = []
    /// When non-nil, `deleteChildrenRange` throws this error on the
    /// next call (then clears it — one-shot). Drives the segmented
    /// push partial-failure path.
    var deleteRangeError: FeishuAPIError? = nil
    /// When non-nil, `insertChildrenAt` throws this error on the next
    /// call (then clears it).
    var insertAtError: FeishuAPIError? = nil

    enum SegmentedCall: Equatable {
        case delete(parentBlockId: String, startIndex: Int, endIndex: Int)
        case insert(parentBlockId: String, index: Int, blockCount: Int)
    }

    /// Hook fired after every successful insert call. Used by #57
    /// step5 cancel tests to flip the cancel signal mid-pipeline.
    var afterInsertHook: (() -> Void)?

    func pullDocument(documentId: String) async throws -> (blocks: [FeishuBlock], revisionId: Int) {
        pullCalls.append(documentId)
        if let error = pullDocumentError { throw error }
        // After a push, echo what landed (the body-verification gate's
        // re-read); before any push, return the test-configured remote.
        return (remoteStateAfterPush ?? pullDocumentResponse, pullDocumentRevision)
    }

    func pushDocument(documentId: String, blocks: [FeishuBlock]) async throws {
        pushCalls.append((documentId, blocks))
        if let error = pushDocumentError { throw error }
        // The push succeeded → the remote now holds these blocks.
        remoteStateAfterPush = blocks
    }

    func createDocument(title: String, parentToken: String?) async throws -> String {
        createCalls.append((title, parentToken))
        switch createDocumentResponse {
        case .success(let id): return id
        case .failure(let err): throw err
        }
    }

    func updateDocumentTitle(documentId: String, title: String) async throws {
        updateTitleCalls.append((documentId, title))
        if let error = updateTitleError { throw error }
    }

    func uploadImage(
        data: Data,
        mimeType: String,
        fileName: String,
        documentId: String
    ) async throws -> String {
        uploadCalls.append((data, mimeType, fileName))
        uploadDocumentIds.append(documentId)
        if let error = uploadImageError { throw error }
        return uploadImageResponse
    }
    /// #21 follow-up: lock that the stage routes the push's docToken
    /// through to uploadImage as parent_node.
    private(set) var uploadDocumentIds: [String] = []

    /// `downloadImage` mock for #21 image pull stage. Tests that
    /// exercise download flows configure either `downloadImageBytes`
    /// (success path) or `downloadImageError` (failure). The success
    /// path defaults to a 1-byte PNG so any test that doesn't
    /// override it still gets a valid response shape.
    var downloadImageBytes: (data: Data, mimeType: String) = (Data([0xFF]), "image/png")
    var downloadImageError: FeishuAPIError? = nil
    private(set) var downloadCalls: [String] = []

    func downloadImage(token: String) async throws -> (data: Data, mimeType: String) {
        downloadCalls.append(token)
        if let error = downloadImageError { throw error }
        return downloadImageBytes
    }

    /// Wiki-node resolver mock for the #58 import flow. PushCoordinator
    /// itself never calls this — it's a protocol completeness stub.
    /// Tests that exercise the import command set
    /// `resolveWikiNodeResolution` directly on the per-test client.
    var resolveWikiNodeResolution: WikiNodeResolution =
        WikiNodeResolution(objToken: "doxc_mocked", objType: "docx", title: nil)
    var resolveWikiNodeError: FeishuAPIError? = nil
    private(set) var resolveWikiNodeCalls: [String] = []

    func resolveWikiNode(token: String) async throws -> WikiNodeResolution {
        resolveWikiNodeCalls.append(token)
        if let error = resolveWikiNodeError { throw error }
        return resolveWikiNodeResolution
    }

    /// #51 v2-9b revision-conflict preflight mock. Tests set
    /// `getDocumentRevisionResult` directly. Default mirrors
    /// pullDocumentResponse's revision (1) so existing tests that
    /// don't touch the conflict path keep working without setup.
    var getDocumentRevisionResult: Int = 1
    var getDocumentRevisionError: FeishuAPIError? = nil
    private(set) var getDocumentRevisionCalls: [String] = []

    func getDocumentRevision(documentId: String) async throws -> Int {
        getDocumentRevisionCalls.append(documentId)
        if let error = getDocumentRevisionError { throw error }
        return getDocumentRevisionResult
    }

    func deleteChildrenRange(
        documentId: String,
        parentBlockId: String,
        startIndex: Int,
        endIndex: Int
    ) async throws {
        segmentedCalls.append(.delete(
            parentBlockId: parentBlockId,
            startIndex: startIndex,
            endIndex: endIndex
        ))
        if let err = deleteRangeError {
            deleteRangeError = nil
            throw err
        }
    }

    func insertChildrenAt(
        documentId: String,
        parentBlockId: String,
        index: Int,
        blocks: [FeishuBlock]
    ) async throws {
        // Match the production behavior: page-only payloads (no
        // descendants) are no-ops and don't emit calls.
        let nonPageCount = blocks.filter {
            if case .page = $0.payload { return false } else { return true }
        }.count
        if nonPageCount == 0 { return }
        segmentedCalls.append(.insert(
            parentBlockId: parentBlockId,
            index: index,
            blockCount: nonPageCount
        ))
        if let err = insertAtError {
            insertAtError = nil
            throw err
        }
        afterInsertHook?()
    }
}
