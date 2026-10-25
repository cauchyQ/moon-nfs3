"""Count owned MoonBit implementation and test lines with a reproducible rule."""
import argparse
import json
from pathlib import Path


def count(root):
    totals = {"library": 0, "cli": 0, "tests": 0}
    details = {}
    excluded = {".git", ".mooncakes", "_build", "target"}
    for path in sorted(root.rglob("*.mbt")):
        relative = path.relative_to(root)
        if any(part in excluded for part in relative.parts):
            continue
        category = "tests" if path.name.endswith(("_test.mbt", "_wbtest.mbt")) else (
            "cli" if relative.parts[0] == "cmd" else "library")
        in_test = False
        own = {key: 0 for key in totals}
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            value = line.strip()
            if value == "///|":
                in_test = False
            if value.startswith(("test ", "async test ", "async fn verify(")):
                in_test = True
            if value and not value.startswith("//"):
                key = "tests" if in_test else category
                own[key] += 1
                totals[key] += 1
        details[relative.as_posix()] = own
    return totals, details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-implementation", type=int, default=0)
    parser.add_argument("--details", action="store_true")
    args = parser.parse_args()
    totals, details = count(Path(__file__).resolve().parent.parent)
    implementation = totals["library"] + totals["cli"]
    print(json.dumps({"nonblank_noncomment_lines": totals,
                      "implementation": implementation,
                      "total": implementation + totals["tests"],
                      **({"files": details} if args.details else {})}, indent=2))
    if implementation < args.min_implementation:
        raise SystemExit(f"implementation {implementation} < {args.min_implementation}")


if __name__ == "__main__":
    main()
