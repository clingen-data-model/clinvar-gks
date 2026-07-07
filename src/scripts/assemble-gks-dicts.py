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

  # Write Parquet files alongside the bundle
  python3 assemble-gks-dicts.py gs://bucket/gks-dicts/ 2026-05-03 --parquet-dir=/tmp/parquet

  # From local files
  python3 assemble-gks-dicts.py ./gks-dicts/ 2026-05-03

Dependencies:
  pip install orjson  # optional, 10-50x faster JSON; falls back to stdlib json
  pip install pyarrow # optional, needed only when --parquet-dir is used
"""
import argparse
import gzip
import json
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

    def json_loads(s):
        return json.loads(s)

    def json_dumps_key(key):
        return json.dumps(key)


# pyarrow is optional — only needed when --parquet-dir is used
try:
    import pyarrow as pa
    import pyarrow.parquet as pq
    _PYARROW_AVAILABLE = True
except ImportError:
    _PYARROW_AVAILABLE = False


# Dictionary sections in output order.
# Each tuple is (section_name, glob_pattern, key_field, value_field).
SECTIONS = [
    ("sequenceReference", "sequenceReference-*.ndjson.gz", "key", "value"),
    ("location", "location-*.ndjson.gz", "key", "value"),
    ("allele", "allele-*.ndjson.gz", "key", "value"),
    ("copyNumberCount", "copyNumberCount-*.ndjson.gz", "key", "value"),
    ("copyNumberChange", "copyNumberChange-*.ndjson.gz", "key", "value"),
    ("gene", "gene-*.ndjson.gz", "key", "value"),
    ("variation", "variation-*.ndjson.gz", "id", None),
    ("condition", "condition-*.ndjson.gz", "id", None),
    ("conditionSet", "conditionSet-*.ndjson.gz", "id", None),
    ("submitter", "submitter-*.ndjson.gz", "key", "value"),
    ("proposition", ["proposition-*.ndjson.gz", "vcv_proposition-*.ndjson.gz", "rcv_proposition-*.ndjson.gz"], "key", "value"),
    ("evidenceLine", ["evidenceLine-*.ndjson.gz", "vcv_evidenceLine-*.ndjson.gz", "rcv_evidenceLine-*.ndjson.gz"], "id", None),
    ("scv", "scv-*.ndjson.gz", "id", None),
    ("vcv", "vcv-*.ndjson.gz", "id", None),
    ("rcv", "rcv-*.ndjson.gz", "id", None),
]

WRITE_BUFFER_SIZE = 8 * 1024 * 1024  # 8MB write buffer
GZIP_COMPRESS_LEVEL = 3  # faster than default 9, minimal size difference on JSON


# ---------------------------------------------------------------------------
# Parquet support (used only when --parquet-dir is passed)
# ---------------------------------------------------------------------------

PARQUET_BATCH_SIZE = 10_000

SIMPLE_COLS = ["id", "data"]


def _ref(value, prefix):
    return (value or "").removeprefix(prefix) or None


def _ref_if(value, prefix):
    """Return the ID portion only if value starts with prefix; otherwise None."""
    if value and value.startswith(prefix):
        return value[len(prefix):]
    return None


def _name(concept):
    return (concept or {}).get("name")


def _exact_pos(p):
    """Return int if p is an exact position; None if it's a range or absent."""
    if p is None or isinstance(p, list):
        return None
    return int(p)


def _range_pos(p):
    """Return {"min": int, "max": int} if p is a [min, max] range; None if exact or absent."""
    if isinstance(p, list):
        return {"min": int(p[0]), "max": int(p[1])}
    return None


def _state_len_min(state):
    """Lower bound of a state length (int or [min, max] range), as string or None."""
    length = (state or {}).get("length")
    if length is None:
        return None
    return str(length[0] if isinstance(length, list) else length)


def _state_len_max(state):
    """Upper bound of a state length (int or [min, max] range), as string or None."""
    length = (state or {}).get("length")
    if length is None:
        return None
    return str(length[1] if isinstance(length, list) else length)


