#!/usr/bin/env python3
"""
Assemble GKS dictionary NDJSON files into a single keyed JSON file.

For GCS sources, shards are downloaded one section at a time and deleted
after each section is processed, keeping disk usage minimal.

Output is written locally to /tmp/clinvar-gks-{date}.json.gz.
Source files are removed after successful assembly unless --keep-source is used.

Usage:
  # From GCS (section-by-section download to minimise disk usage)
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03

  # Also copy the bundle to GCS after assembly
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03 --copy-to-gcs

  # Keep source files for debugging
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03 --keep-source

  # From local files
  python3 assemble-gks-dicts.py ./gks-dicts/ 2026-05-03

Dependencies:
  pip install orjson  # optional, 10-50x faster JSON; falls back to stdlib json
"""
import argparse
import gzip
import re
import shutil
import subprocess
import sys
import tempfile
import time
from fnmatch import fnmatch
from pathlib import Path

try:
    import orjson

    def json_loads(s):
        return orjson.loads(s)

    def json_dumps_key(key):
        return orjson.dumps(key).decode()

except ImportError:
    import json

    def json_loads(s):
        return json.loads(s)

    def json_dumps_key(key):
        return json.dumps(key)


# Dictionary sections in output order.
# Each tuple is (section_name, glob_pattern, key_field, value_field).
SECTIONS = [
    ("sequenceReference", "sequenceReference-*.ndjson.gz", "key", "value"),
    ("location", "location-*.ndjson.gz", "key", "value"),
    ("allele", "allele-*.ndjson.gz", "key", "value"),
    ("gene", "gene-*.ndjson.gz", "key", "value"),
    ("variation", "variation-*.ndjson.gz", "id", None),
    ("condition", "condition-*.ndjson.gz", "id", None),
    ("conditionSet", "conditionSet-*.ndjson.gz", "id", None),
    ("submitter", "submitter-*.ndjson.gz", "key", "value"),
    ("proposition", ["proposition-*.ndjson.gz", "vcv_proposition-*.ndjson.gz", "rcv_proposition-*.ndjson.gz"], "key", "value"),
    ("scv", "scv-*.ndjson.gz", "id", None),
    ("vcv", "vcv-*.ndjson.gz", "id", None),
    ("rcv", "rcv-*.ndjson.gz", "id", None),
]

WRITE_BUFFER_SIZE = 8 * 1024 * 1024  # 8MB write buffer
GZIP_COMPRESS_LEVEL = 3  # faster than default 9, minimal size difference on JSON


