#!/usr/bin/env python3
"""
Assemble GKS dictionary NDJSON files into a single keyed JSON file.

Supports reading from local files or GCS. For GCS sources, shards are
bulk-downloaded in parallel first, then processed locally.

Output is placed in {bucket}/{date}/release/clinvar-gks-{date}.json.gz.
Source files are removed after successful assembly unless --keep-source is used.

Usage:
  # From GCS (shards downloaded in parallel, then assembled locally)
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03

  # Keep source files for debugging
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03 --keep-source

  # From local files (output goes to ./2026-05-03/release/)
  python3 assemble-gks-dicts.py ./gks-dicts/ 2026-05-03

Dependencies:
  pip install orjson  # optional, 10-50x faster JSON; falls back to stdlib json
"""
import argparse
import gzip
import io
import os
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


def download_gcs_shards(gcs_prefix, local_dir):
    """Bulk-download all shards from GCS to a local directory using parallel transfers."""
    print(f"  Downloading shards from {gcs_prefix} ...")
    start = time.time()
    subprocess.run(
        ["gsutil", "-m", "-q", "cp", "-r", gcs_prefix, local_dir],
        check=True,
    )
    elapsed = time.time() - start
    count = sum(1 for f in Path(local_dir).rglob("*.ndjson.gz"))
    print(f"  Downloaded {count} files in {elapsed:.1f}s")
    return local_dir


def open_local_file(path):
    """Open a local file, auto-detecting gzip by magic bytes."""
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic == b'\x1f\x8b':
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def resolve_local_files(local_dir, glob_patterns):
    """Resolve files matching glob pattern(s) from a local directory."""
    if isinstance(glob_patterns, str):
        glob_patterns = [glob_patterns]
    matched = []
    local_path = Path(local_dir)
    for pattern in glob_patterns:
        matched.extend(local_path.glob(pattern))
    return sorted(set(str(f) for f in matched))


def stream_passthrough(filepath, key_field):
    """
    Yield (key_json, raw_value_json) from an NDJSON file.
    Parses only to extract the key; the entire raw line is the value.
    Avoids the parse-then-reserialize roundtrip.
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
    Yield (key_json, value_json) from an NDJSON file with key/value fields.
    For string values, passes through the raw JSON string.
    For object values, passes through after a single serialize.
    """
    with open_local_file(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            key_json = json_dumps_key(rec[key_field])
            raw = rec[value_field]
            if isinstance(raw, str):
                # Already a JSON string — pass through directly
                value_json = raw
            else:
                value_json = json_dumps_key(raw)  # works for any JSON value
            yield key_json, value_json


def open_output(output_path):
    """Open output file — supports local or GCS paths."""
    if output_path.startswith("gs://"):
        proc = subprocess.Popen(
            ["gsutil", "cp", "-", output_path],
            stdin=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        if output_path.endswith(".gz"):
            return gzip.open(
                proc.stdin, "wb", compresslevel=GZIP_COMPRESS_LEVEL
            ), proc
        return proc.stdin, proc
    else:
        if output_path.endswith(".gz"):
            return gzip.open(
                output_path, "wb", compresslevel=GZIP_COMPRESS_LEVEL
            ), None
        return open(output_path, "wb"), None


def assemble(local_dir, output_path):
    """Assemble all dictionary NDJSON files into a single keyed JSON file."""
    section_count = 0
    total_entries = 0
    start_time = time.time()

    out, proc = open_output(output_path)
    buf = bytearray()

    try:
        buf.extend(b"{\n")

        first_section = True
        for section_name, glob_pattern, key_field, value_field in SECTIONS:
            files = resolve_local_files(local_dir, glob_pattern)
            if not files:
                print(f"  Skipping {section_name} (no files matching {glob_pattern})")
                continue

            if not first_section:
                buf.extend(b",\n")
            first_section = False

            section_start = time.time()
            print(
                f"  Assembling {section_name} from {len(files)} file(s)...",
                end="", flush=True,
            )
            buf.extend(f'  "{section_name}": {{\n'.encode())

            entry_count = 0
            first_entry = True

            if value_field is None:
                # Passthrough mode: extract key, keep raw JSON line as value
                for filepath in files:
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
                # Key/value mode: extract key and value fields
                for filepath in files:
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

        buf.extend(b"\n}\n")
        out.write(bytes(buf))

    finally:
        out.close()
        if proc:
            proc.wait()

    elapsed = time.time() - start_time
    print(
        f"\nDone: {section_count} sections, "
        f"{total_entries:,} total entries in {elapsed:.1f}s"
        f" -> {output_path}"
    )


def derive_output_path(source, date):
    """Derive output path from source bucket and date."""
    filename = f"clinvar-gks-{date}.json.gz"
    if source.startswith("gs://"):
        bucket = source.split("/")[2]
        return f"gs://{bucket}/{date}/release/{filename}"
    else:
        return str(Path(date) / "release" / filename)


def cleanup_source(source):
    """Remove the source directory after successful assembly."""
    if source.startswith("gs://"):
        print(f"\nCleaning up source: {source}")
        subprocess.run(
            ["gsutil", "-m", "rm", "-r", source],
            check=True,
        )
    else:
        print(f"\nCleaning up source: {source}")
        shutil.rmtree(source)
    print("  Source removed.")


def main():
    parser = argparse.ArgumentParser(
        description="Assemble GKS dictionary NDJSON files "
        "into a single keyed JSON file.",
    )
    parser.add_argument(
        "source",
        help="Source directory (local path or gs:// URI)",
    )
    parser.add_argument(
        "date",
        help="ClinVar release date (YYYY-MM-DD)",
    )
    parser.add_argument(
        "--keep-source",
        action="store_true",
        help="Keep source files after assembly (for debugging)",
    )
    args = parser.parse_args()

    if not re.match(r"^\d{4}-\d{2}-\d{2}$", args.date):
        parser.error(
            f"date must be YYYY-MM-DD format, got '{args.date}'"
        )

    source = args.source
    is_gcs = source.startswith("gs://")

    if not is_gcs and not Path(source).is_dir():
        parser.error(
            f"{source} is not a directory or GCS path"
        )

    output_path = derive_output_path(source, args.date)

    # Create local output directory if needed
    if not output_path.startswith("gs://"):
        Path(output_path).parent.mkdir(
            parents=True, exist_ok=True
        )

    print(f"Assembling GKS dictionaries from {source}")
    print(f"  Output: {output_path}")
    if "orjson" in sys.modules:
        print("  Using orjson for fast JSON processing")
    else:
        print(
            "  Using stdlib json "
            "(pip install orjson for 10-50x speedup)"
        )

    # For GCS sources, bulk-download shards first
    tmp_dir = None
    if is_gcs:
        tmp_dir = tempfile.mkdtemp(prefix="gks-assemble-")
        download_gcs_shards(source, tmp_dir)
        # gsutil -m cp -r creates a subdirectory; find it
        subdirs = [
            d for d in Path(tmp_dir).iterdir() if d.is_dir()
        ]
        local_dir = str(subdirs[0]) if subdirs else tmp_dir
    else:
        local_dir = source

    try:
        assemble(local_dir, output_path)
    finally:
        # Clean up temp download dir
        if tmp_dir:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    if not args.keep_source:
        cleanup_source(source)
    else:
        print(f"\n  Source retained: {source}")


if __name__ == "__main__":
    main()
