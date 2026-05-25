import {Compartment, EditorState, Prec, RangeSetBuilder} from "@codemirror/state";
import {EditorView, Decoration, ViewPlugin, WidgetType, keymap, placeholder} from "@codemirror/view";
import {autocompletion, startCompletion} from "@codemirror/autocomplete";
import {defaultKeymap, history, historyKeymap} from "@codemirror/commands";
import {markdown} from "@codemirror/lang-markdown";
import {syntaxHighlighting, HighlightStyle} from "@codemirror/language";
import {tags} from "@lezer/highlight";
import MarkdownIt from "markdown-it";

const standaloneFixtures = {
  "full-markdown": `# Meeting Notes

This paragraph checks **bold**, *italic*, ***bold italic***, \`inline code\`, ~~strikethrough~~, a [[Michelle]] wikilink, and @amy plus @Neal person mentions.

Use bracketed mentions for full names like @[Amy Williams], typed people like @person[Amy Williams], and projects like @project[Q3 Launch].

## Decisions

- Ship the local editor bundle.
- Keep Markdown as the source of truth.
- Validate dark and light mode.

### Checklist

- [x] Record audio locally
- [ ] Link a note to a recording
- [ ] Insert a context citation

> Speaker 1: This blockquote should remain readable and selectable.

1. First ordered item
2. Second ordered item
3. Third ordered item

\`\`\`swift
let sourceOfTruth = "Markdown"
print(sourceOfTruth)
\`\`\`

| Field | Expected |
| --- | --- |
| Storage | Markdown |
| Editor | CodeMirror 6 |
| Mode | Live Preview |

---

\`\`\`harc-context
recording: recording:42
timecode: 00:03:42
speaker: Michelle
quote: "We should keep the notes tied to the recording."
\`\`\`

[Harc repo](https://github.com/jkrack/Harc)`,
};

const initialDoc = (() => {
  const fixture = new URLSearchParams(location.search).get("fixture");
  return standaloneFixtures[fixture] ?? "# Title\n\nStart writing in Markdown.";
})();

const standaloneMentionTargets = {
  "full-markdown": [
    {label: "Amy Williams", kind: "person", detail: "Person"},
    {label: "Neal Patel", kind: "person", detail: "Person"},
    {label: "Michelle", kind: "person", detail: "Person"},
    {label: "Q3 Launch", kind: "project", detail: "Project"},
  ],
};

const postChange = (text) => {
  window.webkit?.messageHandlers?.harc?.postMessage({type: "change", text});
};

let linkTargets = [];
let mentionTargets = standaloneMentionTargets[
  new URLSearchParams(location.search).get("fixture")
] ?? [];
let attachmentBaseURL = "";

const markdownHighlight = HighlightStyle.define([
  {tag: tags.heading1, class: "cm-md-heading-token"},
  {tag: tags.processingInstruction, class: "cm-md-syntax-muted"},
  {tag: tags.monospace, class: "cm-inline-code"},
  {tag: tags.link, class: "cm-wikilink"},
]);

function lineHasSelection(view, line) {
  return view.state.selection.ranges.some((range) => {
    return range.from <= line.to && range.to >= line.from;
  });
}

class TaskCheckboxWidget extends WidgetType {
  constructor(checked) {
    super();
    this.checked = checked;
  }

  eq(other) {
    return other.checked === this.checked;
  }

  toDOM() {
    const checkbox = document.createElement("span");
    checkbox.className = `cm-md-task-checkbox ${this.checked ? "is-checked" : ""}`;
    checkbox.setAttribute("aria-hidden", "true");
    checkbox.textContent = this.checked ? "x" : "";
    return checkbox;
  }
}

class ListMarkerWidget extends WidgetType {
  constructor(text, kind) {
    super();
    this.text = text;
    this.kind = kind;
  }

  eq(other) {
    return other.text === this.text && other.kind === this.kind;
  }

  toDOM() {
    const marker = document.createElement("span");
    marker.className = `cm-md-list-marker cm-md-list-marker-${this.kind}`;
    marker.setAttribute("aria-hidden", "true");
    marker.textContent = this.text;
    return marker;
  }
}

