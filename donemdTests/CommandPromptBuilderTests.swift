import XCTest
@testable import donemd

/// Phase 3 Slice 4 (#65) — M3 CommandPromptBuilder, full 13-command set.
///
/// Pure-function tests: given (command, selection context, contextRange),
/// assert the prompt messages. Per PRD § 测试决策 the test names mirror user
/// stories; we assert external behavior (the string the Provider receives),
/// not template internals.
final class CommandPromptBuilderTests: XCTestCase {

    // Convenience: messages from a build, ignoring the degrade flag.
    private func msgs(_ command: AICommand, _ ctx: SelectionContext, range: Int = 1) -> [AIMessage] {
        CommandPromptBuilder.build(command: command, context: ctx, contextRange: range).messages
    }
    private func system(_ command: AICommand, _ ctx: SelectionContext) -> String {
        msgs(command, ctx).first!.content
    }
    private func user(_ command: AICommand, _ ctx: SelectionContext, range: Int = 1) -> String {
        msgs(command, ctx, range: range).last!.content
    }

    // MARK: - shape

    func testBuildReturnsSystemThenUser() {
        let m = msgs(.polish, SelectionContext(selection: "x"))
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.map(\.role), [.system, .user])
    }

    func testAllCommandsProduceTwoMessages() {
        for cmd in Self.allCommands {
            let m = msgs(cmd, SelectionContext(selection: "测试", paragraph: "测试"))
            XCTAssertEqual(m.count, 2, "\(cmd) should yield system+user")
            XCTAssertEqual(m.first?.role, .system)
            XCTAssertEqual(m.last?.role, .user)
        }
    }

    func testEveryCommandSelectionSurvivesVerbatim() {
        let sel = "**加粗** 和 `代码` 和 [链接](http://x.com)"
        for cmd in Self.allCommands {
            let u = user(cmd, SelectionContext(selection: sel, paragraph: sel))
            XCTAssertTrue(u.contains(sel), "\(cmd) must pass the selection through untouched")
        }
    }

    // MARK: - 改写组 instructions

    func testPolishInstruction() {
        XCTAssertTrue(system(.polish, SelectionContext(selection: "x")).contains("更自然流畅"))
        XCTAssertTrue(system(.polish, SelectionContext(selection: "x")).contains("不要任何前后说明"))
    }

    func testFormalInstruction() {
        XCTAssertTrue(system(.formal, SelectionContext(selection: "x")).contains("正式书面语"))
    }

    func testColloquialInstruction() {
        XCTAssertTrue(system(.colloquial, SelectionContext(selection: "x")).contains("日常口语"))
    }

    func testSimplifyInstruction() {
        XCTAssertTrue(system(.simplify, SelectionContext(selection: "x")).contains("精简"))
    }

    // MARK: - 自定义改写: intent substitution

    func testCustomRewriteEmbedsUserIntent() {
        let s = system(.customRewrite(intent: "改成更幽默的语气"), SelectionContext(selection: "x"))
        XCTAssertTrue(s.contains("改成更幽默的语气"), "user intent must reach the instruction")
    }

    func testCustomRewriteWithDifferentIntentDiffers() {
        let a = system(.customRewrite(intent: "更正式"), SelectionContext(selection: "x"))
        let b = system(.customRewrite(intent: "更口语"), SelectionContext(selection: "x"))
        XCTAssertNotEqual(a, b)
    }

    func testCustomRewriteUsesSurroundingContext() {
        XCTAssertEqual(AICommand.customRewrite(intent: "x").contextScope, .surroundingParagraphs)
    }

    // MARK: - 翻译组: selection-only, no surrounding context

    func testTranslateToEnglishInstruction() {
        XCTAssertTrue(system(.translateToEnglish, SelectionContext(selection: "你好")).contains("英文"))
    }

    func testTranslateToChineseInstruction() {
        XCTAssertTrue(system(.translateToChinese, SelectionContext(selection: "hello")).contains("中文"))
    }

    func testTranslateToCustomLanguageSubstituted() {
        let s = system(.translateTo(language: "日文"), SelectionContext(selection: "hi"))
        XCTAssertTrue(s.contains("日文"))
    }

    func testTranslationIsSelectionOnlyIgnoringNeighbours() {
        // PRD user story 57: translation never carries surrounding context.
        let ctx = SelectionContext(
            selection: "需要翻译的句子。",
            paragraph: "需要翻译的句子。",
            before: "前一段不该出现。",
            after: "后一段不该出现。"
        )
        let u = user(.translateToEnglish, ctx)
        XCTAssertEqual(u, "需要翻译的句子。")
        XCTAssertFalse(u.contains("前一段不该出现。"))
        XCTAssertFalse(u.contains("后一段不该出现。"))
        XCTAssertFalse(u.contains("仅供参考"))
    }

    func testAllTranslateCommandsAreSelectionOnly() {
        for cmd in [AICommand.translateToEnglish, .translateToChinese, .translateTo(language: "韩文")] {
            XCTAssertEqual(cmd.contextScope, .selectionOnly, "\(cmd) must be selection-only")
        }
    }

    // MARK: - 转换组

    func testSummarizeInstruction() {
        XCTAssertTrue(system(.summarize, SelectionContext(selection: "x")).contains("总结"))
    }

    func testExpandInstruction() {
        XCTAssertTrue(system(.expand, SelectionContext(selection: "x")).contains("展开"))
    }

    func testOutlineInstruction() {
        XCTAssertTrue(system(.outline, SelectionContext(selection: "x")).contains("大纲"))
    }

    func testToTableAllowsNotSuitableAnswer() {
        // PRD acceptance: 转表格 must be able to say 不适合 rather than forcing.
        let s = system(.toTable, SelectionContext(selection: "x"))
        XCTAssertTrue(s.contains("不适合"), "toTable prompt must offer the 不适合 escape")
        XCTAssertTrue(s.contains("表格"))
    }

    func testTransformCommandsUseSurroundingContext() {
        for cmd in [AICommand.summarize, .expand, .outline, .toTable] {
            XCTAssertEqual(cmd.contextScope, .surroundingParagraphs, "\(cmd)")
        }
    }

    // MARK: - 延伸组: whole document

    func testContinueWritingInstruction() {
        XCTAssertTrue(system(.continueWriting, SelectionContext(selection: "x")).contains("续写"))
    }

    func testContinueWritingIsWholeDocument() {
        XCTAssertEqual(AICommand.continueWriting.contextScope, .wholeDocument)
    }

    func testContinueWritingSendsFullDocument() {
        let ctx = SelectionContext(
            selection: "光标处的选区。",
            paragraph: "光标处的选区。",
            fullDocument: "第一段。\n\n第二段。\n\n光标处的选区。"
        )
        let u = user(.continueWriting, ctx)
        XCTAssertTrue(u.contains("第一段。"), "续写 must carry the whole document")
        XCTAssertTrue(u.contains("第二段。"))
        XCTAssertTrue(u.contains("续写起点为全文末尾"))
    }

    func testContinueWritingFallsBackToSelectionWhenNoFullDoc() {
        let u = user(.continueWriting, SelectionContext(selection: "只有选区。"))
        XCTAssertTrue(u.contains("只有选区。"))
    }

    // MARK: - surrounding context: positions (改写组 representative = polish)

    func testPolishIncludesBeforeAndAfterParagraphs() {
        let u = user(.polish, SelectionContext(
            selection: "这是要润色的句子。",
            paragraph: "这是要润色的句子。",
            before: "前一段内容。",
            after: "后一段内容。"
        ))
        XCTAssertTrue(u.contains("前一段内容。"))
        XCTAssertTrue(u.contains("后一段内容。"))
        XCTAssertTrue(u.contains("这是要润色的句子。"))
        XCTAssertTrue(u.contains("仅供参考"))
    }

    func testLineStartSelectionNoBeforeParagraph() {
        let u = user(.polish, SelectionContext(
            selection: "开头第一段。", paragraph: "开头第一段。", before: nil, after: "第二段。"
        ))
        XCTAssertTrue(u.contains("第二段。"))
        XCTAssertTrue(u.contains("开头第一段。"))
    }

    func testDocumentEndSelectionNoAfterParagraph() {
        let u = user(.polish, SelectionContext(
            selection: "最后一段。", paragraph: "最后一段。", before: "倒数第二段。", after: nil
        ))
        XCTAssertTrue(u.contains("倒数第二段。"))
        XCTAssertTrue(u.contains("最后一段。"))
    }

    func testMidParagraphSelectionShowsOwnParagraphAsContext() {
        let u = user(.polish, SelectionContext(
            selection: "一个片段",
            paragraph: "段落开头，一个片段，段落结尾。",
            before: "前段。",
            after: "后段。"
        ))
        XCTAssertTrue(u.contains("段落开头，一个片段，段落结尾。"))
        XCTAssertTrue(u.contains("一个片段"))
    }

    func testWholeParagraphSelectionNotDuplicated() {
        let sel = "整段被选中。"
        let u = user(.polish, SelectionContext(selection: sel, paragraph: sel, before: nil, after: nil))
        let occurrences = u.components(separatedBy: sel).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testSelectionOnlyWhenNoSurroundingContext() {
        let u = user(.polish, SelectionContext(selection: "孤立的一句话。"))
        XCTAssertTrue(u.contains("孤立的一句话。"))
        XCTAssertFalse(u.contains("仅供参考"))
    }

    // MARK: - contextRange (0 / 1 / 2 / 3)

    private func multiNeighbourContext(selection: String = "中间选区。") -> SelectionContext {
        SelectionContext(
            selection: selection,
            paragraph: selection,
            beforeBlocks: ["远前段。", "中前段。", "近前段。"],   // nearest = last
            afterBlocks: ["近后段。", "中后段。", "远后段。"]      // nearest = first
        )
    }

    func testContextRangeZeroDropsAllNeighbours() {
        let u = user(.polish, multiNeighbourContext(), range: 0)
        XCTAssertFalse(u.contains("近前段。"))
        XCTAssertFalse(u.contains("近后段。"))
        XCTAssertFalse(u.contains("仅供参考"))
        XCTAssertTrue(u.contains("中间选区。"))
    }

    func testContextRangeOneTakesNearestNeighbourEachSide() {
        let u = user(.polish, multiNeighbourContext(), range: 1)
        XCTAssertTrue(u.contains("近前段。"))
        XCTAssertTrue(u.contains("近后段。"))
        XCTAssertFalse(u.contains("中前段。"))
        XCTAssertFalse(u.contains("中后段。"))
    }

    func testContextRangeTwoTakesTwoNeighboursEachSide() {
        let u = user(.polish, multiNeighbourContext(), range: 2)
        XCTAssertTrue(u.contains("近前段。"))
        XCTAssertTrue(u.contains("中前段。"))
        XCTAssertFalse(u.contains("远前段。"))
        XCTAssertTrue(u.contains("近后段。"))
        XCTAssertTrue(u.contains("中后段。"))
        XCTAssertFalse(u.contains("远后段。"))
    }

    func testContextRangeThreeTakesAllProvided() {
        let u = user(.polish, multiNeighbourContext(), range: 3)
        XCTAssertTrue(u.contains("远前段。"))
        XCTAssertTrue(u.contains("中前段。"))
        XCTAssertTrue(u.contains("近前段。"))
        XCTAssertTrue(u.contains("远后段。"))
    }

    func testNeighbourOrderingTopToBottom() {
        // before blocks then own (if distinct) then after, in document order.
        let u = user(.polish, multiNeighbourContext(), range: 3)
        let idxFar = u.range(of: "远前段。")!.lowerBound
        let idxNear = u.range(of: "近前段。")!.lowerBound
        let idxAfter = u.range(of: "近后段。")!.lowerBound
        XCTAssertTrue(idxFar < idxNear, "before blocks must keep document order")
        XCTAssertTrue(idxNear < idxAfter, "before must precede after")
    }

    func testContextRangeClampedAboveThree() {
        // Builder takes prefix/suffix; range 99 with only 3 provided = all 3.
        let u = user(.polish, multiNeighbourContext(), range: 99)
        XCTAssertTrue(u.contains("远前段。"))
    }

    func testTranslationIgnoresContextRange() {
        let u = user(.translateToEnglish, multiNeighbourContext(), range: 3)
        XCTAssertEqual(u, "中间选区。")
    }

    // MARK: - 8K auto-degrade (PRD user story 60)

    func testLongDocumentDegradesToSelectionOnly() {
        let huge = String(repeating: "上", count: 9000)
        let ctx = SelectionContext(
            selection: "短选区。",
            paragraph: "短选区。",
            beforeBlocks: [huge],
            afterBlocks: [huge]
        )
        let result = CommandPromptBuilder.build(command: .polish, context: ctx, contextRange: 1)
        XCTAssertTrue(result.didDegrade, "over-budget prompt must degrade")
        // Degraded user message is selection-only — no giant context block.
        XCTAssertFalse(result.messages.last!.content.contains(huge))
        XCTAssertTrue(result.messages.last!.content.contains("短选区。"))
    }

    func testShortDocumentDoesNotDegrade() {
        let ctx = SelectionContext(
            selection: "短选区。", paragraph: "短选区。",
            before: "前段。", after: "后段。"
        )
        let result = CommandPromptBuilder.build(command: .polish, context: ctx, contextRange: 1)
        XCTAssertFalse(result.didDegrade)
        XCTAssertTrue(result.messages.last!.content.contains("前段。"))
    }

    func testWholeDocumentDegradesWhenDocHuge() {
        let huge = String(repeating: "续", count: 9000)
        let ctx = SelectionContext(selection: "选区。", paragraph: "选区。", fullDocument: huge)
        let result = CommandPromptBuilder.build(command: .continueWriting, context: ctx)
        XCTAssertTrue(result.didDegrade)
        XCTAssertFalse(result.messages.last!.content.contains(huge))
        XCTAssertTrue(result.messages.last!.content.contains("选区。"))
    }

    func testTranslationNeverDegradesEvenWithHugeNeighbours() {
        // Selection-only scope can't degrade further — flag stays false.
        let huge = String(repeating: "x", count: 9000)
        let ctx = SelectionContext(selection: "翻译我。", paragraph: "翻译我。", beforeBlocks: [huge])
        let result = CommandPromptBuilder.build(command: .translateToEnglish, context: ctx)
        XCTAssertFalse(result.didDegrade)
        XCTAssertEqual(result.messages.last!.content, "翻译我。")
    }

    func testDegradeBoundaryRebuildOmitsContextMarker() {
        let huge = String(repeating: "字", count: 9000)
        let ctx = SelectionContext(selection: "目标。", paragraph: "目标。", beforeBlocks: [huge])
        let result = CommandPromptBuilder.build(command: .summarize, context: ctx)
        XCTAssertTrue(result.didDegrade)
        XCTAssertFalse(result.messages.last!.content.contains("仅供参考"))
    }

    // MARK: - 生成组 (slash commands, S6) — inputOnly scope

    func testWriteOutlineEmbedsTopicAndIsInputOnly() {
        let cmd = AICommand.writeOutline(topic: "团队周报")
        XCTAssertEqual(cmd.contextScope, .inputOnly)
        XCTAssertTrue(system(cmd, SelectionContext(selection: "团队周报")).contains("团队周报"))
        XCTAssertTrue(system(cmd, SelectionContext(selection: "x")).contains("大纲"))
    }

    func testExpandTopicEmbedsTopicAndIsInputOnly() {
        let cmd = AICommand.expandTopic(topic: "远程协作")
        XCTAssertEqual(cmd.contextScope, .inputOnly)
        XCTAssertTrue(system(cmd, SelectionContext(selection: "远程协作")).contains("远程协作"))
    }

    func testFreePromptIsInputOnly() {
        XCTAssertEqual(AICommand.freePrompt(prompt: "写一首五言绝句").contextScope, .inputOnly)
    }

    func testInputOnlySendsOnlyTheTypedInputNoDocument() {
        // The typed topic rides in `selection`; neighbours / fullDocument are
        // ignored entirely (PRD user story 59: 生成 = 仅输入).
        let ctx = SelectionContext(
            selection: "会议纪要",
            paragraph: "不该出现的段落。",
            beforeBlocks: ["前段不该出现。"],
            afterBlocks: ["后段不该出现。"],
            fullDocument: "整篇不该出现。"
        )
        let u = user(.writeOutline(topic: "会议纪要"), ctx)
        XCTAssertEqual(u, "会议纪要")
        XCTAssertFalse(u.contains("不该出现"))
    }

    func testGenerateInputAccessor() {
        XCTAssertEqual(AICommand.writeOutline(topic: "A").generateInput, "A")
        XCTAssertEqual(AICommand.expandTopic(topic: "B").generateInput, "B")
        XCTAssertEqual(AICommand.freePrompt(prompt: "C").generateInput, "C")
        XCTAssertNil(AICommand.polish.generateInput)
    }

    func testInputOnlyNeverDegradesEvenWithHugeInput() {
        let huge = String(repeating: "题", count: 9000)
        let ctx = SelectionContext(selection: huge)
        let result = CommandPromptBuilder.build(command: .writeOutline(topic: huge), context: ctx)
        XCTAssertFalse(result.didDegrade, "inputOnly has nothing to strip — never degrades")
    }

    // MARK: - SelectionContext convenience init parity

    func testConvenienceInitMatchesArrayInit() {
        let a = SelectionContext(selection: "s", paragraph: "p", before: "b", after: "a")
        let b = SelectionContext(selection: "s", paragraph: "p", beforeBlocks: ["b"], afterBlocks: ["a"])
        XCTAssertEqual(a, b)
    }

    func testConvenienceInitNilNeighboursGivesEmptyArrays() {
        let a = SelectionContext(selection: "s", paragraph: "p", before: nil, after: nil)
        XCTAssertEqual(a.beforeBlocks, [])
        XCTAssertEqual(a.afterBlocks, [])
    }

    // MARK: - fixtures

    /// All non-parameterized + sample parameterized commands, for sweep tests.
    private static let allCommands: [AICommand] = [
        .polish, .formal, .colloquial, .simplify, .customRewrite(intent: "更生动"),
        .translateToEnglish, .translateToChinese, .translateTo(language: "法文"),
        .summarize, .expand, .outline, .toTable,
        .continueWriting,
    ]
}
