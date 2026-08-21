#!/usr/bin/env python3
"""validate-schema-conformance.py — JSON-Schema conformance check for emitted GKS records.

Validates emitted proposition (and, with --statements, statement) records against the
project's JSON Schemas in `schema/` — the clinvar-gks schemas plus the va-spec / cat-vrs /
vrs / gks-core schemas reached through the `schema/` symlinks. Cross-tree `$ref`s resolve by
`$id` via the `referencing` registry (no network access).

Records are read as NDJSON from stdin (one JSON object per line — e.g. the `value` of a
`gks_dict_*proposition` row). Each record is routed to a schema by its type:

  * `$.type == "CustomProposition"`  -> schema named by `$.customPropositionType`
  * `$.type` ending in "Proposition"  -> schema named by `$.type` (va-spec standard types)
  * with --statements, `$.type == "Statement"/"EvidenceLine"` records are skipped unless a
    `--as <SchemaName>` override is given (statements carry type "Statement", not a schema name).

Usage:
  bq query ... 'SELECT TO_JSON_STRING(value) FROM ...gks_dict_proposition LIMIT 500' \
    | python3 src/scripts/validate-schema-conformance.py

  # or against a file of NDJSON records
  python3 src/scripts/validate-schema-conformance.py < records.ndjson

Exit code is non-zero if any record fails validation.
"""
# flake8: noqa: E501
import argparse
import json
import os
import sys
from pathlib import Path

from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012
from jsonschema import Draft202012Validator

SCHEMA_ROOT = Path(__file__).resolve().parents[2] / "schema"


def relax_additional_properties(node):
    """Recursively remove `additionalProperties: false` from a schema.

    The metaschema (gks-metaschema) emits closed-world `additionalProperties: false` on each
    object even when it composes parents via `allOf`. Under JSON Schema, `additionalProperties`
    does NOT see properties contributed by sibling `allOf` subschemas, so every composed record
    is rejected for its inherited fields. `unevaluatedProperties: false` does not help either,
    because the metaschema stamps it (here) at every level of the `allOf` chain and the nested
    assertions cascade to failure. So we strip the closed-world check and validate open-world:
    this still enforces `required`, `type`, `enum`, `format`, and `$ref`-resolved nested shapes
    (e.g. a missing required `objectTherapy` is caught) but does not flag extra properties. The
    real fix belongs upstream in gks-metaschema. Pass --no-relax to keep the schemas as-is.
    """
    if isinstance(node, dict):
        if node.get("additionalProperties") is False:
            del node["additionalProperties"]
        for v in node.values():
            relax_additional_properties(v)
    elif isinstance(node, list):
        for v in node:
            relax_additional_properties(v)
    return node


def load_registry(schema_root: Path, relax: bool = True):
    """Load every JSON Schema under schema_root (following symlinks) into a referencing
    Registry keyed by $id, plus a basename->$id index for type routing."""
    resources = []
    name2contents = {}
    seen = set()
    for dirpath, dirnames, filenames in os.walk(schema_root, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen:  # guard against symlink cycles (nested submodules)
            dirnames[:] = []
            continue
        seen.add(real)
        if os.path.basename(dirpath) != "json":
            continue
        for fn in filenames:
            if fn.endswith(".md"):
                continue
            path = Path(dirpath) / fn
            try:
                doc = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            sid = doc.get("$id")
            if not sid:
                continue
            if relax:
                relax_additional_properties(doc)
            resources.append((sid, Resource.from_contents(doc, default_specification=DRAFT202012)))
            # first one wins on name collision; clinvar-gks names are unique vs va-spec
            name2contents.setdefault(fn, doc)
    registry = Registry().with_resources(resources)
    return registry, name2contents


def schema_name_for(record):
    """Return the schema (type) name a record should validate against, or None to skip."""
    t = record.get("type")
    if t == "CustomProposition":
        return record.get("customPropositionType")
    if isinstance(t, str) and t.endswith("Proposition"):
        return t
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--schema-root", type=Path, default=SCHEMA_ROOT)
    ap.add_argument("--max-errors", type=int, default=20, help="max failing records to print")
    ap.add_argument("--as", dest="force_schema", default=None,
                    help="validate every record against this schema name (override routing)")
    ap.add_argument("--no-relax", action="store_true",
                    help="keep additionalProperties:false as-is (will reject allOf-inherited props)")
    args = ap.parse_args()

    registry, name2contents = load_registry(args.schema_root, relax=not args.no_relax)
    validators = {}

    def validator_for(name):
        if name not in validators:
            schema = name2contents.get(name)
            if schema is None:
                validators[name] = None
            else:
                validators[name] = Draft202012Validator(schema, registry=registry)
        return validators[name]

    from collections import Counter

    total = validated = skipped = failed = 0
    unknown_schema = Counter()
    fail_by_type = Counter()
    signatures = Counter()          # (schema, path-template, message-head) -> count
    sig_example = {}                # signature -> example record id

    def path_template(err):
        # replace array indices with * so distinct rows collapse to one signature
        parts = ["*" if isinstance(p, int) else str(p) for p in err.absolute_path]
        return "/".join(parts) or "(root)"

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        total += 1
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as e:
            failed += 1
            sig = ("<parse>", "", str(e)[:80])
            signatures[sig] += 1
            sig_example.setdefault(sig, line[:60])
            continue
        name = args.force_schema or schema_name_for(rec)
        if name is None:
            skipped += 1
            continue
        v = validator_for(name)
        if v is None:
            unknown_schema[name] += 1
            skipped += 1
            continue
        errors = list(v.iter_errors(rec))
        validated += 1
        if errors:
            failed += 1
            fail_by_type[name] += 1
            rid = rec.get("id", "<no id>")
            for err in errors:
                sig = (name, path_template(err), err.message.split(" under ")[0][:90])
                signatures[sig] += 1
                sig_example.setdefault(sig, rid)

    print("\n" + "=" * 72)
    print(f"records read:      {total}")
    print(f"validated:         {validated}")
    print(f"skipped (no type): {skipped}")
    if unknown_schema:
        print(f"unknown schema (skipped): {dict(unknown_schema)}")
    print(f"records FAILED:     {failed}")
    if fail_by_type:
        print(f"failures by type:  {dict(sorted(fail_by_type.items()))}")
    if signatures:
        print("\ndistinct error signatures (schema | path | message  ->  count  e.g.):")
        for (name, path, msg), n in signatures.most_common(args.max_errors):
            print(f"  [{n:>6}] {name} | {path} | {msg}   (e.g. {sig_example[(name, path, msg)]})")
    print("=" * 72)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
