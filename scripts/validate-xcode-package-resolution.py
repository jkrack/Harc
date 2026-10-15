#!/usr/bin/env python3
"""Allow only Xcode's Sparkle addition under the checked-in project requirement."""

import json
from pathlib import Path
import re
import sys


SPARKLE_URL = "https://github.com/sparkle-project/Sparkle"


def stable_version(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value
    ):
        raise ValueError("Sparkle must resolve to a stable three-component version")
    return tuple(map(int, value.split(".")))


def sparkle_requirement(project):
    # Read only the supported XcodeGen declaration. Unknown requirements or
    # additional options fail closed instead of guessing at YAML semantics.
    sections = re.findall(r"^packages:\s*\n((?:^[ \t].*\n|^\s*\n)*)", project, re.M)
    if len(sections) != 1:
        raise ValueError("expected one packages section in project.yml")
    blocks = re.findall(r"^  Sparkle:\s*\n((?:^    .*\n|^\s*\n)*)", sections[0], re.M)
    if len(blocks) != 1:
        raise ValueError("expected one Sparkle declaration in project.yml")
    fields = {}
    for line in blocks[0].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(
            r'''    (url|from):\s*(?:"([^"]*)"|'([^']*)'|([^\s#'\"]+))(?:\s+#.*)?\s*''', line
        )
        if not match or match[1] in fields:
            raise ValueError("unsupported or ambiguous Sparkle requirement")
        fields[match[1]] = next(value for value in match.groups()[1:] if value is not None)
    if set(fields) != {"url", "from"} or fields["url"] != SPARKLE_URL:
        raise ValueError("expected the official Sparkle URL and a from requirement")
    return stable_version(fields["from"])


def validate(committed, working, project):
    minimum = sparkle_requirement(project)
    if not isinstance(committed.get("pins"), list) or not isinstance(working.get("pins"), list):
        raise ValueError("both lockfiles must contain pin arrays")
    if any(pin.get("identity") == "sparkle" for pin in committed["pins"]):
        raise ValueError("the committed SwiftPM lockfile must not contain Sparkle")
    sparkle = [pin for pin in working["pins"] if pin.get("identity") == "sparkle"]
    if len(sparkle) != 1:
        raise ValueError("expected exactly one added Sparkle pin")
    pin = sparkle[0]
    if (set(pin) != {"identity", "kind", "location", "state"}
            or pin["kind"] != "remoteSourceControl" or pin["location"] != SPARKLE_URL):
        raise ValueError("unexpected Sparkle source or pin fields")
    state = pin["state"]
    if (not isinstance(state, dict) or set(state) != {"revision", "version"}
            or not isinstance(state["revision"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", state["revision"])):
        raise ValueError("Sparkle must have one version and a full revision, without branch drift")
    version = stable_version(state["version"])
    # XcodeGen's `from` is SwiftPM's up-to-next-major requirement, not an exact pin.
    if not minimum <= version < (minimum[0] + 1, 0, 0):
        raise ValueError("Sparkle version is outside project.yml's from requirement")
    if "originHash" in working and not (
        isinstance(working["originHash"], str)
        and re.fullmatch(r"[0-9a-f]{64}", working["originHash"])
    ):
        raise ValueError("malformed generated originHash")
    expected = {key: value for key, value in committed.items() if key != "originHash"}
    actual = {key: value for key, value in working.items() if key != "originHash"}
    actual["pins"] = [pin for pin in working["pins"] if pin.get("identity") != "sparkle"]
    if actual != expected:
        raise ValueError("dependency drift beyond the Xcode-only Sparkle addition")
    return state["version"]


def main():
    if len(sys.argv) != 4:
        print("usage: validate-xcode-package-resolution.py COMMITTED WORKING PROJECT", file=sys.stderr)
        return 64
    try:
        version = validate(
            json.loads(Path(sys.argv[1]).read_text()),
            json.loads(Path(sys.argv[2]).read_text()),
            Path(sys.argv[3]).read_text(),
        )
    except (ValueError, TypeError, KeyError, AttributeError, OSError) as error:
        print(f"Package.resolved rejected: {error}", file=sys.stderr)
        return 1
    print(f"Verified Xcode-only Sparkle {version} against project.yml; other pins unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
