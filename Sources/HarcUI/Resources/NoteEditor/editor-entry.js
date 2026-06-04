import {Editor, defaultValueCtx, editorViewCtx, rootCtx, serializerCtx} from "@milkdown/kit/core";
import {commonmark} from "@milkdown/kit/preset/commonmark";
import {history} from "@milkdown/kit/plugin/history";
import {listener, listenerCtx} from "@milkdown/kit/plugin/listener";
import {replaceAll} from "@milkdown/kit/utils";
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
| Editor | Milkdown |
| Mode | WYSIWYG |

---

\`\`\`harc-context
recording: recording:42
timecode: 00:03:42
speaker: Michelle
quote: "We should keep the notes tied to the recording."
\`\`\`

[Harc repo](https://github.com/jkrack/Harc)`,
};

const fixtureName = new URLSearchParams(location.search).get("fixture");
const initialDoc = standaloneFixtures[fixtureName] ?? "# Title\n\nStart writing in Markdown.";
const standaloneMentionTargets = {
  "full-markdown": [
    {label: "Amy Williams", kind: "person", detail: "Person"},
    {label: "Neal Patel", kind: "person", detail: "Person"},
    {label: "Michelle", kind: "person", detail: "Person"},
    {label: "Q3 Launch", kind: "project", detail: "Project"},
  ],
};

let pendingChangeText = null;
let pendingChangeTimer = null;
let changeCommitDelay = 180;
let linkTargets = [];
let mentionTargets = standaloneMentionTargets[fixtureName] ?? [];
let attachmentBaseURL = "";
let suppressChange = false;
let editorMode = "live";
let formattingRibbonVisible = true;
let editorReady = false;
let lastMarkdown = initialDoc;

const editorElement = document.getElementById("editor");
const sourceElement = document.getElementById("source-editor");
const previewElement = document.getElementById("preview");
const ribbonElement = document.getElementById("format-ribbon");
const headingCommandElement = document.getElementById("heading-command");

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

const sendChange = (text) => {
  window.webkit?.messageHandlers?.harc?.postMessage({type: "change", text});
};

const postChange = (text, options = {}) => {
  pendingChangeText = text;
  if (pendingChangeTimer !== null) {
    clearTimeout(pendingChangeTimer);
    pendingChangeTimer = null;
  }
  if (options.immediate || changeCommitDelay <= 0) {
    flushPendingChange();
    return;
  }
  pendingChangeTimer = setTimeout(flushPendingChange, changeCommitDelay);
};

function flushPendingChange() {
  if (pendingChangeTimer !== null) {
    clearTimeout(pendingChangeTimer);
    pendingChangeTimer = null;
  }
  if (pendingChangeText === null) return;
  const text = pendingChangeText;
  pendingChangeText = null;
  sendChange(text);
}

function flushChanges() {
  flushPendingChange();
}

function setCurrentMarkdown(markdown, options = {}) {
  lastMarkdown = markdown;
  renderPreview(markdown);
  if (sourceElement.value !== markdown) {
    sourceElement.value = markdown;
  }
  if (!options.silent) {
    postChange(markdown, {immediate: options.immediate});
  }
}

function serializeMilkdown() {
  if (!editorReady) return lastMarkdown;
  return milkdown.action((ctx) => {
    const view = ctx.get(editorViewCtx);
    const serializer = ctx.get(serializerCtx);
    return serializer(view.state.doc);
  });
}

function replaceMilkdownMarkdown(markdown) {
  if (!editorReady) return;
  suppressChange = true;
  milkdown.action(replaceAll(markdown));
  suppressChange = false;
}

const milkdown = Editor.make()
  .config((ctx) => {
    ctx.set(rootCtx, editorElement);
    ctx.set(defaultValueCtx, initialDoc);
    ctx.get(listenerCtx).markdownUpdated((_ctx, markdown) => {
      if (suppressChange || editorMode !== "live") return;
      setCurrentMarkdown(markdown);
    });
  })
  .use(commonmark)
  .use(history)
  .use(listener);

milkdown.create().then(() => {
  editorReady = true;
  setCurrentMarkdown(initialDoc, {silent: true});
  setMode(editorMode);
});

sourceElement.value = initialDoc;
renderPreview(initialDoc);
updateFormattingRibbonVisibility();