class ImageAttachmentWidget extends WidgetType {
  constructor(alt, path) {
    super();
    this.alt = alt;
    this.path = path;
  }

  eq(other) {
    return other.alt === this.alt && other.path === this.path;
  }

  toDOM() {
    const figure = document.createElement("figure");
    figure.className = "cm-md-image";

    const img = document.createElement("img");
    img.src = resolveAttachmentURL(this.path);
    img.alt = this.alt || "Note image";
    img.loading = "lazy";
    figure.appendChild(img);

    const caption = document.createElement("figcaption");
    caption.textContent = this.alt || attachmentFilename(this.path);
    figure.appendChild(caption);
    return figure;
  }
}

function syntaxDecorationFor(view, line) {
  return editorMode === "read" || !lineHasSelection(view, line)
    ? Decoration.mark({class: "cm-md-syntax-hidden"})
    : Decoration.mark({class: "cm-md-syntax-muted"});
}

function addInlineMarkdownMarks(marks, line) {
  const patterns = [
    {pattern: /\*\*\*([^*\n]+)\*\*\*/g, textClass: "cm-md-bold cm-md-italic", markerSize: 3},
    {pattern: /\*\*([^*\n]+)\*\*/g, textClass: "cm-md-bold", markerSize: 2},
    {pattern: /(?<!\*)\*([^*\n]+)\*(?!\*)/g, textClass: "cm-md-italic", markerSize: 1},
    {pattern: /~~([^~\n]+)~~/g, textClass: "cm-md-strike", markerSize: 2},
  ];

  for (const {pattern, textClass, markerSize} of patterns) {
    for (const match of line.text.matchAll(pattern)) {
      const from = line.from + match.index;
      const to = from + match[0].length;
      marks.push([from, from + markerSize, Decoration.mark({class: "cm-md-syntax-hidden"})]);
      marks.push([from + markerSize, to - markerSize, Decoration.mark({class: textClass})]);
      marks.push([to - markerSize, to, Decoration.mark({class: "cm-md-syntax-hidden"})]);
    }
  }
}

