import XCTest
@testable import donemd

/// v2 Slice 8 / "v2-9b" step1 (#49) — happy-path PullCoordinator.
///
/// Scope of this suite (mirrors `FeishuPushCoordinatorTests`):
///   - new doc: pull builds a fresh ParsedDocument with feishu.docToken
///     stamped, body parsed from converted markdown, lastPulledRevision
///     set
///   - existing: user fields round-trip in original order; unknown
///     feishu.* keys preserved; lastPushedAt preserved
///   - body wire shape: existing body fully replaced by pulled blocks
///   - errors: API failures surface as PullError.apiFailed
///   - warnings: converter warnings flow through onto the result
///
/// Out of scope (deferred to step2 / 9b):
///   - unsaved-changes dialog (UI layer)
///   - OAuth re-routing on .unauthorized (UI layer)
///   - placeholder index frontmatter sync
///   - revision conflict detection — that's #51
final class FeishuPullCoordinatorTests: XCTestCase {

    // MARK: - happy paths

    func testPullNewDocumentBuildsParsedDocument() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_NEW", text: "Hello"
        )
        api.pullDocumentRevision = 5
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_NEW"), into: nil
        )

        XCTAssertEqual(api.pullCalls, ["doxc_NEW"])
        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.docToken,
            DocToken("doxc_NEW")
        )
        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.lastPulledRevision,
            5
        )
        XCTAssertTrue(
            flattenText(result.updatedDocument.body).contains("Hello"),
            "body must carry the pulled paragraph text"
        )
    }

    func testPullExistingDocumentPreservesUserFields() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "New body"
        )
        api.pullDocumentRevision = 9
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let existing = parsedDocument(
            frontmatterYAML: """
            title: Hello
            tags: [foo, bar]
            """,
            body: "# Old body\n"
        )
        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: existing
        )

        let userKeys = result.updatedDocument.frontmatter.userFields.map(\.key)
        XCTAssertEqual(userKeys, ["title", "tags"],
            "user fields must round-trip in order, untouched by pull")
    }

    func testPullPreservesUnknownFeishuFields() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "body"
        )
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let existing = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_X
              foo: bar
            """,
            body: "old\n"
        )
        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: existing
        )

        let unknownKeys = result.updatedDocument.frontmatter.feishu?
            .unknownFields.map(\.key) ?? []
        XCTAssertTrue(unknownKeys.contains("foo"),
            "unknown feishu key 'foo' must round-trip — got \(unknownKeys)")
    }

    func testPullPreservesLastPushedAtAndOverwritesRevision() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "body"
        )
        api.pullDocumentRevision = 42
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let existing = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_X
              last_pushed_at: 2020-01-01T00:00:00Z
              last_pulled_revision: 1
            """,
            body: "old\n"
        )
        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: existing
        )

        XCTAssertEqual(
            result.updatedDocument.frontmatter.feishu?.lastPulledRevision,
            42, "lastPulledRevision must advance to the pulled revision"
        )
        XCTAssertNotNil(
            result.updatedDocument.frontmatter.feishu?.lastPushedAt,
            "lastPushedAt must round-trip — it's still the last push"
        )
    }

    // MARK: - body wire shape

    func testBodyIsRebuiltFromBlocksNotMergedWithExistingBody() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "NEW"
        )
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let existing = parsedDocument(
            frontmatterYAML: "title: T\n",
            body: "OLD body that must disappear\n"
        )
        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: existing
        )

        let bodyText = flattenText(result.updatedDocument.body)
        XCTAssertTrue(bodyText.contains("NEW"),
            "pulled paragraph text must appear in the result body")
        XCTAssertFalse(bodyText.contains("OLD"),
            "existing body must be fully replaced by pulled blocks")
    }

    // MARK: - error paths

    func testPullFailureSurfacesAsAPIFailed() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentError = .networkUnreachable("offline")
        let coordinator = FeishuPullCoordinator(apiClient: api)

        do {
            _ = try await coordinator.pull(
                token: DocToken("doxc_X"), into: nil
            )
            XCTFail("expected PullError.apiFailed")
        } catch let error as FeishuPullCoordinator.PullError {
            guard case .apiFailed(let underlying) = error else {
                XCTFail("expected apiFailed, got \(error)")
                return
            }
            guard case .networkUnreachable(let msg) = underlying else {
                XCTFail("expected networkUnreachable, got \(underlying)")
                return
            }
            XCTAssertEqual(msg, "offline")
        }
    }

    func testNotFoundSurfacesUnchanged() async throws {
        let api = MockFeishuAPIClient()
        api.pullDocumentError = .notFound(resource: "doxc_X")
        let coordinator = FeishuPullCoordinator(apiClient: api)

        do {
            _ = try await coordinator.pull(
                token: DocToken("doxc_X"), into: nil
            )
            XCTFail("expected PullError.apiFailed(.notFound)")
        } catch let error as FeishuPullCoordinator.PullError {
            guard case .apiFailed(.notFound(let resource)) = error else {
                XCTFail("expected apiFailed(.notFound), got \(error)")
                return
            }
            XCTAssertEqual(resource, "doxc_X")
        }
    }

    // MARK: - title binding (Notion-style: page.title → leading H1)

    func testPullPrependsPageTitleAsLeadingH1() async throws {
        let api = MockFeishuAPIClient()
        let page = FeishuBlock(
            blockId: "doxc_X", parentId: nil, children: ["p1"],
            payload: .page(.init(title: .init(elements: [
                .textRun(.init(content: "Doc Title"))
            ])))
        )
        let para = FeishuBlock(
            blockId: "p1", parentId: "doxc_X", children: nil,
            payload: .text(.init(elements: [
                .textRun(.init(content: "body"))
            ]))
        )
        api.pullDocumentResponse = [page, para]
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        let firstChild = try XCTUnwrap(result.updatedDocument.body.content?.first)
        XCTAssertEqual(firstChild.type, "heading",
            "page.title must surface as the body's first node")
        if case .int(let level)? = firstChild.attrs?["level"] {
            XCTAssertEqual(level, 1, "title heading must be level 1")
        } else {
            XCTFail("expected heading attrs.level=Int(1), got \(firstChild.attrs ?? [:])")
        }
        XCTAssertTrue(flattenText(firstChild).contains("Doc Title"),
            "leading heading must carry the page title text")
    }

    func testPullSkipsLeadingH1WhenPageTitleEmpty() async throws {
        let api = MockFeishuAPIClient()
        // Default `.page(.init())` has empty title.elements — pull must not
        // synthesize an empty `# ` heading.
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "just body"
        )
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        let firstChild = try XCTUnwrap(result.updatedDocument.body.content?.first)
        XCTAssertNotEqual(firstChild.type, "heading",
            "empty title → no synthetic H1 prepended")
    }

    // MARK: - converter warnings

    func testConverterWarningsSurfacedOnPullResult() async throws {
        let api = MockFeishuAPIClient()
        // Page → placeholder (sheet) with one nested paragraph child.
        // Converter must drop the child and emit one warning.
        let page = FeishuBlock(
            blockId: "doxc_X", parentId: nil, children: ["pl1"],
            payload: .page(.init())
        )
        let placeholder = FeishuBlock(
            blockId: "pl1", parentId: "doxc_X", children: ["c1"],
            payload: .placeholder(.init(
                subtype: .sheet,
                title: "Embedded sheet",
                url: "https://example.com/sheet/X"
            ))
        )
        let nested = FeishuBlock(
            blockId: "c1", parentId: "pl1", children: nil,
            payload: .text(.init(elements: [
                .textRun(.init(content: "dropped child"))
            ]))
        )
        api.pullDocumentResponse = [page, placeholder, nested]
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        XCTAssertEqual(result.warnings.count, 1)
        guard case .nestedContentDroppedInPlaceholder(let blockId, let count) =
                result.warnings.first else {
            XCTFail("expected nestedContentDroppedInPlaceholder, got \(result.warnings)")
            return
        }
        XCTAssertEqual(blockId, "pl1")
        XCTAssertEqual(count, 1)
    }

    // MARK: - placeholder index rewrite (step4)

    func testPullRewritesPlaceholderIndexFromPulledBody() async throws {
        let api = MockFeishuAPIClient()
        let page = FeishuBlock(
            blockId: "doxc_X", parentId: nil, children: ["pl1", "pl2"],
            payload: .page(.init())
        )
        let placeholder1 = FeishuBlock(
            blockId: "pl1", parentId: "doxc_X", children: nil,
            payload: .placeholder(.init(
                subtype: .sheet,
                title: "Sheet One",
                url: "https://example.com/sheet/1"
            ))
        )
        let placeholder2 = FeishuBlock(
            blockId: "pl2", parentId: "doxc_X", children: nil,
            payload: .placeholder(.init(
                subtype: .board,
                title: "Board Two",
                url: "https://example.com/board/2"
            ))
        )
        api.pullDocumentResponse = [page, placeholder1, placeholder2]
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        let refs = result.updatedDocument.frontmatter.feishu?.placeholderBlocks ?? []
        XCTAssertEqual(refs.count, 2,
            "frontmatter must list every placeholder in the pulled body")
        XCTAssertEqual(refs.map(\.blockId), ["pl1", "pl2"],
            "ids must follow document order")
        XCTAssertEqual(refs[0].title, "Sheet One")
        XCTAssertEqual(refs[1].title, "Board Two")
        XCTAssertFalse(refs[0].type.isEmpty,
            "type must round-trip from placeholder subtype")
    }

    func testPullRewritesPlaceholderIndexEvenWhenExistingHadStaleEntries() async throws {
        // The pre-pull frontmatter index pointed at blocks that no longer
        // appear after the pull (the Feishu side deleted them). The post-pull
        // index must reflect *what's in the body now*, not what *was* there —
        // otherwise push's step3.1 integrity gate would always fail right
        // after a pull.
        let api = MockFeishuAPIClient()
        api.pullDocumentResponse = pageWithParagraph(
            pageId: "doxc_X", text: "no placeholders left"
        )
        api.pullDocumentRevision = 1
        let coordinator = FeishuPullCoordinator(apiClient: api)

        let existing = parsedDocument(
            frontmatterYAML: """
            feishu:
              doc_token: doxc_X
              placeholder_blocks:
                - block_id: stale_pl1
                  type: sheet
                  title: Old sheet
            """,
            body: "old\n"
        )
        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: existing
        )

        let refs = result.updatedDocument.frontmatter.feishu?.placeholderBlocks ?? []
        XCTAssertTrue(refs.isEmpty,
            "stale placeholder index must be cleared when the pulled body has no placeholders — got \(refs)")
    }

    // MARK: - #21 image download stage integration

    /// When PullCoordinator is wired with a download stage, every
    /// feishu://image/<token> in the body gets rewritten to
    /// donemd-asset://<filename> and the report counts the download.
    func testPullWithImageStageRewritesFeishuImageToLocalAsset() async throws {
        let api = MockFeishuAPIClient()
        api.downloadImageBytes = (Data([0x89]), "image/png")
        // Feishu sends an image block (block_type 27) referencing
        // an image_token.
        let imageBlockId = "doxc_X_img1"
        let page = FeishuBlock(
            blockId: "doxc_X", parentId: nil,
            children: [imageBlockId],
            payload: .page(.init())
        )
        let imageBlock = FeishuBlock(
            blockId: imageBlockId, parentId: "doxc_X", children: nil,
            payload: .image(.init(token: "IMG_TOKEN_xyz"))
        )
        api.pullDocumentResponse = [page, imageBlock]
        api.pullDocumentRevision = 1

        let writer = InMemoryImageWriter()
        let stage = FeishuImageDownloadStage(api: api, writer: writer)
        let coordinator = FeishuPullCoordinator(
            apiClient: api, imageDownloadStage: stage
        )

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        XCTAssertEqual(api.downloadCalls, ["IMG_TOKEN_xyz"],
            "PullCoordinator must route feishu:// image refs through downloadImage")
        XCTAssertEqual(result.imageReport?.downloadedCount, 1)
        XCTAssertEqual(writer.written.count, 1,
            "downloaded bytes must be persisted via the writer")
        // The serialized markdown stores the local-relative path
        // (`./assets/<filename>`) — that's the disk form we want, the
        // WebView resolves donemd-asset:// at render time. Either form
        // means "image was rewritten away from feishu://image/".
        let bodyText = MarkdownEngine.serialize(document: result.updatedDocument)
        XCTAssertTrue(
            bodyText.contains("donemd-asset://") || bodyText.contains("./assets/"),
            "rewritten image src must surface in the serialized markdown — got:\n\(bodyText)"
        )
        XCTAssertFalse(bodyText.contains("feishu://image/"),
            "no feishu:// scheme should leak into the saved body when the download succeeded")
    }

    /// No download stage wired → coordinator leaves feishu://image
    /// srcs alone (legacy behaviour, used by the unit tests that
    /// don't care about images).
    func testPullWithoutImageStagePreservesFeishuImageSrc() async throws {
        let api = MockFeishuAPIClient()
        let imageBlockId = "doxc_X_img1"
        let page = FeishuBlock(
            blockId: "doxc_X", parentId: nil,
            children: [imageBlockId],
            payload: .page(.init())
        )
        let imageBlock = FeishuBlock(
            blockId: imageBlockId, parentId: "doxc_X", children: nil,
            payload: .image(.init(token: "IMG_TOKEN"))
        )
        api.pullDocumentResponse = [page, imageBlock]
        api.pullDocumentRevision = 1

        let coordinator = FeishuPullCoordinator(apiClient: api)

        let result = try await coordinator.pull(
            token: DocToken("doxc_X"), into: nil
        )

        XCTAssertNil(result.imageReport,
            "without a stage wired, imageReport stays nil")
        XCTAssertEqual(api.downloadCalls, [],
            "without a stage wired, no downloads attempted")
    }

    // MARK: - helpers

    /// Minimal `[FeishuBlock]` rooted at a page block with one paragraph
    /// child carrying `text`. Enough for round-trip sanity assertions
    /// without committing the test to a specific block-tree shape.
    private func pageWithParagraph(pageId: String, text: String) -> [FeishuBlock] {
        let paraId = pageId + "_p1"
        let page = FeishuBlock(
            blockId: pageId, parentId: nil, children: [paraId],
            payload: .page(.init())
        )
        let para = FeishuBlock(
            blockId: paraId, parentId: pageId, children: nil,
            payload: .text(.init(elements: [
                .textRun(.init(content: text))
            ]))
        )
        return [page, para]
    }

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

    /// Walk a Tiptap body and concatenate every text-run content for a
    /// "did this string land in the result?" assertion. Mirrors the
    /// `flattenText` helper in `FeishuPushCoordinatorTests`, but on
    /// `TiptapNode` instead of `[FeishuBlock]`.
    private func flattenText(_ node: TiptapNode) -> String {
        var collected: [String] = []
        if let text = node.text { collected.append(text) }
        for child in node.content ?? [] {
            collected.append(flattenText(child))
        }
        return collected.joined(separator: "\n")
    }
}