def _iris(v):
    """Extract iris as a list of URI strings, or None."""
    iris = v.get("iris")
    if not iris:
        return None
    return [str(i) for i in iris]


def _coding(c):
    """Normalize a Coding object to match _CODING_TYPE, or return None."""
    if c is None:
        return None
    return {
        "id": c.get("id"),
        "name": c.get("name"),
        "code": c.get("code"),
        "system": c.get("system"),
        "system_version": c.get("systemVersion"),
        "iris": [str(i) for i in c["iris"]] if c.get("iris") else None,
        "extensions": _extensions(c),
    }


def _mappings(mappings):
    """Normalize a mappings array to match _MAPPING_TYPE, or return None."""
    if not mappings:
        return None
    return [
        {
            "coding": _coding(m.get("coding")),
            "relation": m.get("relation"),
            "extensions": _extensions(m),
        }
        for m in mappings
    ]


def _extensions(v):
    """Extract extensions as [{name: str, value: str (JSON-encoded)}] or None."""
    exts = v.get("extensions")
    if not exts:
        return None
    return [
        {
            "name": e.get("name"),
            "value": json.dumps(e["value"]) if e.get("value") is not None else None,
        }
        for e in exts
    ]


def _exprs(v):
    """Extract expressions as [{syntax, value, syntax_version}] or None."""
    exprs = v.get("expressions")
    if not exprs:
        return None
    return [
        {
            "syntax": e.get("syntax"),
            "value": e.get("value"),
            "syntax_version": e.get("syntaxVersion"),
        }
        for e in exprs
    ]


def _concept_label(c):
    """Extract classification/strength/evidenceOutcome as queryable struct, or None."""
    if c is None:
        return None
    return {
        "concept_type": c.get("conceptType") or c.get("type"),
        "name": c.get("name"),
        "primary_coding": _coding(c.get("primaryCoding")),
        "extensions": _extensions(c),
    }


def _contributions(v):
    """Extract contributions array to match _CONTRIBUTION_TYPE, or None."""
    contribs = v.get("contributions")
    if not contribs:
        return None
    return [
        {
            "type": c.get("type"),
            "contributor": _ref(c.get("contributor"), "#/submitter/"),
            "date": c.get("date"),
            "activity_type": c.get("activityType"),
        }
        for c in contribs
    ]


def _reported_in(v):
    """Extract reportedIn array to match _REPORTED_IN_TYPE, or None."""
    docs = v.get("reportedIn")
    if not docs:
        return None
    return [
        {
            "id": d.get("id"),
            "name": d.get("name"),
            "type": d.get("type"),
            "document_type": d.get("documentType"),
            "title": d.get("title"),
            "doi": d.get("doi"),
            "pmid": d.get("pmid"),
            "urls": d.get("urls") or None,
        }
        for d in docs
    ]


def _specified_by(v):
    """Extract specifiedBy struct to match _SPECIFIED_BY_TYPE, or None."""
    sb = v.get("specifiedBy")
    if sb is None:
        return None
    reported_in = sb.get("reportedIn")
    return {
        "name": sb.get("name"),
        "method_type": sb.get("methodType"),
        "type": sb.get("type"),
        "reported_in": json.dumps(reported_in) if reported_in else None,
    }


def _mappable_concept(mc):
    """Normalize a MappableConcept dict to match _MAPPABLE_CONCEPT_TYPE, or return None."""
    if mc is None:
        return None
    return {
        "id": mc.get("id"),
        "name": mc.get("name"),
        "aliases": mc.get("aliases") or None,
        "primary_coding": _coding(mc.get("primaryCoding")),
        "iris": [str(i) for i in mc["iris"]] if mc.get("iris") else None,
        "extensions": _extensions(mc),
    }


def _constraints(v):
    """Extract variation constraints array to match _CONSTRAINT_TYPE, or return None."""
    constraints = v.get("constraints")
    if not constraints:
        return None
    result = []
    for c in constraints:
        copies_val = c.get("copies")
        result.append({
            "type": c.get("type"),
            "allele": c.get("allele"),
            "location": c.get("location"),
            "relations": [_mappable_concept(r) for r in c.get("relations") or []] or None,
            "match_characteristic": _mappable_concept(c.get("matchCharacteristic")),
            "copies": _exact_pos(copies_val),
            "copies_range": _range_pos(copies_val),
            "copy_change": c.get("copyChange"),
        })
    return result