const livePreviewPlugin = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = this.build(view);
    }

    update(update) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.transactions.some((transaction) => transaction.effects.length > 0)
      ) {
        this.decorations = this.build(update.view);
      }
    }

    build(view) {
      if (editorMode === "source") {
        return new RangeSetBuilder().finish();
      }
      const builder = new RangeSetBuilder();
      const wikilink = /\[\[[^\]\n]+\]\]/g;
      const mention = /@([A-Za-z][A-Za-z0-9_-]*)?\[([^\]\n]+)\]|@([A-Za-z][A-Za-z0-9'._-]*)/g;
      const inlineCode = /`[^`\n]+`/g;
      const imageLink = /!\[([^\]\n]*)\]\(([^)\s]+)\)/g;
      const externalLink = /\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g;
      let fencedCodeLanguage = null;

      for (const range of view.visibleRanges) {
        for (let pos = range.from; pos <= range.to;) {
          const line = view.state.doc.lineAt(pos);
          const text = line.text;
          const marks = [];
          const syntaxDecoration = syntaxDecorationFor(view, line);
          const heading = /^(#{1,6})\s+/.exec(text);
          const fence = /^```([A-Za-z0-9_-]*)\s*$/.exec(text);
          const table = /^\|(.+\|)+\s*$/.exec(text);
          const tableDivider = /^\|\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.exec(text);
          const blockquote = /^(>\s?)(.*)/.exec(text);
          const task = /^(\s*)([-*]\s+)(\[[ xX]\])\s+/.exec(text);
          const unorderedList = /^(\s*)([-*]\s+)/.exec(text);
          const orderedList = /^(\s*)(\d+\.\s+)/.exec(text);

          if (heading && editorMode !== "source") {
            const level = Math.min(heading[1].length, 3);
            marks.push([line.from, line.from + heading[0].length, syntaxDecoration]);
            marks.push([
              line.from + heading[0].length,
              line.to,
              Decoration.mark({class: `cm-md-heading-${level}`})
            ]);
          } else if (heading) {
            marks.push([
              line.from,
              line.from + heading[0].length,
              Decoration.mark({class: "cm-md-syntax-muted"})
            ]);
          }

          if (editorMode !== "source") {
            if (fence) {
              const previousLanguage = fencedCodeLanguage;
              fencedCodeLanguage = fencedCodeLanguage === null ? (fence[1] || "plain") : null;
              marks.push([line.from, line.to, Decoration.mark({class: "cm-md-syntax-hidden"})]);
              if (previousLanguage === "harc-context") {
                marks.push([line.from, line.to, Decoration.mark({class: "cm-md-context-fence-edge"})]);
              }
            } else if (fencedCodeLanguage !== null) {
              marks.push([
                line.from,
                line.to,
                Decoration.mark({
                  class: fencedCodeLanguage === "harc-context" ? "cm-md-context-line" : "cm-md-codeblock-line",
                }),
              ]);
            } else if (table || tableDivider) {
              marks.push([line.from, line.to, Decoration.mark({class: tableDivider ? "cm-md-table-divider" : "cm-md-table-line"})]);
            } else if (/^---\s*$/.test(text)) {
              marks.push([line.from, line.to, Decoration.mark({class: "cm-md-hr"})]);
            } else if (blockquote) {
              marks.push([line.from, line.from + blockquote[1].length, syntaxDecoration]);
              marks.push([line.from + blockquote[1].length, line.to, Decoration.mark({class: "cm-md-blockquote"})]);
            } else if (task) {
              const taskMarkerFrom = line.from + task[1].length + task[2].length;
              const taskMarkerTo = taskMarkerFrom + task[3].length;
              marks.push([line.from + task[1].length, taskMarkerFrom, syntaxDecoration]);
              if (editorMode === "read" || !lineHasSelection(view, line)) {
                marks.push([
                  taskMarkerFrom,
                  taskMarkerTo,
                  Decoration.replace({
                    widget: new TaskCheckboxWidget(/[xX]/.test(task[3])),
                    inclusive: false,
                  }),
                ]);
              } else {
                marks.push([taskMarkerFrom, taskMarkerTo, Decoration.mark({class: "cm-md-syntax-muted"})]);
              }
              marks.push([
                taskMarkerTo + 1,
                line.to,
                Decoration.mark({class: /[xX]/.test(task[3]) ? "cm-md-task-done" : "cm-md-list-text"}),
              ]);
            } else if (unorderedList) {
              const markerFrom = line.from + unorderedList[1].length;
              const markerTo = markerFrom + unorderedList[2].length;
              if (editorMode === "read" || !lineHasSelection(view, line)) {
                marks.push([
                  markerFrom,
                  markerTo,
                  Decoration.replace({
                    widget: new ListMarkerWidget("•", "unordered"),
                    inclusive: false,
                  }),
                ]);
              } else {
                marks.push([markerFrom, markerTo, Decoration.mark({class: "cm-md-syntax-muted"})]);
              }
              marks.push([
                markerTo,
                line.to,
                Decoration.mark({class: "cm-md-list-text"}),
              ]);
            } else if (orderedList) {
              const markerFrom = line.from + orderedList[1].length;
              const markerTo = markerFrom + orderedList[2].length;
              if (editorMode === "read" || !lineHasSelection(view, line)) {
                marks.push([
                  markerFrom,
                  markerTo,
                  Decoration.replace({
                    widget: new ListMarkerWidget(orderedList[2].trim(), "ordered"),
                    inclusive: false,
                  }),
                ]);
              } else {
                marks.push([markerFrom, markerTo, Decoration.mark({class: "cm-md-syntax-muted"})]);
              }
              marks.push([
                markerTo,
                line.to,
                Decoration.mark({class: "cm-md-list-text"}),
              ]);
            }

            addInlineMarkdownMarks(marks, line);

            for (const match of text.matchAll(imageLink)) {
              const from = line.from + match.index;
              const to = from + match[0].length;
              if (editorMode !== "source" && !lineHasSelection(view, line)) {
                marks.push([
                  from,
                  to,
                  Decoration.replace({
                    widget: new ImageAttachmentWidget(match[1], match[2]),
                    block: true,
                  }),
                ]);
              } else {
                marks.push([from, to, Decoration.mark({class: "cm-md-link"})]);
              }
            }
          }

          for (const match of text.matchAll(wikilink)) {
            marks.push([
              line.from + match.index,
              line.from + match.index + match[0].length,
              Decoration.mark({class: "cm-wikilink"})
            ]);
          }

          for (const match of text.matchAll(mention)) {
            const from = line.from + match.index;
            const to = from + match[0].length;
            if (editorMode !== "source" && match[2]) {
              const labelFrom = from + match[0].indexOf("[") + 1;
              marks.push([from, labelFrom, Decoration.mark({class: "cm-md-syntax-hidden"})]);
              marks.push([labelFrom, to - 1, Decoration.mark({class: mentionClass(match[1] || "person")})]);
              marks.push([to - 1, to, Decoration.mark({class: "cm-md-syntax-hidden"})]);
            } else {
              marks.push([from, to, Decoration.mark({class: "cm-entity-mention cm-person-mention"})]);
            }
          }

          for (const match of text.matchAll(externalLink)) {
            if (match.index > 0 && text[match.index - 1] === "!") continue;
            const from = line.from + match.index;
            const textFrom = from + 1;
            const textTo = textFrom + match[1].length;
            const to = from + match[0].length;
            if (editorMode !== "source") {
              marks.push([from, textFrom, Decoration.mark({class: "cm-md-syntax-hidden"})]);
              marks.push([textFrom, textTo, Decoration.mark({class: "cm-md-link"})]);
              marks.push([textTo, to, Decoration.mark({class: "cm-md-syntax-hidden"})]);
            } else {
              marks.push([from, to, Decoration.mark({class: "cm-md-link"})]);
            }
          }

          for (const match of text.matchAll(inlineCode)) {
            marks.push([
              line.from + match.index,
              line.from + match.index + match[0].length,
              Decoration.mark({class: "cm-inline-code"})
            ]);
          }

          marks
            .filter(([from, to]) => to > from)
            .sort(([aFrom, aTo], [bFrom, bTo]) => aFrom - bFrom || aTo - bTo)
            .forEach(([from, to, decoration]) => builder.add(from, to, decoration));

          pos = line.to + 1;
        }
      }
      return builder.finish();
    }
  },
  {decorations: (plugin) => plugin.decorations}
);

