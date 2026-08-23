import Foundation

/// An [[AI 助手]] command — the unit M3 turns into a prompt. S2 (#63) shipped
/// only `.polish`; S4 (#65) fills the full 13-command set across 5 groups
/// (改写 / 翻译 / 转换 / 延伸 / 我的命令). Each case carries its own
/// [[Context 窗口]] scope so the builder doesn't branch on an external table.
///
/// The 5th group「我的命令」([[自定义命令]]) lands in S9 — not here.
public enum AICommand: Equatable {

    // MARK: 改写组 (rewrite)

    /// 润色 — improve fluency without changing meaning. Default short-press
    /// ⌘/ action (PRD user story 4).
    case polish
    /// 改正式 — rewrite into formal written register.
    case formal
    /// 改口语化 — rewrite into everyday spoken register.
    case colloquial
    /// 简化 — trim while keeping the key points.
    case simplify
    /// 自定义改写 — the user types a rewrite intent in a mini input; that
    /// intent becomes the instruction (PRD § 13 条命令: "用户输入的改写意图 + 选区").
    case customRewrite(intent: String)

    // MARK: 翻译组 (translate)

    /// 翻译为英文.
    case translateToEnglish
    /// 翻译为中文.
    case translateToChinese
    /// 翻译为… — target language picked from a popover (日 / 韩 / 法 / 西 /
    /// 自定义). The language string is not persisted.
    case translateTo(language: String)

    // MARK: 转换组 (transform)

    /// 总结 — summarize the key points in 1-3 sentences.
    case summarize
    /// 扩写 — expand on the original.
    case expand
    /// 列大纲 — extract key points into a markdown outline.
    case outline
    /// 转表格 — produce a markdown table when the content suits one;
    /// otherwise say it's not suitable (PRD acceptance: don't force a table).
    case toTable

    // MARK: 延伸组 (continue)

    /// 续写 — naturally continue from the text. Uses [[续写插入]] landing
    /// (S5); S4 only ships the dispatch path + 整篇文档 context.
    case continueWriting

    // MARK: 生成组 (slash-command generate, S6) — [[生成插入]] landing.
    // Context = input only: these start from a blank cursor, the user-typed
    // topic / prompt IS the whole input, no document context travels.

    /// 写大纲 — generate a markdown outline for a user-typed topic.
    case writeOutline(topic: String)
    /// 扩写主题 — expand a user-typed topic into paragraphs.
    case expandTopic(topic: String)
    /// 自由 prompt — send the user's raw prompt verbatim. The only command
    /// whose slash entry also exposes a [[Provider]] override dropdown.
    case freePrompt(prompt: String)

    /// The Chinese instruction sent to the [[Provider]] as the `system`
    /// message (PRD § 13 条内置命令 Prompt 草案). Built-in prompts are fixed —
    /// user customization goes through [[自定义命令]] (S9), not by editing these.
    ///
    /// Most carry an anti-preamble tail so DeepSeek et al. don't prepend
    /// "以下是…" boilerplate that would land inside the document on replace.
    var instruction: String {
        // Reused tail — keep the model from wrapping its output in chatter.
        let direct = "直接输出结果，不要任何前后说明。"
        switch self {
        case .polish:
            return "在不改变原意的前提下，让以下文本更自然流畅。" + direct
        case .formal:
            return "将以下文本改写为正式书面语。" + direct
        case .colloquial:
            return "将以下文本改写为日常口语。" + direct
        case .simplify:
            return "在保留要点的前提下精简以下文本。" + direct
        case .customRewrite(let intent):
            // The user's intent is the instruction. We still fence it with the
            // anti-preamble so the output is drop-in.
            return "请按以下要求改写文本：\(intent)。" + direct
        case .translateToEnglish:
            return "将以下文本翻译为英文，保留原有的 Markdown 结构。" + direct
        case .translateToChinese:
            return "将以下文本翻译为中文，保留原有的 Markdown 结构。" + direct
        case .translateTo(let language):
            return "将以下文本翻译为\(language)，保留原有的 Markdown 结构。" + direct
        case .summarize:
            return "用 1-3 句话总结以下文本的要点。" + direct
        case .expand:
            return "在以下文本的基础上展开补充，使内容更充实。" + direct
        case .outline:
            return "提取以下文本的要点，列为 Markdown 大纲。" + direct
        case .toTable:
            // Deliberately *not* using the strict anti-preamble: the command
            // must be able to say "不适合" instead of forcing a table.
            return "如果以下内容适合表格化，输出一个 Markdown 表格；否则只回复「不适合」。不要任何额外说明。"
        case .continueWriting:
            return "基于以下文本，自然地续写一段。" + direct
        case .writeOutline(let topic):
            return "请围绕「\(topic)」生成一个 Markdown 大纲。" + direct
        case .expandTopic(let topic):
            return "请围绕「\(topic)」展开写成段落。" + direct
        case .freePrompt:
            // The user's prompt is the whole instruction; it rides in the user
            // message, so the system message just sets the drop-in constraint.
            return "请完成用户的要求。" + direct
        }
    }

