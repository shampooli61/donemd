import type { Editor } from '@tiptap/core';

/**
 * Phase 2 selection bubble menu — 11 actions in three groups:
 *
 *   format      [B] [I] [S̶] [</>] [🔗]
 *   block       [清除] [引用] [代码块] [无序] [有序]
 *   container   [高亮块]
 *
 * Block-convert actions (the middle group) operate on the *whole block*
 * containing the selection — Tiptap's toggleBlockquote / toggleCodeBlock
 * / toggleBulletList / toggleOrderedList already do this, so even when
 * the user has only a few characters selected, the entire surrounding
 * paragraph flips. The container group (currently just 「高亮块」) wraps
 * the cursor's paragraph in a callout of the default type (note); type
 * switching happens via the NodeView icon picker.
 *
 * The DOM has to exist before the Editor is constructed (BubbleMenu's
 * `configure({ element })` requires it), so this module produces the
 * element synchronously and exposes an `attach()` hook to wire button
 * actions and active-state syncing once the Editor is alive.
 */

type ButtonHandler = (editor: Editor) => void;
type IsActiveQuery = (editor: Editor) => boolean;

interface BubbleButton {
  cmd: string;
  label: string;
  tooltip: string;
  action: ButtonHandler;
  isActive?: IsActiveQuery;
}

const FORMAT_BUTTONS: BubbleButton[] = [
  {
    cmd: 'bold',
    label: 'B',
    tooltip: '加粗 (Cmd+B)',
    action: (e) => e.chain().focus().toggleBold().run(),
    isActive: (e) => e.isActive('bold'),
  },
  {
    cmd: 'italic',
    label: 'I',
    tooltip: '斜体 (Cmd+I)',
    action: (e) => e.chain().focus().toggleItalic().run(),
    isActive: (e) => e.isActive('italic'),
  },
  {
    cmd: 'strike',
    label: 'S̶',
    tooltip: '删除线 (Cmd+Shift+X)',
    action: (e) => e.chain().focus().toggleStrike().run(),
    isActive: (e) => e.isActive('strike'),
  },
  {
    cmd: 'code',
    label: '</>',
    tooltip: '行内代码 (Cmd+E)',
    action: (e) => e.chain().focus().toggleCode().run(),
    isActive: (e) => e.isActive('code'),
  },
  {
    cmd: 'link',
    label: '🔗',
    tooltip: '链接 (Cmd+K)',
    // Wired by attach() — needs access to the link prompt helper.
    action: () => {},
    isActive: (e) => e.isActive('link'),
  },
];

const BLOCK_BUTTONS: BubbleButton[] = [
  {
    cmd: 'clear',
    label: '清除',
    tooltip: '清除格式 (Cmd+\\)',
    action: (e) => e.chain().focus().clearNodes().unsetAllMarks().run(),
  },
  {
    cmd: 'blockquote',
    label: '引用',
    tooltip: '引用 (Cmd+Shift+B)',
    action: (e) => e.chain().focus().toggleBlockquote().run(),
    isActive: (e) => e.isActive('blockquote'),
  },
  {
    cmd: 'codeBlock',
    label: '代码块',
    tooltip: '代码块 (Cmd+Option+C)',
    // Merge-aware: a multi-line selection becomes ONE code block, not one per
    // paragraph (see setMergedCodeBlock in mermaid-codeblock.ts).
    action: (e) => e.chain().focus().setMergedCodeBlock().run(),
    isActive: (e) => e.isActive('codeBlock'),
  },
  {
    cmd: 'bulletList',
    label: '无序',
    tooltip: '无序列表 (Cmd+Shift+8)',
    action: (e) => e.chain().focus().toggleBulletList().run(),
    isActive: (e) => e.isActive('bulletList'),
  },
  {
    cmd: 'orderedList',
    label: '有序',
    tooltip: '有序列表 (Cmd+Shift+7)',
    action: (e) => e.chain().focus().toggleOrderedList().run(),
    isActive: (e) => e.isActive('orderedList'),
  },
  {
    // Task list (checkbox list). Reached from the 格式 menu via the
    // formatCommand bridge — same action map as the floater. TaskList/TaskItem
    // are already registered in main.ts, so toggleTaskList is available.
    cmd: 'taskList',
    label: '任务列表',
    tooltip: '任务列表',
    action: (e) => e.chain().focus().toggleTaskList().run(),
    isActive: (e) => e.isActive('taskList'),
  },
];