# pyarrow types for columns that are not plain strings.
_RANGE_TYPE = pa.struct([pa.field("min", pa.int64()), pa.field("max", pa.int64())]) if _PYARROW_AVAILABLE else None
_EXTENSION_TYPE = pa.list_(
    pa.struct([pa.field("name", pa.string()), pa.field("value", pa.string())])
) if _PYARROW_AVAILABLE else None
_IRIS_TYPE = pa.list_(pa.string()) if _PYARROW_AVAILABLE else None
_EXPRESSION_TYPE = pa.list_(pa.struct([
    pa.field("syntax", pa.string()),
    pa.field("value", pa.string()),
    pa.field("syntax_version", pa.string()),
])) if _PYARROW_AVAILABLE else None

_CODING_TYPE = pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("code", pa.string()),
    pa.field("system", pa.string()),
    pa.field("system_version", pa.string()),
    pa.field("iris", _IRIS_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
]) if _PYARROW_AVAILABLE else None

_MAPPING_TYPE = pa.list_(pa.struct([
    pa.field("coding", _CODING_TYPE),
    pa.field("relation", pa.string()),
    pa.field("extensions", _EXTENSION_TYPE),
])) if _PYARROW_AVAILABLE else None

_MAPPABLE_CONCEPT_TYPE = pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("aliases", _IRIS_TYPE),
    pa.field("primary_coding", _CODING_TYPE),
    pa.field("iris", _IRIS_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
]) if _PYARROW_AVAILABLE else None

_CONCEPT_LABEL_TYPE = pa.struct([
    pa.field("concept_type", pa.string()),
    pa.field("name", pa.string()),
    pa.field("primary_coding", _CODING_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
]) if _PYARROW_AVAILABLE else None

_CONTRIBUTION_TYPE = pa.list_(pa.struct([
    pa.field("type", pa.string()),
    pa.field("contributor", pa.string()),
    pa.field("date", pa.string()),
    pa.field("activity_type", pa.string()),
])) if _PYARROW_AVAILABLE else None

_REPORTED_IN_TYPE = pa.list_(pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("type", pa.string()),
    pa.field("document_type", pa.string()),
    pa.field("title", pa.string()),
    pa.field("doi", pa.string()),
    pa.field("pmid", pa.string()),
    pa.field("urls", pa.list_(pa.string())),
])) if _PYARROW_AVAILABLE else None

_SPECIFIED_BY_TYPE = pa.struct([
    pa.field("name", pa.string()),
    pa.field("method_type", pa.string()),
    pa.field("type", pa.string()),
    pa.field("reported_in", pa.string()),
]) if _PYARROW_AVAILABLE else None

_CONSTRAINT_TYPE = pa.list_(pa.struct([
    pa.field("type", pa.string()),
    pa.field("allele", pa.string()),
    pa.field("location", pa.string()),
    pa.field("relations", pa.list_(_MAPPABLE_CONCEPT_TYPE)),
    pa.field("match_characteristic", _MAPPABLE_CONCEPT_TYPE),
    pa.field("copies", pa.int64()),
    pa.field("copies_range", _RANGE_TYPE),
    pa.field("copy_change", pa.string()),
])) if _PYARROW_AVAILABLE else None