    /// [[Context 窗口]] scope for this command (PRD user story 56-59).
    var contextScope: ContextScope {
        switch self {
        case .polish, .formal, .colloquial, .simplify, .customRewrite,
             .summarize, .expand, .outline, .toTable:
            // 改写 / 转换 — surrounding paragraphs for style consistency
            // and reference disambiguation.
            return .surroundingParagraphs
        case .translateToEnglish, .translateToChinese, .translateTo:
            // 翻译 — selection only. Extra context introduces "它/this"
            // referent mismatch in the translation (PRD user story 57).
            return .selectionOnly
        case .continueWriting:
            // 续写 — needs whole-document voice / terminology (user story 58).
            return .wholeDocument
        case .writeOutline, .expandTopic, .freePrompt:
            // 生成 — from a blank cursor; only the user's typed input matters,
            // no document context (PRD user story 59).
            return .inputOnly
        }
    }

    /// The user-typed input for the parameterized generate commands — the only
    /// content `.inputOnly` sends. nil for the non-generate commands.
    var generateInput: String? {
        switch self {
        case .writeOutline(let topic), .expandTopic(let topic):
            return topic
        case .freePrompt(let prompt):
            return prompt
        default:
            return nil
        }
    }
}

/// How much document context travels with the selection (PRD § Context 窗口).
public enum ContextScope: Equatable {
    /// Only the selected text (翻译类). No surrounding context.
    case selectionOnly
    /// Selection paragraph + N paragraphs before/after (改写 / 转换), where N
    /// is the user's `ai.contextRange` (0/1/2/3, default 1).
    case surroundingParagraphs
    /// The whole document (续写).
    case wholeDocument
    /// Only the user-typed input ([[斜杠命令]] 生成类). No document context at
    /// all — the selection field carries the typed topic / prompt.
    case inputOnly
}

/// The editor-side context M3 needs to build a prompt. The JS bubble menu
/// extracts these plain strings from the live ProseMirror selection (there's
/// no Swift-side selection accessor) and sends them across the bridge — so
/// M3 stays a pure function over strings, fully unit-testable.
public struct SelectionContext: Equatable {
    /// The exact selected text the user highlighted — the transform target.
    public let selection: String
    /// The paragraph (block) the selection sits in. May equal `selection`
    /// when the whole paragraph is selected; may be empty if unavailable.
    public let paragraph: String
    /// Blocks before `paragraph`, in document order (top → bottom), so the
    /// block immediately preceding the selection is `beforeBlocks.last`. JS
    /// supplies up to 3; `build()` slices to the active `contextRange`.
    public let beforeBlocks: [String]
    /// Blocks after `paragraph`, in document order, so the block immediately
    /// following the selection is `afterBlocks.first`.
    public let afterBlocks: [String]
    /// Full document markdown — only consulted for `.wholeDocument` scope.
    public let fullDocument: String?

    public init(
        selection: String,
        paragraph: String = "",
        beforeBlocks: [String] = [],
        afterBlocks: [String] = [],
        fullDocument: String? = nil
    ) {
        self.selection = selection
        self.paragraph = paragraph
        self.beforeBlocks = beforeBlocks
        self.afterBlocks = afterBlocks
        self.fullDocument = fullDocument
    }

    /// Convenience for the common single-neighbour case (and the S2 tests):
    /// one block before, one after.
    public init(
        selection: String,
        paragraph: String,
        before: String?,
        after: String? = nil,
        fullDocument: String? = nil
    ) {
        self.init(
            selection: selection,
            paragraph: paragraph,
            beforeBlocks: before.map { [$0] } ?? [],
            afterBlocks: after.map { [$0] } ?? [],
            fullDocument: fullDocument
        )
    }
}

/// The output of M3: the chat messages plus whether the 8K guard kicked in.
public struct PromptBuildResult: Equatable {
    public let messages: [AIMessage]
    /// True when the prompt exceeded the 8K budget and was rebuilt as
    /// selection-only — M4/JS surfaces the「文档过长，已切换为仅选区调用」toast.
    public let didDegrade: Bool

