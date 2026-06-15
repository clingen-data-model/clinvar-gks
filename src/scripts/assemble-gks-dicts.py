#!/usr/bin/env python3
"""
Assemble GKS dictionary NDJSON files into a single keyed JSON file.

Supports reading from local files or streaming directly from GCS.

Usage:
  # From local files
  python3 assemble-gks-dicts.py ./gks-dicts/ ./clinvar-gks.json.gz

  # Stream from GCS (no download needed — run in Cloud Shell for best perf)
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/2026-05-10/ ./clinvar-gks.json.gz

  # Stream from GCS and upload result to GCS
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/2026-05-10/ gs://bucket/release/clinvar-gks.json.gz

Dependencies:
  pip install orjson  # optional, 10-50x faster JSON; falls back to stdlib json
"""
import gzip
import io
import subprocess
import sys
import time
from fnmatch import fnmatch
from pathlib import Path

try:
    import orjson

    def json_loads(s):
        return orjson.loads(s)

    def json_dumps_key(key):
        return orjson.dumps(key).decode()

    def json_dumps_value(value):
        return orjson.dumps(value).decode()

except ImportError:
    import json

    def json_loads(s):
        return json.loads(s)

    def json_dumps_key(key):
        return json.dumps(key)

    def json_dumps_value(value):
        return json.dumps(value, separators=(",", ":"))


# Dictionary sections in output order.
# Each tuple is (section_name, glob_pattern, key_field, value_field).
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

WRITE_BUFFER_SIZE = 8 * 1024 * 1024  # 8MB write buffer


def list_gcs_files(gcs_prefix):
    """List files in a GCS prefix."""
    result = subprocess.run(
        ["gsutil", "ls", gcs_prefix],
        capture_output=True, text=True, check=True,
    )
    return [line.strip() for line in result.stdout.strip().split("\n") if line.strip()]


def open_gcs_file(gcs_path):
    """Stream a GCS file via gcloud storage cat with auto-decompression."""
    # --raw avoids transcoding; pipe through zcat if gzipped
    if gcs_path.endswith(".gz"):
        proc = subprocess.Popen(
            f'gcloud storage cat "{gcs_path}" | zcat',
            shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
    else:
        proc = subprocess.Popen(
            ["gcloud", "storage", "cat", gcs_path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
    return io.TextIOWrapper(proc.stdout, encoding="utf-8")


def open_local_file(path):
    """Open a local file, auto-detecting gzip by magic bytes."""
    with open(path, "rb") as f:
        magic = f.read(2)
    if magic == b'\x1f\x8b':
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


def resolve_files(source, glob_pattern):
    """
    Resolve files matching a glob pattern from local dir or GCS prefix.
    Returns list of (path_or_uri, opener_fn) tuples.
    """
    if source.startswith("gs://"):
        prefix = source.rstrip("/") + "/"
        all_files = list_gcs_files(prefix)
        # Match the glob pattern against the filename portion
        matched = []
        for uri in all_files:
            filename = uri.split("/")[-1]
            if fnmatch(filename, glob_pattern):
                matched.append(uri)
        return sorted(matched), open_gcs_file
    else:
        local_dir = Path(source)
        files = sorted(local_dir.glob(glob_pattern))
        return [str(f) for f in files], open_local_file


def stream_dict(filepath, opener_fn, key_field="key", value_field="value"):
    """Yield (key, value) pairs from an NDJSON file."""
    with opener_fn(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json_loads(line)
            key = rec[key_field]

            if value_field is None:
                value = rec
            else:
                raw = rec[value_field]
                if isinstance(raw, str):
                    value = json_loads(raw)
                else:
                    value = raw

            yield key, value


def open_output(output_path):
    """Open output file — supports local or GCS paths."""
    if output_path.startswith("gs://"):
        # Pipe through gsutil cp
        proc = subprocess.Popen(
            ["gsutil", "cp", "-", output_path],
            stdin=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        if output_path.endswith(".gz"):
            return gzip.open(proc.stdin, "wt", encoding="utf-8"), proc
        return io.TextIOWrapper(proc.stdin, encoding="utf-8"), proc
    else:
        is_gzip = output_path.endswith(".gz")
        opener = gzip.open if is_gzip else open
        return opener(output_path, "wt", encoding="utf-8"), None


def assemble(source, output_path):
    """Assemble all dictionary NDJSON files into a single keyed JSON file."""
    section_count = 0
    total_entries = 0
    start_time = time.time()

    out, proc = open_output(output_path)
    buf = io.StringIO()

    try:
        buf.write("{\n")

        first_section = True
        for section_name, glob_pattern, key_field, value_field in SECTIONS:
            files, opener_fn = resolve_files(source, glob_pattern)
            if not files:
                print(f"  Skipping {section_name} (no files matching {glob_pattern})")
                continue

            if not first_section:
                buf.write(",\n")
            first_section = False

            section_start = time.time()
            print(f"  Assembling {section_name} from {len(files)} file(s)...", end="", flush=True)
            buf.write(f'  "{section_name}": {{\n')

            entry_count = 0
            first_entry = True
            for filepath in files:
                for key, value in stream_dict(filepath, opener_fn, key_field, value_field):
                    if not first_entry:
                        buf.write(",\n")
                    first_entry = False
                    buf.write(f"    {json_dumps_key(key)}: {json_dumps_value(value)}")
                    entry_count += 1

                    # Flush buffer periodically
                    if buf.tell() >= WRITE_BUFFER_SIZE:
                        out.write(buf.getvalue())
                        buf.seek(0)
                        buf.truncate()

            buf.write("\n  }")
            section_count += 1
            total_entries += entry_count
            elapsed = time.time() - section_start
            print(f" {entry_count:,} entries ({elapsed:.1f}s)")

        buf.write("\n}\n")
        out.write(buf.getvalue())

    finally:
        out.close()
        if proc:
            proc.wait()

    elapsed = time.time() - start_time
    print(f"\nDone: {section_count} sections, {total_entries:,} total entries in {elapsed:.1f}s -> {output_path}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    source = sys.argv[1]
    output_path = sys.argv[2]

    if not source.startswith("gs://") and not Path(source).is_dir():
        print(f"Error: {source} is not a directory or GCS path")
        sys.exit(1)

    print(f"Assembling GKS dictionaries from {source}")
    if "orjson" in sys.modules:
        print("  Using orjson for fast JSON processing")
    else:
        print("  Using stdlib json (pip install orjson for 10-50x speedup)")
    assemble(source, output_path)


if __name__ == "__main__":
    main()
