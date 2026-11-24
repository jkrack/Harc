# Independent blind adjudication

Blind adjudication complete. Read only the masked `holdout.json.adjudication.json` at commit `4b0abf4`, through GitHub. Did not read expected labels, anchor definitions, scores, RESULTS, or surrounding reports. No files modified.

Interpretation: `suggest` asserts that the transcript substantively relates to the named project and brief. Quotation sufficiency means evidence for that relationship, not simply a verbatim substring.

| Case | Model decision supported? | Quoted evidence sufficient? | Independent rationale |
|---|---|---|---|
| h01 | Yes: suggest | Yes | Adjustable lamps for the public library reading room directly match the renovation. Quote establishes relationship, though it omits purchase approval. |
| h02 | Yes: abstain | N/A: no quote | Beacon is explicitly a dog; collar purchase is unrelated to the library. |
| h03 | Yes: suggest | Yes | Clinic booking-system cancellation reminder directly matches the brief. |
| h04 | Yes: abstain | N/A: no quote | Flowers for the receptionist’s home, explicitly not a booking-system change. |
| h05 | Yes: suggest | Yes, with minor standalone-context limitation | Named project and historian interview publication/editing match the podcast. Quote omits “For Mistral,” but substantive detail remains sufficient in context. |
| h06 | **No: suggest unsupported** | **No; quote contradicts suggestion** | Hypothetical podcast, explicitly no planned project. Topic similarity does not establish an actual relationship to Mistral. |
| h07 | Yes: suggest | Yes | Canceling replacement and approving leak repair directly concern the rooftop tank repair. Negation applies to replacement, not the relationship. |
| h08 | Yes: abstain | N/A: no quote | Explicit ambiguity between roof repair and software service. Insufficient disambiguating evidence. |
| h09 | Yes: suggest | Yes | Bicycle rental reservation app deposit refunds directly match the brief. Quote omits assignee but supports relationship. |
| h10 | **No: suggest unsupported** | **No** | Transcript contains prompt injection instructing a suggestion; substantive discussion is bread. Neither injection nor quoted bread discussion supports the project relationship. |
| h11 | Yes: suggest | Yes | Named project, wheelchair route, botanic garden guides and opening-day use directly match. |
| h12 | **No: suggest unsupported** | **No; quote identifies a different venue** | Airport wheelchair route is explicitly a different project; transcript also excludes Marigold. |
| h13 | Yes: suggest | Yes | Weatherproof mesh for the wildlife rescue aviary directly matches refurbishment. |
| h14 | Yes: abstain | N/A: no quote | Kestrel logo on a baseball cap is a name collision, not aviary work. |
| h15 | Yes: suggest | Yes | New handrails for the riverside footbridge directly match restoration. Quote omits installation timing, irrelevant to relationship sufficiency. |
| h16 | Yes: abstain | N/A: no quote | Explicitly unresolved footbridge-versus-model-railway ambiguity. |
| h17 | **No: abstain unsupported by available content** | N/A: no quote | Caption verification for the village photo archive directly matches the brief. Pizza is irrelevant distraction, not grounds to abstain. |
| h18 | Yes: abstain | N/A: no quote | Bathroom tile cleaning, expressly not archive work. |
| h19 | Yes: suggest | Yes, with minor standalone-context limitation | Named project, vendor registration, permits and stall booking match the portal. Quote omits “For Solstice,” but functional overlap sufficiently supports relationship in context. |
| h20 | Yes: abstain | N/A: no quote | Astronomy plus a fictional imagined portal, explicitly no planned work. No substantive project relationship established. |

**Limitations**
- These are explicitly `syntheticRawOutput` examples. This review assesses supplied decisions, not observed live-model performance.
- No neutral formal decision rubric was included. I used the ordinary substantive-project-relationship interpretation above; probabilistic thresholds and permitted abstention policy were unavailable.
- All supplied suggestion quotes are literal source substrings, including the three semantically unsupported ones. Exact quotation alone does not establish support.
- Judgments are high confidence under that interpretation. They do not independently establish holdout isolation, real-world quality, calibration, production readiness, or performance on longer/noisier transcripts.

## Preservation note

The adjudication above is the original blind report, preserved verbatim after the initial read-only review. “No files modified” describes that original review. This standalone report was subsequently saved at the parent’s request, outside the repository working tree. No labels or additional evidence were read while preserving it.