    public init(messages: [AIMessage], didDegrade: Bool) {
        self.messages = messages
        self.didDegrade = didDegrade
    }
}

/// M3 — **pure function, no side effects**. Composes `command + selection +
/// context` into the final prompt messages handed to the [[Provider]].
public enum CommandPromptBuilder {

    /// Soft ceiling on total prompt size (PRD user story 60). Past this, the
    /// prompt is rebuilt selection-only so a long document can't blow up token
    /// usage / first-token latency.
    public static let tokenBudget = 8000

    /// Build the chat messages for a command over a selection context.
    ///
    /// Shape: one `system` message carrying the command instruction, one
    /// `user` message carrying the context-framed selection. Splitting
    /// instruction (system) from content (user) keeps the model from echoing
    /// the instruction back and matches every OpenAI-compatible / Anthropic
    /// chat convention.
    ///
    /// - Parameter contextRange: how many paragraphs before/after to include
    ///   for `.surroundingParagraphs` scope (0/1/2/3, the user's
    ///   `ai.contextRange`). Ignored by `.selectionOnly` / `.wholeDocument`.
    public static func build(
        command: AICommand,
        context: SelectionContext,
        contextRange: Int = 1
    ) -> PromptBuildResult {
        let system = command.instruction
        let user = userMessage(scope: command.contextScope, context: context, contextRange: contextRange)

        // 8K guard: if the full prompt is over budget and we included more than
        // the bare selection, rebuild selection-only and flag the degrade.
        // .selectionOnly / .inputOnly have nothing to strip — never degrade.
        if command.contextScope != .selectionOnly,
           command.contextScope != .inputOnly,
           estimatedTokens(system: system, user: user) > tokenBudget {
            let degraded = userMessage(scope: .selectionOnly, context: context, contextRange: contextRange)
            return PromptBuildResult(
                messages: [AIMessage(role: .system, content: system),
                           AIMessage(role: .user, content: degraded)],
                didDegrade: true
            )
        }

        return PromptBuildResult(
            messages: [AIMessage(role: .system, content: system),
                       AIMessage(role: .user, content: user)],
            didDegrade: false
        )
    }

    // MARK: - User message framing

    /// Frame the selection with whatever context the scope calls for. The
    /// selection is always fenced with an explicit marker so the model knows
    /// precisely what to transform even when surrounding context is included —
    /// context is for disambiguation / style, not for rewriting.
    private static func userMessage(
        scope: ContextScope,
        context: SelectionContext,
        contextRange: Int
    ) -> String {
        switch scope {
        case .selectionOnly, .inputOnly:
            // inputOnly: the typed topic / prompt rides in `selection` (JS sends
            // it there). Same framing as selectionOnly — just the bare text.
            return context.selection

        case .surroundingParagraphs:
            // Take the nearest `contextRange` neighbours on each side: the last
            // N before (nearest is last) and the first N after (nearest is
            // first). contextRange == 0 → no neighbours, just the own paragraph.
            let n = max(0, contextRange)
            let before = n == 0 ? [] : Array(context.beforeBlocks.suffix(n))
            let after = n == 0 ? [] : Array(context.afterBlocks.prefix(n))

            var reference: [String] = []
            reference.append(contentsOf: before.filter { !$0.isEmpty })
            if !context.paragraph.isEmpty, context.paragraph != context.selection {
                reference.append(context.paragraph)
            }
            reference.append(contentsOf: after.filter { !$0.isEmpty })

            var parts: [String] = []
            if !reference.isEmpty {
                parts.append("上下文（仅供参考，不要改写）：")
                parts.append(contentsOf: reference)
                parts.append("")  // blank line before the target
            }
            parts.append("需要处理的文本：")
            parts.append(context.selection)
            return parts.joined(separator: "\n")

        case .wholeDocument:
            // 续写 sends the whole doc as voice context. Fall back to the
            // selection if no full doc was provided.
            let doc = context.fullDocument ?? context.selection
            return "全文：\n\(doc)\n\n续写起点为全文末尾。"
        }
    }

    // MARK: - Token estimate

    /// Conservative estimate: ~1 token per character. Chinese is ~1 char/token
    /// and English is fewer tokens than chars, so counting characters
    /// over-estimates — exactly the bias we want for a *safety* ceiling.
    static func estimatedTokens(system: String, user: String) -> Int {
        system.count + user.count
    }
}
