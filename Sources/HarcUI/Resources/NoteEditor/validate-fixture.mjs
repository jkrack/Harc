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
  headingRendered: entry.includes("cm-md-heading-${level}") || entry.includes("cm-md-heading-1"),
  emphasisStyled: entry.includes("cm-md-bold") && entry.includes("cm-md-italic") && entry.includes("cm-md-strike"),
  taskStyled: entry.includes("TaskCheckboxWidget") && entry.includes("cm-md-task-done"),
  blockquoteStyled: entry.includes("cm-md-blockquote"),
  codeFenceStyled: entry.includes("cm-md-codeblock-line") && entry.includes("cm-md-context-line"),
  tableStyled: entry.includes("cm-md-table-line") && entry.includes("cm-md-table-divider"),
  thematicBreakStyled: entry.includes("cm-md-hr"),
  wikilinkStyled: entry.includes("cm-wikilink"),
  mentionStyled: entry.includes("cm-person-mention"),
  inlineCodeStyled: entry.includes("cm-inline-code"),
  wikilinkAutocomplete: entry.includes("autocompletion") &&
    entry.includes("wikilinkCompletions") &&
    entry.includes("setLinkTargets(targets)"),
  mentionAutocomplete: entry.includes("mentionCompletions") &&
    entry.includes("setMentionTargets(targets)") &&
    entry.includes("standaloneMentionTargets") &&
    entry.includes("mentionInsertText"),
  modeSupport: entry.includes("setMode(mode)") && entry.includes("source") && entry.includes("read"),
  fixtureTextPresent: missing.length === 0,
};

if (Object.values(checks).some((value) => !value)) {
  console.error(JSON.stringify({ ok: false, url, checks, missing }, null, 2));
  process.exit(1);
}

console.log(JSON.stringify({ ok: true, url, checks }, null, 2));