sourceElement.addEventListener("input", () => {
  if (editorMode !== "source") return;
  setCurrentMarkdown(sourceElement.value);
});

sourceElement.addEventListener("paste", (event) => {
  handlePasteEvent(event);
});

editorElement?.addEventListener("paste", (event) => {
  handlePasteEvent(event);
});

editorElement?.addEventListener("input", () => {
  decorateMilkdownSurface();
});

editorElement?.addEventListener("keyup", () => {
  decorateMilkdownSurface();
  maybeShowCompletions();
});

editorElement?.addEventListener("mouseup", decorateMilkdownSurface);

window.addEventListener("blur", flushPendingChange);
window.addEventListener("pagehide", flushPendingChange);

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

document.addEventListener("click", (event) => {
  if (!event.target.closest?.("#completion-popover")) hideCompletions();
});

window.HarcEditor = {
  setText(text) {
    if (text === lastMarkdown) return;
    setCurrentMarkdown(text, {silent: true});
    replaceMilkdownMarkdown(text);
  },
  focus() {
    if (editorMode === "source") {
      sourceElement.focus();
    } else if (editorReady) {
      milkdown.action((ctx) => ctx.get(editorViewCtx).focus());
    }
  },
  getText() {
    if (editorMode === "source") return sourceElement.value;
    return serializeMilkdown();
  },
  setLinkTargets(targets) {
    linkTargets = normalizeTargets(targets, "note");
  },
  setMentionTargets(targets) {
    mentionTargets = normalizeTargets(targets, "person");
  },
  setMode,
  flushChanges,
  setChangeCommitDelay(milliseconds) {
    const next = Number(milliseconds);
    if (Number.isFinite(next) && next >= 0) {
      changeCommitDelay = next;
    }
  },
  setAttachmentBaseURL(url) {
    attachmentBaseURL = typeof url === "string" ? url : "";
    renderPreview(lastMarkdown);
    decorateMilkdownSurface();
  },
  setFormattingRibbonVisible(isVisible) {
    formattingRibbonVisible = Boolean(isVisible);
    updateFormattingRibbonVisibility();
  },
  insertMarkdown(markdown) {
    insertMarkdown(markdown);
  },
  runMarkdownCommand(command) {
    runMarkdownCommand(command);
  },
  showAttachmentError(message) {
    showAttachmentError(message);
  },
};

function normalizeTargets(targets, fallbackKind) {
  if (!Array.isArray(targets)) return [];
  return targets
    .filter((target) => target && typeof target.label === "string")
    .map((target) => ({
      label: target.label,
      kind: typeof target.kind === "string" ? target.kind : fallbackKind,
      detail: typeof target.detail === "string" ? target.detail : "",
    }));
}

function setMode(mode) {
  if (!["source", "live", "read"].includes(mode)) return;
  if (editorMode === "live") {
    setCurrentMarkdown(serializeMilkdown(), {silent: true});
  }
  if (editorMode === "source") {
    replaceMilkdownMarkdown(sourceElement.value);
  }

  editorMode = mode;
  editorElement.hidden = mode !== "live";
  sourceElement.hidden = mode !== "source";
  previewElement.hidden = mode !== "read";
  sourceElement.readOnly = mode === "read";
  editorElement.classList.toggle("is-readonly", mode === "read");
  updateMilkdownEditable(mode !== "read");
  updateFormattingRibbonVisibility();
  renderPreview(lastMarkdown);
  decorateMilkdownSurface();
}

function updateMilkdownEditable(isEditable) {
  if (!editorReady) return;
  milkdown.action((ctx) => {
    const view = ctx.get(editorViewCtx);
    view.setProps({editable: () => isEditable});
  });
}

function insertMarkdown(markdown) {
  if (editorMode === "read") return;
  if (editorMode === "source") {
    wrapSourceSelection(markdown, "");
    return;
  }
  const selection = currentSelection();
  const next = selection.text.slice(0, selection.from) + markdown + selection.text.slice(selection.to);
  selection.commit(next, selection.from + markdown.length, selection.from + markdown.length);
}