let suppressChange = false;
let editorMode = "live";
const editableCompartment = new Compartment();
const modeThemeCompartment = new Compartment();
const editorElement = document.getElementById("editor");
const previewElement = document.getElementById("preview");
const ribbonElement = document.getElementById("format-ribbon");
const headingCommandElement = document.getElementById("heading-command");
let formattingRibbonVisible = true;

const markdownRenderer = MarkdownIt({
  html: false,
  linkify: true,
  typographer: true,
  breaks: false,
});

const defaultImageRenderer =
  markdownRenderer.renderer.rules.image ||
  ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));

markdownRenderer.renderer.rules.image = (tokens, idx, options, env, self) => {
  const token = tokens[idx];
  const srcIndex = token.attrIndex("src");
  if (srcIndex >= 0) {
    token.attrs[srcIndex][1] = resolveAttachmentURL(token.attrs[srcIndex][1]);
  }
  return defaultImageRenderer(tokens, idx, options, env, self);
};

function editableExtensionFor(mode) {
  return EditorView.editable.of(mode !== "read");
}

function modeThemeFor(mode) {
  return EditorView.theme({
    "&": {
      cursor: mode === "read" ? "default" : "text",
    },
    ".cm-content": {
      userSelect: mode === "read" ? "text" : "auto",
    },
    ".cm-cursor, .cm-dropCursor": {
      display: mode === "read" ? "none" : undefined,
    },
  });
}

