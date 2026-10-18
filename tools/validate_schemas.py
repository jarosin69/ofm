"""Validate OFM payload schemas against example payloads.

For every schema schemas/<name>.schema.json (except common), every file in
tests/schemas/<name>/valid/ must pass and every file in
tests/schemas/<name>/invalid/ must fail. Exit code 0 = all checks passed.

Run from the repository root (no local Python needed):
    docker run --rm -v ${PWD}:/repo -w /repo python:3.12-slim `
      sh -c "pip install -q jsonschema && python tools/validate_schemas.py"
"""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent.parent
SCHEMAS = ROOT / "schemas"
EXAMPLES = ROOT / "tests" / "schemas"


def load(path: Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def main() -> int:
    schemas = {p.name.removesuffix(".schema.json"): load(p)
               for p in sorted(SCHEMAS.glob("*.schema.json"))}
    registry = Registry().with_resources(
        (s["$id"], Resource.from_contents(s)) for s in schemas.values())

    failures = 0
    checked = 0
    for name, schema in schemas.items():
        Draft202012Validator.check_schema(schema)  # the schema itself is well-formed
        if name == "common":
            continue
        validator = Draft202012Validator(schema, registry=registry)
        folder = EXAMPLES / name
        if not any(folder.glob("valid/*.json")):
            print(f"FAIL  {name}: no valid examples in {folder.relative_to(ROOT)}")
            failures += 1
        for expect_valid in (True, False):
            sub = "valid" if expect_valid else "invalid"
            for example in sorted(folder.glob(f"{sub}/*.json")):
                errors = list(validator.iter_errors(load(example)))
                ok = (not errors) if expect_valid else bool(errors)
                checked += 1
                rel = example.relative_to(ROOT)
                if ok:
                    print(f"ok    {rel}")
                else:
                    failures += 1
                    detail = errors[0].message if errors else "accepted, but should be rejected"
                    print(f"FAIL  {rel}: {detail}")

    print(f"\n{checked} examples checked, {failures} failure(s).")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