function runMarkdownCommand(command) {
  switch (command) {
  case "bold":
    wrapSelection("**", "**");
    break;
  case "italic":
    wrapSelection("*", "*");
    break;
  case "strike":
    wrapSelection("~~", "~~");
    break;
  case "inline-code":
    wrapSelection("`", "`");
    break;
  case "heading-1":
    transformSelectedLines((line) => line.replace(/^#{1,6}\s+/, "").replace(/^/, "# "));
    break;
  case "heading-2":
    transformSelectedLines((line) => line.replace(/^#{1,6}\s+/, "").replace(/^/, "## "));
    break;
  case "heading-3":
    transformSelectedLines((line) => line.replace(/^#{1,6}\s+/, "").replace(/^/, "### "));
    break;
  case "bullet-list":
    transformSelectedLines((line) => line.trim() ? line.replace(/^(\s*)([-*]|\d+\.)\s+/, "$1").replace(/^(\s*)/, "$1- ") : "- ");
    break;
  case "ordered-list":
    transformSelectedLines((line, index) => line.trim() ? line.replace(/^(\s*)([-*]|\d+\.)\s+/, "$1").replace(/^(\s*)/, `$1${index + 1}. `) : `${index + 1}. `);
    break;
  case "task-list":
    transformSelectedLines((line) => line.trim() ? line.replace(/^(\s*)([-*]\s+)?(\[[ xX]\]\s+)?/, "$1- [ ] ") : "- [ ] ");
    break;
  case "quote":
    transformSelectedLines((line) => line.replace(/^(\s*)/, "$1> "));
    break;
  case "divider":
    insertMarkdown("\n---\n");
    break;
  case "code-block":
    wrapSelection("```\n", "\n```");
    break;
  case "table":
    insertMarkdown("\n| Field | Value |\n| --- | --- |\n|  |  |\n");
    break;
  case "link":
    wrapSelection("[", "](https://)");
    break;
  case "image":
    insertMarkdown("![image](./note.assets/image.png)");
    break;
  default:
    break;
  }
}

function currentSelection() {
  if (editorMode === "source") {
    return {
      text: sourceElement.value,
      from: sourceElement.selectionStart,
      to: sourceElement.selectionEnd,
      commit(next, nextFrom, nextTo) {
        sourceElement.value = next;
        sourceElement.setSelectionRange(nextFrom, nextTo);
        sourceElement.focus();
        setCurrentMarkdown(next, {immediate: true});
        replaceMilkdownMarkdown(next);
      },
    };
  }
  const text = serializeMilkdown();
  return {
    text,
    from: text.length,
    to: text.length,
    commit(next) {
      setCurrentMarkdown(next, {immediate: true});
      replaceMilkdownMarkdown(next);
    },
  };
}

function wrapSelection(prefix, suffix) {
  const selection = currentSelection();
  const selected = selection.text.slice(selection.from, selection.to) || "";
  const next = selection.text.slice(0, selection.from) + prefix + selected + suffix + selection.text.slice(selection.to);
  selection.commit(next, selection.from + prefix.length, selection.to + prefix.length);
}

function wrapSourceSelection(prefix, suffix) {
  const from = sourceElement.selectionStart;
  const to = sourceElement.selectionEnd;
  const selected = sourceElement.value.slice(from, to);
  const next = sourceElement.value.slice(0, from) + prefix + selected + suffix + sourceElement.value.slice(to);
  sourceElement.value = next;
  sourceElement.setSelectionRange(from + prefix.length, to + prefix.length);
  setCurrentMarkdown(next, {immediate: true});
  replaceMilkdownMarkdown(next);
}

function transformSelectedLines(transform) {
  const selection = currentSelection();
  const lineStart = selection.text.lastIndexOf("\n", Math.max(0, selection.from - 1)) + 1;
  const lineEndIndex = selection.text.indexOf("\n", selection.to);
  const lineEnd = lineEndIndex === -1 ? selection.text.length : lineEndIndex;
  const block = selection.text.slice(lineStart, lineEnd);
  const transformed = block.split("\n").map(transform).join("\n");
  const next = selection.text.slice(0, lineStart) + transformed + selection.text.slice(lineEnd);
  selection.commit(next, lineStart, lineStart + transformed.length);
}

function renderPreview(markdown) {
  previewElement.innerHTML = renderTaskLists(markdownRenderer.render(markdown));
}

function renderTaskLists(html) {
  return html.replace(/<li>\s*\[([ xX])\]\s+/g, (_match, checked) => {
    const isChecked = checked.toLowerCase() === "x";
    return `<li class="md-task-list-item"><input class="md-task-checkbox" type="checkbox" disabled${isChecked ? " checked" : ""}> `;
  });
}

function resolveAttachmentURL(path) {
  if (!path) return path;
  if (/^(https?:|file:|data:|blob:)/.test(path)) return path;
  if (!attachmentBaseURL) return path;
  try {
    return new URL(path.replace(/^\.\//, ""), attachmentBaseURL).toString();
  } catch {
    return path;
  }
}

function handlePasteEvent(event) {
  const items = Array.from(event.clipboardData?.items ?? []);
  const imageItem = items.find((item) => item.type?.startsWith("image/"));
  if (!imageItem) {
    requestNativePasteboardImage();
    return false;
  }
  const file = imageItem.getAsFile();
  if (!file) {
    requestNativePasteboardImage();
    return false;
  }
  event.preventDefault();
  readClipboardImage(file);
  return true;
}

function readClipboardImage(file) {
  const reader = new FileReader();
  reader.onload = () => {
    const result = typeof reader.result === "string" ? reader.result : "";
    const [, data = ""] = result.split(",");
    window.webkit?.messageHandlers?.harc?.postMessage({
      type: "pasteImage",
      data,
      mimeType: file.type || "image/png",
      filename: file.name || null,
    });
  };
  reader.onerror = () => showAttachmentError("Could not read the pasted image.");
  reader.readAsDataURL(file);
}

function requestNativePasteboardImage() {
  window.webkit?.messageHandlers?.harc?.postMessage({type: "nativePasteboardImage"});
}

function showAttachmentError(message) {
  const existing = document.querySelector(".attachment-error");
  existing?.remove();
  const element = document.createElement("div");
  element.className = "attachment-error";
  element.textContent = message || "Could not attach image.";
  document.body.appendChild(element);
  setTimeout(() => element.remove(), 4200);
}

function updateFormattingRibbonVisibility() {
  ribbonElement.hidden = !formattingRibbonVisible || editorMode === "read";
}

function decorateMilkdownSurface() {
  if (!editorReady) return;
  for (const image of editorElement.querySelectorAll("img")) {
    const src = image.getAttribute("src");
    const resolved = resolveAttachmentURL(src);
    if (resolved !== src) image.setAttribute("src", resolved);
  }
  for (const code of editorElement.querySelectorAll("pre code")) {
    const text = code.textContent ?? "";
    code.parentElement?.classList.toggle("harc-context-block", text.includes("recording:") && text.includes("timecode:"));
  }
}

let completionElement = null;
const completionProjectClass = "completion-project";

function maybeShowCompletions() {
  if (editorMode !== "live" || !editorReady) return;
  const markdown = serializeMilkdown();
  const token = /(?:\[\[|@[\w-]*\[?|@)([A-Za-z0-9 _.-]{0,32})$/.exec(markdown);
  if (!token) {
    hideCompletions();
    return;
  }
  const isWiki = token[0].startsWith("[[");
  const targets = isWiki ? linkTargets : mentionTargets;
  const query = token[1].toLowerCase();
  const matches = targets
    .filter((target) => target.label.toLowerCase().includes(query))
    .slice(0, 6);
  if (matches.length === 0) {
    hideCompletions();
    return;
  }
  showCompletions(matches, isWiki);
}

function showCompletions(matches, isWiki) {
  hideCompletions();
  completionElement = document.createElement("div");
  completionElement.id = "completion-popover";
  completionElement.setAttribute("role", "listbox");
  for (const target of matches) {
    const option = document.createElement("button");
    option.type = "button";
    option.className = `completion-option ${target.kind === "project" ? completionProjectClass : `completion-${target.kind}`}`;
    option.textContent = target.detail ? `${target.label} ${target.detail}` : target.label;
    option.addEventListener("mousedown", (event) => {
      event.preventDefault();
      insertMarkdown(isWiki ? `[[${target.label}]]` : typedMentionInsertText(target));
      hideCompletions();
    });
    completionElement.appendChild(option);
  }
  document.body.appendChild(completionElement);
}

function hideCompletions() {
  completionElement?.remove();
  completionElement = null;
}

function typedMentionInsertText(target) {
  if (target.kind === "project") return `@project[${target.label}]`;
  return `@person[${target.label}]`;
}