const view = new EditorView({
  parent: editorElement,
  state: EditorState.create({
    doc: initialDoc,
    extensions: [
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      markdown(),
      placeholder("Start writing in Markdown..."),
      autocompletion({
        override: [wikilinkCompletions, mentionCompletions],
        activateOnTyping: true,
      }),
      syntaxHighlighting(markdownHighlight),
      livePreviewPlugin,
      editableCompartment.of(editableExtensionFor(editorMode)),
      modeThemeCompartment.of(modeThemeFor(editorMode)),
      EditorView.lineWrapping,
      Prec.high(keymap.of([
        {
          key: "@",
          run(view) {
            view.dispatch(view.state.replaceSelection("@"));
            startCompletion(view);
            return true;
          },
        },
        {
          key: "[",
          run(view) {
            const before = view.state.sliceDoc(Math.max(0, view.state.selection.main.from - 1), view.state.selection.main.from);
            view.dispatch(view.state.replaceSelection("["));
            if (before === "[") startCompletion(view);
            return true;
          },
        },
      ])),
      Prec.high(EditorView.domEventHandlers({
        paste(event) {
          const items = Array.from(event.clipboardData?.items ?? []);
          const imageItem = items.find((item) => item.type?.startsWith("image/"));
          if (!imageItem) return false;
          const file = imageItem.getAsFile();
          if (!file) return false;
          event.preventDefault();
          readClipboardImage(file);
          return true;
        },
      })),
      EditorView.updateListener.of((update) => {
        if (update.docChanged && !suppressChange) {
          const nextText = update.state.doc.toString();
          renderPreview(nextText);
          postChange(nextText);
        }
      }),
    ],
  }),
});

renderPreview(initialDoc);
editorElement?.addEventListener("mousedown", () => {
  if (editorMode !== "read") {
    requestAnimationFrame(() => view.focus());
  }
});

ribbonElement?.addEventListener("mousedown", (event) => {
  event.preventDefault();
});

ribbonElement?.addEventListener("click", (event) => {
  const target = event.target instanceof Element ? event.target : null;
  const button = target?.closest("[data-md-command]");
  if (!button || editorMode === "read") return;
  runMarkdownCommand(button.dataset.mdCommand);
});

headingCommandElement?.addEventListener("change", (event) => {
  const command = event.target.value;
  if (command && editorMode !== "read") {
    runMarkdownCommand(command);
  }
  event.target.value = "";
});

window.HarcEditor = {
  setText(text) {
    const current = view.state.doc.toString();
    if (text === current) return;
    suppressChange = true;
    view.dispatch({
      changes: {from: 0, to: current.length, insert: text},
    });
    suppressChange = false;
    renderPreview(text);
  },
  focus() {
    view.focus();
  },
  getText() {
    return view.state.doc.toString();
  },
  setLinkTargets(targets) {
    if (!Array.isArray(targets)) {
      linkTargets = [];
      return;
    }
    linkTargets = targets
      .filter((target) => target && typeof target.label === "string")
      .map((target) => ({
        label: target.label,
        kind: typeof target.kind === "string" ? target.kind : "note",
        detail: typeof target.detail === "string" ? target.detail : "",
      }));
  },
  setMentionTargets(targets) {
    if (!Array.isArray(targets)) {
      mentionTargets = [];
      return;
    }
    mentionTargets = targets
      .filter((target) => target && typeof target.label === "string")
      .map((target) => ({
        label: target.label,
        kind: typeof target.kind === "string" ? target.kind : "person",
        detail: typeof target.detail === "string" ? target.detail : "",
      }));
  },
  setAttachmentBaseURL(url) {
    attachmentBaseURL = typeof url === "string" ? url : "";
    renderPreview(view.state.doc.toString());
  },
  setFormattingRibbonVisible(isVisible) {
    formattingRibbonVisible = Boolean(isVisible);
    updateFormattingRibbonVisibility();
  },
  insertMarkdown(markdown) {
    if (typeof markdown !== "string" || markdown.length === 0) return;
    const insert = `\n\n${markdown}\n\n`;
    view.dispatch({
      changes: view.state.replaceSelection(insert),
      selection: {anchor: view.state.selection.main.from + insert.length},
      userEvent: "input.paste",
    });
    postChange(view.state.doc.toString());
  },
  showAttachmentError(message) {
    showAttachmentError(message);
  },
  setMode(mode) {
    if (!["source", "live", "read"].includes(mode)) return;
    editorMode = mode;
    const isRead = mode === "read";
    if (editorElement) editorElement.hidden = isRead;
    if (previewElement) previewElement.hidden = !isRead;
    updateFormattingRibbonVisibility();
    renderPreview(view.state.doc.toString());
    view.dispatch({
      effects: [
        editableCompartment.reconfigure(editableExtensionFor(mode)),
        modeThemeCompartment.reconfigure(modeThemeFor(mode)),
      ],
    });
    if (!isRead) {
      requestAnimationFrame(() => view.focus());
    }
  },
};