const CONTAINER_BUTTONS: BubbleButton[] = [
  {
    cmd: 'callout',
    label: '高亮块',
    tooltip: '转高亮块（默认 note，转后可点图标换类型）',
    // wrapIn picks the nearest matching wrappable block and uses its
    // existing content — selecting a few words inside a paragraph still
    // wraps the *entire* paragraph, matching the issue's acceptance:
    // "选中部分文字点「转 callout」→ 整段被转为 callout".
    action: (e) => e.chain().focus().wrapIn('callout', { type: 'note' }).run(),
    isActive: (e) => e.isActive('callout'),
  },
];

const ALL_BUTTONS = [...FORMAT_BUTTONS, ...BLOCK_BUTTONS, ...CONTAINER_BUTTONS];

/** Run a format command by its `cmd` name — the SAME action the bubble button
 *  would run. This is the single source of truth shared by two entry points:
 *  the selection floater's buttons (mouse path) and the native 格式 menu, which
 *  reaches here via Swift's `formatCommand` bridge message (menu / shortcut
 *  path). Keeping one action map means the menu and the floater can never drift
 *  apart in behavior.
 *
 *  `link` is special-cased: its action lives in main.ts (the interactive link
 *  prompt), so callers pass it in. Every other cmd is self-contained. */
export function runFormatCommand(
  editor: Editor,
  cmd: string,
  insertLink: (editor: Editor) => void
): void {
  if (cmd === 'link') {
    insertLink(editor);
    return;
  }
  const button = ALL_BUTTONS.find((b) => b.cmd === cmd);
  if (button) {
    button.action(editor);
  } else {
    console.warn('[format] unknown command:', cmd);
  }
}

/** Phase 3 #63/#65: an AI command the "AI ▾" dropdown can launch. The launcher
 *  (injected at attach) extracts the selection + context and ships it to Swift.
 *
 *  `arg` carries the free-text parameter for the two parameterized commands:
 *  customRewrite (rewrite intent) and translateTo (target language). For every
 *  other command it's absent — the kind alone maps to a fixed Swift prompt. */
export interface AICommandItem {
  kind: string;
  label: string;
  arg?: string;
}

/** A command entry in the dropdown. `prompt` marks the two commands that pop a
 *  mini input before launching (自定义改写 / 翻译为…). */
export interface AICommandSpec {
  kind: string;
  label: string;
  /** Pop a free-text input ('rewrite') or a language popover ('language')
   *  before dispatching. Absent → launch immediately. */
  prompt?: 'rewrite' | 'language';
}

export interface AICommandGroup {
  title: string;
  items: AICommandSpec[];
}

/** The 13 built-in commands, 4 groups (PRD § 13 条内置命令). The 5th group
 *  「我的命令」([[自定义命令]]) lands in S9.
 *
 *  Exported so the ⌘/ panel (slash-menu.ts) can offer the SAME transform set
 *  when there's a selection — the bubble's "AI ▾" is the mouse path, ⌘/ is the
 *  keyboard path, both onto one command catalog (#69 双路径冗余). */
export const AI_GROUPS: AICommandGroup[] = [
  {
    title: '改写',
    items: [
      { kind: 'polish', label: '润色' },
      { kind: 'formal', label: '改正式' },
      { kind: 'colloquial', label: '改口语化' },
      { kind: 'simplify', label: '简化' },
      { kind: 'customRewrite', label: '自定义改写…', prompt: 'rewrite' },
    ],
  },
  {
    title: '翻译',
    items: [
      { kind: 'translateToEnglish', label: '翻译为英文' },
      { kind: 'translateToChinese', label: '翻译为中文' },
      { kind: 'translateTo', label: '翻译为…', prompt: 'language' },
    ],
  },
  {
    title: '转换',
    items: [
      { kind: 'summarize', label: '总结' },
      { kind: 'expand', label: '扩写' },
      { kind: 'outline', label: '列大纲' },
      { kind: 'toTable', label: '转表格' },
    ],
  },
  {
    title: '延伸',
    items: [{ kind: 'continueWriting', label: '续写' }],
  },
];

/** Common target languages for the「翻译为…」popover. Custom entry is free-text
 *  and not persisted (PRD acceptance). Exported so the ⌘/ keyboard path offers
 *  the same chips (#69). */
