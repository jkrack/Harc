import { readFile } from "node:fs/promises";

const url = process.argv[2] ?? "http://127.0.0.1:8765/index.html?fixture=full-markdown";
const fixturePath = new URL("./Fixtures/full-markdown-capability.md", import.meta.url);
const entryPath = new URL("./editor-entry.js", import.meta.url);

const requiredText = [
  "Meeting Notes",
  "bold",
  "italic",
  "inline code",
  "Michelle",
  "Decisions",
  "Checklist",
  "Speaker 1",
  "First ordered item",
  "sourceOfTruth",
  "Field",
  "recording:42",
  "Harc repo",
  "@amy",
  "@Neal",
  "@[Amy Williams]",
];

const text = await readFile(fixturePath, "utf8");
const entry = await readFile(entryPath, "utf8");
const missing = requiredText.filter((item) => !text.includes(item));

const checks = {
  headingFixture: /^# Meeting Notes/m.test(text) && /^## Decisions/m.test(text) && /^### Checklist/m.test(text),
  emphasisFixture: text.includes("**bold**") && text.includes("*italic*") && text.includes("~~strikethrough~~"),
  listsFixture: text.includes("- Ship the local editor bundle.") && text.includes("1. First ordered item"),
  taskFixture: text.includes("- [x] Record audio locally") && text.includes("- [ ] Link a note to a recording"),
  blockquoteFixture: text.includes("> Speaker 1:"),
  codeFenceFixture: text.includes("```swift") && text.includes("```harc-context"),
  tableFixture: text.includes("| Field | Expected |"),
  linkFixture: text.includes("[Harc repo](https://github.com/jkrack/Harc)"),
  mentionFixture: text.includes("@amy") && text.includes("@Neal") && text.includes("@[Amy Williams]"),
  milkdownEditor: entry.includes("Editor.make()") &&
    entry.includes("@milkdown/kit/core") &&
    entry.includes("@milkdown/kit/preset/commonmark"),
  headingRendered: entry.includes("commonmark") && entry.includes("heading-1"),
  emphasisStyled: entry.includes("bold") && entry.includes("italic") && entry.includes("strike"),
  taskStyled: entry.includes("renderTaskLists(html)") && entry.includes("md-task-checkbox"),
  blockquoteStyled: entry.includes("quote"),
  codeFenceStyled: entry.includes("code-block") && entry.includes("harc-context-block"),
  tableStyled: entry.includes("table"),
  thematicBreakStyled: entry.includes("divider"),
  wikilinkStyled: entry.includes("[[") && entry.includes("linkTargets"),
  mentionStyled: entry.includes("mentionTargets") && entry.includes("typedMentionInsertText"),
  inlineCodeStyled: entry.includes("inline-code"),
  wikilinkAutocomplete: entry.includes("maybeShowCompletions") &&
    entry.includes("showCompletions(matches, isWiki)") &&
    entry.includes("setLinkTargets(targets)"),
  mentionAutocomplete: entry.includes("maybeShowCompletions") &&
    entry.includes("setMentionTargets(targets)") &&
    entry.includes("standaloneMentionTargets") &&
    entry.includes("typedMentionInsertText"),
  modeSupport: entry.includes("setMode(mode)") && entry.includes("sourceElement") && entry.includes("read"),
  attachmentSupport: entry.includes("readClipboardImage(file)") &&
    entry.includes("requestNativePasteboardImage()") &&
    entry.includes("resolveAttachmentURL(path)") &&
    entry.includes("insertMarkdown(markdown)"),
  fixtureTextPresent: missing.length === 0,
};

if (Object.values(checks).some((value) => !value)) {
  console.error(JSON.stringify({ ok: false, url, checks, missing }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({ ok: true, url, checks }, null, 2));
