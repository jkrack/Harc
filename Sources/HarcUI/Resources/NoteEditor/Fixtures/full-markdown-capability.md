# Meeting Notes

This paragraph checks **bold**, *italic*, ***bold italic***, `inline code`, ~~strikethrough~~, a [[Michelle]] wikilink, and @amy plus @Neal person mentions.

Use bracketed mentions for full names like @[Amy Williams], typed people like @person[Amy Williams], and projects like @project[Q3 Launch].

Symbol gauntlet: ~ ! @ # $ % ^ & * ( ) _ + - = { } [ ] | \ : ; " ' < > , . ? /

Escaped literals: \*literal asterisk\* \[literal brackets\] \`literal tick\`

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

```swift
let sourceOfTruth = "Markdown"
print(sourceOfTruth)
```

| Field | Expected |
| --- | --- |
| Storage | Markdown |
| Editor | CodeMirror 6 |
| Mode | Live Preview |

---

```harc-context
recording: recording:42
timecode: 00:03:42
speaker: Michelle
quote: "We should keep the notes tied to the recording."
```

[Harc repo](https://github.com/jkrack/Harc)