export const TRANSLATE_LANGUAGES = ['日文', '韩文', '法文', '西班牙文'];

export interface BubbleHandle {
  element: HTMLElement;
  attach(
    editor: Editor,
    insertLink: (editor: Editor) => void,
    launchAI?: (editor: Editor, command: AICommandItem) => void
  ): void;
}

/** Build the bubble's DOM tree synchronously. The Editor isn't available
 *  yet — handlers and active-state sync are wired in `attach()`. */
export function createBubbleMenu(): BubbleHandle {
  const root = document.createElement('div');
  root.className = 'donemd-bubble';
  // Hidden until the editor has a non-empty selection — Tiptap's BubbleMenu
  // extension toggles this on/off via shouldShow.
  root.style.visibility = 'hidden';

  const buttonRefs = new Map<string, HTMLButtonElement>();

  const buildGroup = (buttons: BubbleButton[]): void => {
    for (const b of buttons) {
      const el = document.createElement('button');
      el.type = 'button';
      el.className = 'donemd-bubble__btn';
      el.textContent = b.label;
      el.title = b.tooltip;
      el.setAttribute('aria-label', b.tooltip);
      // Don't steal focus from the editor on mousedown — otherwise the
      // selection collapses before the click handler runs.
      el.addEventListener('mousedown', (e) => e.preventDefault());
      buttonRefs.set(b.cmd, el);
      root.appendChild(el);
    }
  };

  const addDivider = (): void => {
    const divider = document.createElement('span');
    divider.className = 'donemd-bubble__divider';
    divider.setAttribute('aria-hidden', 'true');
    root.appendChild(divider);
  };

  buildGroup(FORMAT_BUTTONS);
  addDivider();
  buildGroup(BLOCK_BUTTONS);
  addDivider();
  buildGroup(CONTAINER_BUTTONS);

  // Phase 3 #63: "AI ▾" dropdown. Custom DOM (the other buttons are plain
  // <button>s; this one toggles a popover of AI commands).
  addDivider();
  const aiButton = document.createElement('button');
  aiButton.type = 'button';
  aiButton.className = 'donemd-bubble__btn donemd-bubble__ai';
  aiButton.textContent = 'AI ▾';
  aiButton.title = 'AI 助手';
  aiButton.setAttribute('aria-label', 'AI 助手');
  aiButton.addEventListener('mousedown', (e) => e.preventDefault());

  // Grouped dropdown: a title row + item rows per group, dividers between.
  // Items that need a parameter (自定义改写 / 翻译为…) open a sub-input layer
  // instead of dispatching directly; that layer is built lazily in attach().
  const aiMenu = document.createElement('div');
  aiMenu.className = 'donemd-bubble__ai-menu';
  aiMenu.style.display = 'none';
  AI_GROUPS.forEach((group, gi) => {
    if (gi > 0) {
      const sep = document.createElement('div');
      sep.className = 'donemd-bubble__ai-sep';
      sep.setAttribute('aria-hidden', 'true');
      aiMenu.appendChild(sep);
    }
    const title = document.createElement('div');
    title.className = 'donemd-bubble__ai-group';
    title.textContent = group.title;
    aiMenu.appendChild(title);
    for (const cmd of group.items) {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'donemd-bubble__ai-item';
      item.textContent = cmd.label;
      item.dataset.kind = cmd.kind;
      if (cmd.prompt) item.dataset.prompt = cmd.prompt;
      item.addEventListener('mousedown', (e) => e.preventDefault());
      aiMenu.appendChild(item);
    }
  });

  // Footer hint (PRD user story 55): tell mouse users the AI commands also
  // have a keyboard entry (⌘/). A single overall hint — NOT a per-item badge,
  // since ⌘/ with a selection surfaces only the 6-command transform subset,
  // not this full 13-command floater; badging each would mislead.
  const aiHint = document.createElement('div');
  aiHint.className = 'donemd-bubble__ai-hint';
  aiHint.textContent = '⌘/ 用键盘唤起';
  aiHint.setAttribute('aria-hidden', 'true');
  aiMenu.appendChild(aiHint);

  // Sub-layer for parameterized commands: a labelled text input (自定义改写)
  // or a list of language chips + custom input (翻译为…). Hidden by default.
  const aiSub = document.createElement('div');
  aiSub.className = 'donemd-bubble__ai-sub';
  aiSub.style.display = 'none';
  aiMenu.appendChild(aiSub);

  root.appendChild(aiButton);
  root.appendChild(aiMenu);

  const flatItems: AICommandSpec[] = AI_GROUPS.flatMap((g) => g.items);

  return {
    element: root,
    attach(editor, insertLink, launchAI) {
      const closeAIMenu = () => {
        aiMenu.style.display = 'none';
        aiSub.style.display = 'none';
        aiSub.replaceChildren();
      };
      const dispatch = (kind: string, arg?: string) => {
        closeAIMenu();
        const spec = flatItems.find((c) => c.kind === kind);
        const label = spec?.label ?? kind;
        if (launchAI) launchAI(editor, { kind, label, ...(arg ? { arg } : {}) });
      };

      // Render the「自定义改写…」input: a single text field, Enter sends, Esc closes.
      const showRewriteInput = (): void => {
        aiSub.replaceChildren();
        aiSub.style.display = 'flex';
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'donemd-bubble__ai-input';
        input.placeholder = '请描述改写意图';
        input.addEventListener('mousedown', (e) => e.stopPropagation());
        input.addEventListener('keydown', (e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            const v = input.value.trim();
            if (v) dispatch('customRewrite', v);
          } else if (e.key === 'Escape') {
            e.preventDefault();
            closeAIMenu();
          }
        });
        aiSub.appendChild(input);
        input.focus();
      };

      // Render the「翻译为…」popover: common-language chips + a free-text input.
      const showLanguagePopover = (): void => {
        aiSub.replaceChildren();
        aiSub.style.display = 'flex';
        for (const lang of TRANSLATE_LANGUAGES) {
          const chip = document.createElement('button');
          chip.type = 'button';
          chip.className = 'donemd-bubble__ai-item';
          chip.textContent = lang;
          chip.addEventListener('mousedown', (e) => e.preventDefault());
          chip.addEventListener('click', (e) => {
            e.preventDefault();
            dispatch('translateTo', lang);
          });
          aiSub.appendChild(chip);
        }
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'donemd-bubble__ai-input';
        input.placeholder = '其它语种…';
        input.addEventListener('mousedown', (e) => e.stopPropagation());
        input.addEventListener('keydown', (e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            const v = input.value.trim();
            if (v) dispatch('translateTo', v);
          } else if (e.key === 'Escape') {
            e.preventDefault();
            closeAIMenu();
          }
        });
        aiSub.appendChild(input);
      };

      aiButton.addEventListener('click', (e) => {
        e.preventDefault();
        if (aiMenu.style.display === 'none') {
          aiSub.style.display = 'none';
          aiSub.replaceChildren();
          aiMenu.style.display = 'flex';
        } else {
          closeAIMenu();
        }
      });

      for (const item of Array.from(aiMenu.querySelectorAll('.donemd-bubble__ai-item')) as HTMLButtonElement[]) {
        // Skip the language chips inside aiSub (wired in showLanguagePopover).
        if (item.parentElement === aiSub) continue;
        item.addEventListener('click', (e) => {
          e.preventDefault();
          const kind = item.dataset.kind ?? 'polish';
          const promptKind = item.dataset.prompt;
          if (promptKind === 'rewrite') { showRewriteInput(); return; }
          if (promptKind === 'language') { showLanguagePopover(); return; }
          dispatch(kind);
        });
      }
      // Collapse the menu whenever the selection changes (bubble may hide).
      editor.on('selectionUpdate', closeAIMenu);

      // Wire click handlers now that we have the editor reference.
      for (const b of ALL_BUTTONS) {
        const el = buttonRefs.get(b.cmd);
        if (!el) continue;
        const handler =
          b.cmd === 'link' ? () => insertLink(editor) : () => b.action(editor);
        el.addEventListener('click', (e) => {
          e.preventDefault();
          handler();
        });
      }

      // Highlight buttons whose mark / node is currently active so users
      // see the toggle state at a glance.
      const refresh = (): void => {
        for (const b of ALL_BUTTONS) {
          const el = buttonRefs.get(b.cmd);
          if (!el) continue;
          const active = b.isActive ? b.isActive(editor) : false;
          el.classList.toggle('is-active', active);
        }
      };
      editor.on('selectionUpdate', refresh);
      editor.on('transaction', refresh);
      refresh();
    },
  };
}