def list_gcs_files(gcs_prefix):
    """List all files under a GCS prefix."""
    result = subprocess.run(
        ["gsutil", "ls", gcs_prefix.rstrip("/") + "/"],
        capture_output=True, text=True, check=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def match_gcs_files(all_gcs_files, glob_patterns):
    """Filter GCS file URIs by glob pattern(s)."""
    if isinstance(glob_patterns, str):
        glob_patterns = [glob_patterns]
    return sorted(
        uri for uri in all_gcs_files
        if any(fnmatch(uri.split("/")[-1], p) for p in glob_patterns)
    )


def download_files(gcs_uris, local_dir):
    """Download specific GCS URIs to a local directory in parallel."""
    subprocess.run(
        ["gsutil", "-m", "-q", "cp"] + gcs_uris + [local_dir + "/"],
        check=True,
    )
    return sorted(str(f) for f in Path(local_dir).glob("*.ndjson.gz"))


def resolve_local_files(local_dir, glob_patterns):
    """Resolve files matching glob pattern(s) from a local directory."""
    if isinstance(glob_patterns, str):
        glob_patterns = [glob_patterns]
    matched = []
    for pattern in glob_patterns:
        matched.extend(Path(local_dir).glob(pattern))
    return sorted(set(str(f) for f in matched))


def open_local_file(path):
    """Open a local file, auto-detecting gzip by magic bytes."""
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic == b'\x1f\x8b':
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def stream_passthrough(filepath, key_field):
    """
    Yield (key_json, raw_line) pairs. Parses only the key field;
    passes the raw JSON line through as the value to avoid re-serialization.
    """
    with open_local_file(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            yield json_dumps_key(rec[key_field]), line


def stream_kv(filepath, key_field, value_field):
    """
    Yield (key_json, value_json) pairs from key/value NDJSON records.
    String values are passed through directly without re-serialization.
    """
    with open_local_file(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            key_json = json_dumps_key(rec[key_field])
            raw = rec[value_field]
            value_json = raw if isinstance(raw, str) else json_dumps_key(raw)
            yield key_json, value_json


def open_output(output_path):
    """Open output file for writing."""
    if output_path.endswith(".gz"):
        return gzip.open(output_path, "wb", compresslevel=GZIP_COMPRESS_LEVEL)
    return open(output_path, "wb")


def assemble(source, output_path, is_gcs):
    """
    Assemble all dictionary NDJSON sections into a single keyed JSON file.
    For GCS sources, downloads one section at a time to minimise disk usage.
    """
    section_count = 0
    total_entries = 0
    start_time = time.time()

    # List GCS files once upfront
    all_gcs_files = list_gcs_files(source) if is_gcs else []

    out = open_output(output_path)
    buf = bytearray()

    try:
        buf.extend(b"{\n")
        first_section = True

        for section_name, glob_pattern, key_field, value_field in SECTIONS:
            section_tmp = None
            try:
                if is_gcs:
                    matched_uris = match_gcs_files(all_gcs_files, glob_pattern)
                    if not matched_uris:
                        print(f"  Skipping {section_name} (no files matching {glob_pattern})")
                        continue
                    section_tmp = tempfile.mkdtemp(prefix=f"gks-{section_name[:6]}-")
                    local_files = download_files(matched_uris, section_tmp)
                else:
                    local_files = resolve_local_files(source, glob_pattern)
                    if not local_files:
                        print(f"  Skipping {section_name} (no files matching {glob_pattern})")
                        continue

                if not first_section:
                    buf.extend(b",\n")
                first_section = False

                section_start = time.time()
                print(
                    f"  Assembling {section_name} from {len(local_files)} file(s)...",
                    end="", flush=True,
                )
                buf.extend(f'  "{section_name}": {{\n'.encode())

                entry_count = 0
                first_entry = True

                if value_field is None:
                    for filepath in local_files:
                        for key_json, raw_json in stream_passthrough(filepath, key_field):
                            if not first_entry:
                                buf.extend(b",\n")
                            first_entry = False
                            buf.extend(f"    {key_json}: {raw_json}".encode())
                            entry_count += 1
                            if len(buf) >= WRITE_BUFFER_SIZE:
                                out.write(bytes(buf))
                                buf.clear()
                else:
                    for filepath in local_files:
                        for key_json, value_json in stream_kv(filepath, key_field, value_field):
                            if not first_entry:
                                buf.extend(b",\n")
                            first_entry = False
                            buf.extend(f"    {key_json}: {value_json}".encode())
                            entry_count += 1
                            if len(buf) >= WRITE_BUFFER_SIZE:
                                out.write(bytes(buf))
                                buf.clear()

                buf.extend(b"\n  }")
                section_count += 1
                total_entries += entry_count
                elapsed = time.time() - section_start
                print(f" {entry_count:,} entries ({elapsed:.1f}s)")

            finally:
                # Delete section shards immediately after processing
                if section_tmp:
                    shutil.rmtree(section_tmp, ignore_errors=True)

        buf.extend(b"\n}\n")
        out.write(bytes(buf))

    finally:
        out.close()

    elapsed = time.time() - start_time
    print(
        f"\nDone: {section_count} sections, "
        f"{total_entries:,} total entries in {elapsed:.1f}s"
        f" -> {output_path}"
    )


def derive_output_path(date):
    """Derive local output path from date."""
    return str(Path("/tmp") / f"clinvar-gks-{date}.json.gz")


def derive_gcs_path(source, date):
    """Derive GCS output path from source bucket and date."""
    bucket = source.split("/")[2]
    return f"gs://{bucket}/{date}/release/clinvar-gks-{date}.json.gz"


def cleanup_source(source):
    """Remove the source directory after successful assembly."""
    print(f"\nCleaning up source: {source}")
    if source.startswith("gs://"):
        subprocess.run(["gsutil", "-m", "rm", "-r", source], check=True)
    else:
        shutil.rmtree(source)
    print("  Source removed.")


def main():
    parser = argparse.ArgumentParser(
        description="Assemble GKS dictionary NDJSON files into a single keyed JSON file.",
    )
    parser.add_argument("source", help="Source directory (local path or gs:// URI)")
    parser.add_argument("date", help="ClinVar release date (YYYY-MM-DD)")
    parser.add_argument(
        "--keep-source", action="store_true",
        help="Keep source files after assembly (for debugging)",
    )
    parser.add_argument(
        "--copy-to-gcs", action="store_true",
        help="Copy the assembled bundle to GCS after local assembly",
    )
    args = parser.parse_args()

    if not re.match(r"^\d{4}-\d{2}-\d{2}$", args.date):
        parser.error(f"date must be YYYY-MM-DD format, got '{args.date}'")

    source = args.source
    is_gcs = source.startswith("gs://")

    if not is_gcs and not Path(source).is_dir():
        parser.error(f"{source} is not a directory or GCS path")

    output_path = derive_output_path(args.date)

    print(f"Assembling GKS dictionaries from {source}")
    print(f"  Output: {output_path}")
    print(f"  Using {'orjson' if 'orjson' in sys.modules else 'stdlib json (pip install orjson for 10-50x speedup)'}")

    assemble(source, output_path, is_gcs)

    if args.copy_to_gcs and is_gcs:
        gcs_path = derive_gcs_path(source, args.date)
        print(f"\nCopying bundle to GCS: {gcs_path}")
        subprocess.run(["gsutil", "-q", "cp", output_path, gcs_path], check=True)
        print("  Done.")

    if not args.keep_source:
        cleanup_source(source)
    else:
        print(f"\n  Source retained: {source}")


if __name__ == "__main__":
    main()