_COLUMN_TYPES = {
    "start":               _RANGE_TYPE and pa.int64(),
    "end":                 _RANGE_TYPE and pa.int64(),
    "start_range":         _RANGE_TYPE,
    "end_range":           _RANGE_TYPE,
    "copies":              _RANGE_TYPE and pa.int64(),
    "expressions":         _EXPRESSION_TYPE,
    "extensions":          _EXTENSION_TYPE,
    "iris":                _IRIS_TYPE,
    "aliases":             pa.list_(pa.string()) if _PYARROW_AVAILABLE else None,
    "concepts":            pa.list_(pa.string()) if _PYARROW_AVAILABLE else None,
    "primary_coding":      _CODING_TYPE,
    "mappings":            _MAPPING_TYPE,
    "classification":               _CONCEPT_LABEL_TYPE,
    "strength":                     _CONCEPT_LABEL_TYPE,
    "confidence":                   _CONCEPT_LABEL_TYPE,
    "contributions":                _CONTRIBUTION_TYPE,
    "reported_in":                  _REPORTED_IN_TYPE,
    "specified_by":                 _SPECIFIED_BY_TYPE,
    "evidence_outcome":            _CONCEPT_LABEL_TYPE,
    "strength_of_evidence_provided": _CONCEPT_LABEL_TYPE,
    "has_evidence_lines":          pa.list_(pa.string()) if _PYARROW_AVAILABLE else None,
    "has_evidence_items":          pa.list_(pa.string()) if _PYARROW_AVAILABLE else None,
    "constraints":                  _CONSTRAINT_TYPE,
    "match_characteristic":         _MAPPABLE_CONCEPT_TYPE,
    "gene_context_qualifier":       _MAPPABLE_CONCEPT_TYPE,
    "mode_of_inheritance_qualifier": _MAPPABLE_CONCEPT_TYPE,
    "penetrance_qualifier":         _MAPPABLE_CONCEPT_TYPE,
} if _PYARROW_AVAILABLE else {}


def _make_schema(col_names):
    """Build a pyarrow schema; special column names get typed, everything else is string."""
    return pa.schema([
        pa.field(c, _COLUMN_TYPES.get(c, pa.string()))
        for c in col_names
    ])


SIMPLE_SCHEMA = _make_schema(SIMPLE_COLS) if _PYARROW_AVAILABLE else None


