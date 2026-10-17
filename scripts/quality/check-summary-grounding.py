#!/usr/bin/env python3
"""Validate diagnostic source quotations, not semantic entailment or accuracy."""
import argparse
import hashlib
import json
from pathlib import Path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def qwen_final_answer(raw):
    # The pinned Qwen template opens <think> in the generation prefix.
    # Refuse missing/ambiguous boundaries; never pass scratch text as an answer.
    if raw.count("</think>") != 1:
        raise ValueError("missing or ambiguous reasoning boundary")
    return raw.split("</think>", 1)[1].strip()


def validate(raw, lines):
    payload = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(payload, dict) or set(payload) != {"facts", "actions"}:
        raise ValueError("expected facts and actions only")
    covered = set()
    for kind in ("facts", "actions"):
        if not isinstance(payload[kind], list):
            raise ValueError(f"{kind} must be an array")
        for item in payload[kind]:
            fields = {"claim", "evidence"} if kind == "facts" else {"owner", "task", "evidence"}
            if not isinstance(item, dict) or set(item) != fields:
                raise ValueError(f"invalid {kind} entry")
            for field in fields - {"evidence"}:
                if not isinstance(item[field], str) or not item[field].strip():
                    raise ValueError(f"empty or invalid {field}")
            evidence = item["evidence"]
            if not isinstance(evidence, list) or not evidence:
                raise ValueError("missing evidence")
            cited_speakers = set()
            for citation in evidence:
                if not isinstance(citation, dict) or set(citation) != {"utterance", "quote"}:
                    raise ValueError("invalid evidence entry")
                index, quote = citation["utterance"], citation["quote"]
                if type(index) is not int or not 1 <= index <= len(lines):
                    raise ValueError("unknown utterance")
                if not isinstance(quote, str) or not quote.strip() or quote not in lines[index - 1]["text"]:
                    raise ValueError("quotation is not an exact source substring")
                cited_speakers.add(lines[index - 1]["speaker"])
                if kind == "facts":
                    covered.add(index)
            if kind == "actions" and item["owner"] not in cited_speakers:
                raise ValueError("action owner has no cited utterance")
    if not payload["facts"]:
        raise ValueError("empty factual summary")
    return payload, sorted(covered)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", type=Path)
    parser.add_argument("responses", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--qwen-reasoning", action="store_true",
                        help="Require the pinned Qwen reasoning boundary and validate only its final answer")
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())
    responses = json.loads(args.responses.read_text())
    if not isinstance(cases, list) or not cases or not isinstance(responses, list):
        raise ValueError("nonempty case inventory required")
    expected = {case["id"]: case for case in cases}
    ids = [row["id"] for row in responses]
    if len(expected) != len(cases) or len(ids) != len(set(ids)) or set(ids) != set(expected):
        raise ValueError("case inventory mismatch")
    rows = []
    for response in responses:
        case = expected[response["id"]]
        row = {"id": case["id"], "sourceEvidenceValid": False, "ownerCountMatches": False}
        try:
            if response.get("stopReason") != "complete":
                raise ValueError("generation did not report normal completion")
            raw = qwen_final_answer(response["raw"]) if args.qwen_reasoning else response["raw"]
            payload, covered = validate(raw, case["lines"])
            row.update(sourceEvidenceValid=True, coveredUtterances=covered,
                       uncitedUtterances=sorted(set(range(1, len(case["lines"]) + 1)) - set(covered)),
                       ownerCountMatches=sorted(x["owner"].lower() for x in payload["actions"]) ==
                       sorted(x.lower() for x in case["actors"]), payload=payload)
        except (ValueError, TypeError, KeyError) as error:
            row["error"] = str(error)
        rows.append(row)
    report = {
        "scope": "Exact-source evidence and ownership checks only. Valid quotations do not prove claims, acceptance, completeness or semantic entailment.",
        "sha256": {"checker": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   "cases": hashlib.sha256(args.cases.read_bytes()).hexdigest(),
                   "responses": hashlib.sha256(args.responses.read_bytes()).hexdigest()},
        "qwenReasoning": args.qwen_reasoning,
        "results": rows,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Exact evidence valid: {sum(x['sourceEvidenceValid'] for x in rows)}/{len(rows)}")
    print(f"Evidence and ownership: {sum(x['sourceEvidenceValid'] and x['ownerCountMatches'] for x in rows)}/{len(rows)}")
    if not all(x["sourceEvidenceValid"] and x["ownerCountMatches"] for x in rows):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