function updateFormattingRibbonVisibility() {
  if (!ribbonElement) return;
  ribbonElement.hidden = !formattingRibbonVisible || editorMode === "read";
  const editorHeight = ribbonElement.hidden ? "100%" : "calc(100% - 42px)";
  if (editorElement) editorElement.style.height = editorHeight;
  if (previewElement) previewElement.style.height = "100%";
}

updateFormattingRibbonVisibility();

function currentText() {
  return view.state.doc.toString();
}

function dispatchTextReplacement(from, to, insert, selectionOffset = insert.length) {
  view.dispatch({
    changes: {from, to, insert},
    selection: {anchor: from + selectionOffset},
    userEvent: "input",
  });
  renderPreview(currentText());
  postChange(currentText());
  requestAnimationFrame(() => view.focus());
}

function selectedTextOrPlaceholder(placeholderText) {
  const selection = view.state.selection.main;
  const selected = view.state.sliceDoc(selection.from, selection.to);
  return selected.length > 0 ? selected : placeholderText;
}

function wrapSelection(prefix, suffix = prefix, placeholderText = "text") {
  const selection = view.state.selection.main;
  const selected = selectedTextOrPlaceholder(placeholderText);
  const insert = `${prefix}${selected}${suffix}`;
  const cursorOffset = selection.empty ? prefix.length + selected.length : insert.length;
  dispatchTextReplacement(selection.from, selection.to, insert, cursorOffset);
}

function insertBlock(markdown, cursorOffset = markdown.length) {
  const selection = view.state.selection.main;
  const before = view.state.sliceDoc(Math.max(0, selection.from - 1), selection.from);
  const after = view.state.sliceDoc(selection.to, Math.min(view.state.doc.length, selection.to + 1));
  const leading = selection.from > 0 && before !== "\n" ? "\n\n" : "";
  const trailing = selection.to < view.state.doc.length && after !== "\n" ? "\n\n" : "";
  const insert = `${leading}${markdown}${trailing}`;
  dispatchTextReplacement(selection.from, selection.to, insert, leading.length + cursorOffset);
}

function transformSelectedLines(transform) {
  const selection = view.state.selection.main;
  const fromLine = view.state.doc.lineAt(selection.from);
  const toLine = view.state.doc.lineAt(selection.to);
  const original = view.state.sliceDoc(fromLine.from, toLine.to);
  const replacement = original.split("\n").map(transform).join("\n");
  dispatchTextReplacement(fromLine.from, toLine.to, replacement);
}