PARQUET_SECTION_CONFIGS = {
    "sequenceReference": (
        ["id", "refget_accession", "name", "aliases",
         "molecule_type", "residue_alphabet", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("refgetAccession"),
            v.get("name"),
            v.get("aliases") or None,
            v.get("moleculeType"),
            v.get("residueAlphabet"),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "location": (
        ["id", "digest", "sequence_reference_id", "name", "aliases",
         "start", "end", "start_range", "end_range",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("digest"),
            _ref(v.get("sequenceReference"), "#/sequenceReference/"),
            v.get("name"),
            v.get("aliases") or None,
            _exact_pos(v.get("start")),
            _exact_pos(v.get("end")),
            _range_pos(v.get("start")),
            _range_pos(v.get("end")),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "allele": (
        ["id", "digest", "location_id", "name", "aliases",
         "state_type", "state_sequence",
         "state_length_min", "state_length_max",
         "expressions", "extensions", "state"],
        lambda k, v: (
            k,
            v.get("digest"),
            _ref(v.get("location"), "#/location/"),
            v.get("name"),
            v.get("aliases") or None,
            (v.get("state") or {}).get("type"),
            (v.get("state") or {}).get("sequence"),
            _state_len_min(v.get("state")),
            _state_len_max(v.get("state")),
            _exprs(v),
            _extensions(v),
            json.dumps(v.get("state")),
        ),
    ),
    "copyNumberCount": (
        ["id", "digest", "location_id", "name", "aliases",
         "copies", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("digest"),
            _ref(v.get("location"), "#/location/"),
            v.get("name"),
            v.get("aliases") or None,
            v.get("copies"),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "copyNumberChange": (
        ["id", "digest", "location_id", "name", "aliases",
         "copy_change", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("digest"),
            _ref(v.get("location"), "#/location/"),
            v.get("name"),
            v.get("aliases") or None,
            v.get("copyChange"),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "gene": (
        ["id", "name", "aliases",
         "primary_coding", "mappings", "iris", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("name"),
            v.get("aliases") or None,
            _coding(v.get("primaryCoding")),
            _mappings(v.get("mappings")),
            _iris(v),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "variation": (
        ["id", "name", "aliases", "mappings", "extensions", "constraints", "data"],
        lambda k, v: (
            k,
            v.get("name"),
            v.get("aliases") or None,
            _mappings(v.get("mappings")),
            _extensions(v),
            _constraints(v),
            json.dumps(v),
        ),
    ),
    "condition": (
        ["id", "concept_type", "name", "aliases",
         "primary_coding", "mappings", "iris", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("conceptType"),
            v.get("name"),
            v.get("aliases") or None,
            _coding(v.get("primaryCoding")),
            _mappings(v.get("mappings")),
            _iris(v),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "conditionSet": (
        ["id", "concept_set_type", "membership_operator", "concepts", "extensions", "data"],
        lambda k, v: (
            k,
            v.get("conceptSetType"),
            v.get("membershipOperator"),
            v.get("concepts") or None,
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "submitter": (
        ["id", "name", "type", "agent_type", "data"],
        lambda k, v: (
            k,
            v.get("name"),
            v.get("type", "Agent"),
            v.get("agentType", "organization"),
            json.dumps(v),
        ),
    ),
    "proposition": (
        ["id", "name", "subject_variant",
         "predicate",
         "object_condition", "object_condition_set",
         "type",
         "gene_context_qualifier",
         "mode_of_inheritance_qualifier",
         "penetrance_qualifier",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("name"),
            _ref(v.get("subjectVariant"), "#/variation/"),
            v.get("predicate"),
            _ref_if(v.get("objectCondition"), "#/condition/"),
            _ref_if(v.get("objectCondition"), "#/conditionSet/"),
            v.get("type"),
            _mappable_concept(v.get("geneContextQualifier")),
            _mappable_concept(v.get("modeOfInheritanceQualifier")),
            _mappable_concept(v.get("penetranceQualifier")),
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "scv": (
        ["id", "type", "proposition_id",
         "classification", "strength",
         "direction", "confidence", "description",
         "contributions", "reported_in", "specified_by", "has_evidence_lines",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("type"),
            _ref(v.get("proposition"), "#/proposition/"),
            _concept_label(v.get("classification")),
            _concept_label(v.get("strength")),
            v.get("direction"),
            _concept_label(v.get("confidence")),
            v.get("description"),
            _contributions(v),
            _reported_in(v),
            _specified_by(v),
            v.get("hasEvidenceLines") or None,
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "evidenceLine": (
        ["id", "type", "proposition_id",
         "direction_of_evidence_provided",
         "evidence_outcome", "strength_of_evidence_provided",
         "has_evidence_lines", "has_evidence_items",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("type"),
            _ref(v.get("proposition"), "#/proposition/"),
            v.get("directionOfEvidenceProvided"),
            _concept_label(v.get("evidenceOutcome")),
            _concept_label(v.get("strengthOfEvidenceProvided")),
            v.get("hasEvidenceLines") or None,
            v.get("hasEvidenceItems") or None,
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "vcv": (
        ["id", "type", "proposition_id",
         "classification", "strength",
         "direction", "confidence",
         "has_evidence_lines",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("type"),
            _ref(v.get("proposition"), "#/proposition/"),
            _concept_label(v.get("classification")),
            _concept_label(v.get("strength")),
            v.get("direction"),
            _concept_label(v.get("confidence")),
            v.get("hasEvidenceLines") or None,
            _extensions(v),
            json.dumps(v),
        ),
    ),
    "rcv": (
        ["id", "type", "proposition_id",
         "classification", "strength",
         "direction", "confidence",
         "has_evidence_lines",
         "extensions", "data"],
        lambda k, v: (
            k,
            v.get("type"),
            _ref(v.get("proposition"), "#/proposition/"),
            _concept_label(v.get("classification")),
            _concept_label(v.get("strength")),
            v.get("direction"),
            _concept_label(v.get("confidence")),
            v.get("hasEvidenceLines") or None,
            _extensions(v),
            json.dumps(v),
        ),
    ),
}


def open_parquet_writers(parquet_dir):
    """Open one ParquetWriter per section. Returns {section: (writer, batch, col_names, schema)}."""
    import os
    os.makedirs(parquet_dir, exist_ok=True)
    writers = {}
    for section_name, _, _, _ in SECTIONS:
        col_names = (
            PARQUET_SECTION_CONFIGS[section_name][0]
            if section_name in PARQUET_SECTION_CONFIGS
            else SIMPLE_COLS
        )
        schema = _make_schema(col_names)
        path = os.path.join(parquet_dir, f"{section_name}.parquet")
        writer = pq.ParquetWriter(path, schema, compression="zstd")
        batch = {col: [] for col in col_names}
        writers[section_name] = (writer, batch, col_names, schema)
    return writers


def _flush_parquet(writer, batch, col_names, schema):
    if batch[col_names[0]]:
        writer.write_table(pa.table(batch, schema=schema))
        for col in col_names:
            batch[col].clear()


def _add_parquet_record(writer_state, pq_id, pq_data_str, section_name, entry_count):
    """Append one record to the Parquet batch; flush every PARQUET_BATCH_SIZE records."""
    writer, batch, col_names, schema = writer_state
    if section_name in PARQUET_SECTION_CONFIGS:
        _, extractor = PARQUET_SECTION_CONFIGS[section_name]
        row = extractor(pq_id, json_loads(pq_data_str))
    else:
        row = (pq_id, pq_data_str)
    for col, val in zip(col_names, row):
        batch[col].append(val)
    if entry_count % PARQUET_BATCH_SIZE == 0:
        _flush_parquet(writer, batch, col_names, schema)


def close_parquet_writers(writers):
    """Flush remaining batches and close all writers."""
    for writer, batch, col_names, schema in writers.values():
        _flush_parquet(writer, batch, col_names, schema)
        writer.close()


# ---------------------------------------------------------------------------
# Bundle assembly
# ---------------------------------------------------------------------------

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


def assemble(source, output_path, is_gcs, parquet_dir=None):
    """
    Assemble all dictionary NDJSON sections into a single keyed JSON file.
    For GCS sources, downloads one section at a time to minimise disk usage.
    Optionally writes typed Parquet files when parquet_dir is set.
    """
    section_count = 0
    total_entries = 0
    start_time = time.time()

    parquet_writers = open_parquet_writers(parquet_dir) if parquet_dir else {}

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
                            if parquet_writers:
                                _add_parquet_record(
                                    parquet_writers[section_name],
                                    json_loads(key_json),
                                    raw_json,
                                    section_name,
                                    entry_count,
                                )
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
                            if parquet_writers:
                                _add_parquet_record(
                                    parquet_writers[section_name],
                                    json_loads(key_json),
                                    value_json,
                                    section_name,
                                    entry_count,
                                )
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
        if parquet_writers:
            close_parquet_writers(parquet_writers)

    elapsed = time.time() - start_time
    pq_msg = f", {len(parquet_writers)} Parquet files" if parquet_writers else ""
    print(
        f"\nDone: {section_count} sections, "
        f"{total_entries:,} total entries in {elapsed:.1f}s"
        f"{pq_msg}"
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
    parser.add_argument(
        "--parquet-dir",
        metavar="DIR",
        help="Write per-section typed Parquet files to DIR alongside the bundle",
    )
    args = parser.parse_args()

    if not re.match(r"^\d{4}-\d{2}-\d{2}$", args.date):
        parser.error(f"date must be YYYY-MM-DD format, got '{args.date}'")

    source = args.source
    is_gcs = source.startswith("gs://")

    if not is_gcs and not Path(source).is_dir():
        parser.error(f"{source} is not a directory or GCS path")

    if args.parquet_dir and not _PYARROW_AVAILABLE:
        parser.error("--parquet-dir requires pyarrow: pip install pyarrow")

    output_path = derive_output_path(args.date)

    print(f"Assembling GKS dictionaries from {source}")
    print(f"  Output: {output_path}")
    if args.parquet_dir:
        print(f"  Parquet: {args.parquet_dir}")
    print(f"  Using {'orjson' if 'orjson' in sys.modules else 'stdlib json (pip install orjson for 10-50x speedup)'}")

    assemble(source, output_path, is_gcs, parquet_dir=args.parquet_dir)

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
