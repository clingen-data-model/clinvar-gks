#!/usr/bin/env python3
"""
Assemble GKS dictionary NDJSON files into a single keyed JSON file.

Each input file contains rows of {"key": "...", "value": {...}} which are
assembled into a root-level keyed dictionary per section.

Usage:
  python3 assemble-gks-dicts.py <input_dir> <output_file>

Example:
  python3 assemble-gks-dicts.py ./gks-dicts/ ./clinvar-gks-2025-06-08.json.gz
"""
import gzip
import json
import sys
from pathlib import Path


# Dictionary sections in output order.
# Each tuple is (section_name, glob_pattern, key_field, value_field).
# Glob patterns match sharded exports (e.g., allele-*.ndjson.gz).
SECTIONS = [
    ("sequenceReference", "sequenceReference-*.ndjson.gz", "key", "value"),
    ("location", "location-*.ndjson.gz", "key", "value"),
    ("allele", "allele-*.ndjson.gz", "key", "value"),
    ("gene", "gene-*.ndjson.gz", "key", "value"),
    ("variation", "variation-*.ndjson.gz", "key", "value"),
    ("condition", "condition-*.ndjson.gz", "id", None),
    ("conditionSet", "conditionSet-*.ndjson.gz", "id", None),
    ("submitter", "submitter-*.ndjson.gz", "key", "value"),
    ("proposition", "proposition-*.ndjson.gz", "key", "value"),
    ("vcv_proposition", "vcv_proposition-*.ndjson.gz", "key", "value"),
    ("rcv_proposition", "rcv_proposition-*.ndjson.gz", "key", "value"),
    ("scv", "scv-*.ndjson.gz", "id", None),
    ("vcv", "vcv-*.ndjson.gz", "id", None),
    ("rcv", "rcv-*.ndjson.gz", "id", None),
]


def open_file(path):
    """Open a file, handling gzip transparently."""
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def stream_dict(ndjson_path, key_field="key", value_field="value"):
    """
    Yield (key, value_json_string) pairs from an NDJSON file.

    If value_field is None, the entire record (minus the key field) is the value.
    If value_field is specified and its content is a JSON string, it is parsed.
    """
    with open_file(ndjson_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            key = rec[key_field]

            if value_field is None:
                # Use the whole record as the value
                value = rec
            else:
                raw = rec[value_field]
                # If the value is a JSON string, parse it
                if isinstance(raw, str):
                    value = json.loads(raw)
                else:
                    value = raw

            yield key, value


def assemble(input_dir, output_path):
    """Assemble all dictionary NDJSON files into a single keyed JSON file."""
    input_dir = Path(input_dir)
    is_gzip = str(output_path).endswith(".gz")
    opener = gzip.open if is_gzip else open

    section_count = 0
    total_entries = 0

    with opener(output_path, "wt", encoding="utf-8") as out:
        out.write("{\n")

        first_section = True
        for section_name, glob_pattern, key_field, value_field in SECTIONS:
            files = sorted(input_dir.glob(glob_pattern))
            if not files:
                print(f"  Skipping {section_name} (no files matching {glob_pattern})")
                continue

            if not first_section:
                out.write(",\n")
            first_section = False

            print(f"  Assembling {section_name} from {len(files)} file(s)...")
            out.write(f'  "{section_name}": {{\n')

            entry_count = 0
            first_entry = True
            for filepath in files:
                for key, value in stream_dict(filepath, key_field, value_field):
                    if not first_entry:
                        out.write(",\n")
                    first_entry = False
                    out.write(f"    {json.dumps(key)}: {json.dumps(value, separators=(',', ':'))}")
                    entry_count += 1

            out.write("\n  }")
            section_count += 1
            total_entries += entry_count
            print(f"    -> {entry_count:,} entries")

        out.write("\n}\n")

    print(f"\nDone: {section_count} sections, {total_entries:,} total entries -> {output_path}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    input_dir = sys.argv[1]
    output_path = sys.argv[2]

    if not Path(input_dir).is_dir():
        print(f"Error: {input_dir} is not a directory")
        sys.exit(1)

    print(f"Assembling GKS dictionaries from {input_dir}")
    assemble(input_dir, output_path)


if __name__ == "__main__":
    main()