function removeLineMarkdownPrefix(line) {
  return line
    .replace(/^\s{0,3}#{1,6}\s+/, "")
    .replace(/^(\s*)[-*]\s+\[[ xX]\]\s+/, "$1")
    .replace(/^(\s*)[-*]\s+/, "$1")
    .replace(/^(\s*)\d+\.\s+/, "$1")
    .replace(/^(\s*)>\s?/, "$1");
}

function setHeading(level) {
  transformSelectedLines((line) => {
    if (line.trim().length === 0) return line;
    return `${"#".repeat(level)} ${removeLineMarkdownPrefix(line).trimStart()}`;
  });
}

function runMarkdownCommand(command) {
  switch (command) {
  case "bold":
    wrapSelection("**", "**", "bold");
    break;
  case "italic":
    wrapSelection("*", "*", "italic");
    break;
  case "strike":
    wrapSelection("~~", "~~", "text");
    break;
  case "inline-code":
    wrapSelection("`", "`", "code");
    break;
  case "heading-1":
    setHeading(1);
    break;
  case "heading-2":
    setHeading(2);
    break;
  case "heading-3":
    setHeading(3);
    break;
  case "bullet-list":
    transformSelectedLines((line) => line.trim().length === 0 ? line : `${line.match(/^\s*/)[0]}- ${removeLineMarkdownPrefix(line).trimStart()}`);
    break;
  case "ordered-list": {
    let index = 1;
    transformSelectedLines((line) => line.trim().length === 0 ? line : `${line.match(/^\s*/)[0]}${index++}. ${removeLineMarkdownPrefix(line).trimStart()}`);
    break;
  }
  case "task-list":
    transformSelectedLines((line) => line.trim().length === 0 ? line : `${line.match(/^\s*/)[0]}- [ ] ${removeLineMarkdownPrefix(line).trimStart()}`);
    break;
  case "quote":
    transformSelectedLines((line) => line.trim().length === 0 ? line : `${line.match(/^\s*/)[0]}> ${removeLineMarkdownPrefix(line).trimStart()}`);
    break;
  case "divider":
    insertBlock("---\n", 3);
    break;
  case "code-block": {
    const selected = selectedTextOrPlaceholder("code");
    insertBlock(`\`\`\`\n${selected}\n\`\`\`\n`, 4);
    break;
  }
  case "table":
    insertBlock("| Column | Value |\n| --- | --- |\n| Item | Detail |\n", 2);
    break;
  case "link":
    wrapSelection("[", "](https://)", "link");
    break;
  case "image":
    wrapSelection("![", "](attachments/image.png)", "alt");
    break;
  default:
    break;
  }
}

function renderPreview(markdown) {
  if (!previewElement) return;
  const html = markdownRenderer.render(markdown || "");
  previewElement.innerHTML = renderTaskLists(html);
  previewElement.querySelectorAll("a[href]").forEach((anchor) => {
    const href = anchor.getAttribute("href") || "";
    if (/^https?:\/\//i.test(href)) {
      anchor.setAttribute("target", "_blank");
      anchor.setAttribute("rel", "noopener noreferrer");
    }
  });
}

function renderTaskLists(html) {
  return html.replace(
    /<li>\s*\[([ xX])\]\s+/g,
    (_, checked) => `<li class="md-task-list-item"><input class="md-task-checkbox" type="checkbox" disabled ${/[xX]/.test(checked) ? "checked" : ""}>`
  );
}

function readClipboardImage(file) {
  const reader = new FileReader();
  reader.onload = () => {
    const result = typeof reader.result === "string" ? reader.result : "";
    const comma = result.indexOf(",");
    const data = comma >= 0 ? result.slice(comma + 1) : result;
    window.webkit?.messageHandlers?.harc?.postMessage({
      type: "pasteImage",
      data,
      mimeType: file.type || "image/png",
      filename: file.name || "",
    });
  };
  reader.onerror = () => showAttachmentError("Could not read the pasted image.");
  reader.readAsDataURL(file);
}

function resolveAttachmentURL(path) {
  if (/^(file|https?):\/\//i.test(path)) return path;
  const clean = path.replace(/^\.\//, "");
  if (!attachmentBaseURL) return clean;
  return new URL(clean, attachmentBaseURL).toString();
}

function attachmentFilename(path) {
  const clean = path.split(/[?#]/)[0].replace(/\/+$/, "");
  return clean.slice(clean.lastIndexOf("/") + 1) || "Note image";
}

function showAttachmentError(message) {
  const existing = document.querySelector(".attachment-error");
  existing?.remove();
  const banner = document.createElement("div");
  banner.className = "attachment-error";
  banner.textContent = message || "Could not attach image.";
  document.body.appendChild(banner);
  setTimeout(() => banner.remove(), 4000);
}

function wikilinkCompletions(context) {
  const before = context.matchBefore(/\[\[([^\]\[]*)$/);
  if (!before) return null;
  const query = before.text.slice(2).toLowerCase();
  const options = linkTargets
    .filter((target) => target.label.toLowerCase().includes(query))
    .slice(0, 50)
    .map((target) => ({
      label: target.label,
      type: target.kind === "recording" ? "constant" : "text",
      detail: target.detail || (target.kind === "recording" ? "Recording" : "Note"),
      apply(view, completion, from, to) {
        view.dispatch({
          changes: {
            from,
            to,
            insert: `${completion.label}]]`,
          },
          selection: {anchor: from + completion.label.length + 2},
        });
      },
    }));

  return {
    from: before.from + 2,
    options,
    validFor: /^[^\]\[]*$/,
  };
}

function mentionClass(kind) {
  const normalizedKind = typeof kind === "string" ? kind.toLowerCase() : "person";
  return `cm-entity-mention cm-${normalizedKind}-mention`;
}

function typedMentionInsertText(target) {
  const kind = target.kind || "person";
  return `@${kind}[${target.label}]`;
}

function mentionInsertText(target, explicitKind = null) {
  if (explicitKind) return `@${explicitKind}[${target.label}]`;
  if (target.kind && target.kind !== "person") return typedMentionInsertText(target);
  return /\s/.test(target.label) ? `@[${target.label}]` : `@${target.label}`;
}

function normalizedMentionText(value) {
  return value.trim().toLocaleLowerCase();
}

function mentionTargetMatches(target, query) {
  const normalizedQuery = normalizedMentionText(query);
  if (normalizedQuery.length === 0) return true;
  const label = normalizedMentionText(target.label);
  const tokens = label.split(/\s+/).filter(Boolean);
  return label.includes(normalizedQuery) || tokens.some((token) => token.startsWith(normalizedQuery));
}

function mentionTargetRank(target, query) {
  const normalizedQuery = normalizedMentionText(query);
  if (normalizedQuery.length === 0) return 0;
  const label = normalizedMentionText(target.label);
  const tokens = label.split(/\s+/).filter(Boolean);
  if (label.startsWith(normalizedQuery)) return 0;
  if (tokens.some((token) => token.startsWith(normalizedQuery))) return 1;
  if (label.includes(normalizedQuery)) return 2;
  return 3;
}

function mentionCompletions(context) {
  const typed = context.matchBefore(/@([A-Za-z][A-Za-z0-9_-]*)\[([^\]\n]*)$/);
  const bracketed = typed ? null : context.matchBefore(/@\[([^\]\n]*)$/);
  const bare = typed || bracketed ? null : context.matchBefore(/@([A-Za-z0-9'._-]*)$/);
  const before = typed || bracketed || bare;
  if (!before) return null;
  const explicitKind = typed ? typed.text.slice(1, typed.text.indexOf("[")).toLowerCase() : null;
  const query = typed || bracketed
    ? before.text.slice(before.text.indexOf("[") + 1).toLowerCase()
    : before.text.slice(1).toLowerCase();
  if (!context.explicit && query.length === 0) return null;
  const options = mentionTargets
    .filter((target) => !explicitKind || target.kind === explicitKind)
    .filter((target) => mentionTargetMatches(target, query))
    .sort((a, b) => {
      const rankDelta = mentionTargetRank(a, query) - mentionTargetRank(b, query);
      if (rankDelta !== 0) return rankDelta;
      return a.label.localeCompare(b.label, undefined, {sensitivity: "base"});
    })
    .slice(0, 50)
    .map((target) => ({
      label: target.label,
      type: "keyword",
      detail: target.detail || (target.kind === "project" ? "Project" : "Person"),
      apply(view, completion, from, to) {
        const insert = mentionInsertText(target, explicitKind);
        view.dispatch({
          changes: {from: before.from, to, insert},
          selection: {anchor: before.from + insert.length},
        });
      },
    }));

  return {
    from: typed || bracketed ? before.from + before.text.indexOf("[") + 1 : before.from + 1,
    options,
    validFor: typed || bracketed ? /^[^\]\n]*$/ : /^[A-Za-z0-9'._-]*$/,
  };
}

if (!window.webkit?.messageHandlers?.harc) {
  const controls = document.createElement("nav");
  controls.className = "dev-controls";
  controls.setAttribute("aria-label", "Preview editor modes");
  for (const mode of ["source", "live", "read"]) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = mode[0].toUpperCase() + mode.slice(1);
    button.addEventListener("click", () => window.HarcEditor.setMode(mode));
    controls.appendChild(button);
  }
  document.body.prepend(controls);
}
