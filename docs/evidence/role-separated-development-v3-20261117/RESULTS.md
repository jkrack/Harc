# Frozen role-separated development result

Reviewed policy/code28e1e5d (b5a5ceb adds only preserved prior blind report) ran once
on eight new synthetic development cases. Actual policy SHA matches the frozen
38e499ce710ee345fc8e6511f79de5052c0472b3790831ea3e6c827d7495d310.

- Relation:4TP,1FP,0FN; precision80%, recall100%.
- Five valid suggestions, three abstentions; all source/parser valid and normal
  stop. No unsupported quote or runtime failure observed.
- Anchor-qualified:2TP; precision40%, recall50%; two positive suggestions omitted
  required anchors. These are separate from relation classification.
- d06 remains a source-injection false positive. System-role separation did NOT
  eliminate the demonstrated risk. No UI activation or automatic assignment.
- Runtime XCTest passed120.424s; scoped resident/scratch cleanup assertions passed,
  scratch0B afterwards and69% system memory free. Full test invocation also emitted
  CoreData XPC connection warnings after the selected test; these were not a
  failed selected test or evidence of semantic quality.

Raw synthetic responses retained. No changes to policy after outputs. Independently
authored24-case challenge inputs released only after policy review/freeze; input
SHA a2a870aaa54476c6199676d6a9930bc30f553fe13314aa14d7b3ad9029816338.
Gold remains withheld until outputs are locked. Challenge name Lumen overlaps v1;
call it independently authored challenge, not wholly unseen project names. Role
and wording both changed, so results cannot isolate a causal role-separation gain.
