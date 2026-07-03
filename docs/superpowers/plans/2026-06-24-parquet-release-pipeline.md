# Parquet Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate 16 per-section typed Parquet files from each ClinVar-GKS bundle release and upload them alongside the JSON bundle to Cloudflare R2 at `datasets/parquet/`.

**Architecture:** Add `--parquet-dir=DIR` to `assemble-gks-dicts.py`. During assembly it already streams every record once — it now also opens a `ParquetWriter` per section and writes typed rows alongside the bundle in the same pass. No new script; no second read of the bundle. `release-gks.sh` passes `--parquet-dir` to both the assembler and the uploader. `upload-gks-to-r2.sh` gains a `--parquet-dir` argument and uploads the 16 files to `datasets/parquet/`.

**Tech Stack:** Python 3.12, pyarrow, bash, awscli (R2 via S3 API)

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Modify | `src/procedures/gks-catvar-proc.sql` | Split allele dict by VRS type; add copyNumberCount/copyNumberChange tables; rename to `gks_dict_*`; restructure gene and variation dicts |
| Modify | `src/procedures/gks-scv-condition-proc.sql` | Rename `gks_traits` → `gks_dict_condition`, `gks_trait_sets` → `gks_dict_condition_set` |
| Modify | `src/procedures/gks-scv-statement-proc.sql` | Rename `gks_scv_statement_pre` → `gks_dict_scv` |
| Modify | `src/procedures/gks-vcv-statement-proc.sql` | Rename `gks_vcv_statement_pre` → `gks_dict_vcv` |
| Modify | `src/procedures/gks-rcv-statement-proc.sql` | Rename `gks_rcv_statement_pre` → `gks_dict_rcv` |
| Modify | `src/procedures/gks-json-proc.sql` | Update any references to renamed tables |
| Modify | `src/scripts/export-gks-dicts.sh` | Update all `extract` calls to new table names |
| Modify | `src/scripts/assemble-gks-dicts.py` | Add `copyNumberCount`, `copyNumberChange`, `evidenceLine`, and `aggregationEvidenceLine` to SECTIONS; add `--parquet-dir`: write 16 typed Parquet files during assembly |
| Modify | `src/scripts/release-gks.sh` | Add `PARQUET_DIR`, pass to assembler and uploader, cleanup |
| Modify | `src/scripts/upload-gks-to-r2.sh` | Accept `--parquet-dir`, upload Parquet files to `datasets/parquet/` |
| Modify | `docs/pipeline/export.md` | Update table names |
| Modify | `docs/pipeline/index.md` | Update table names |
| Modify | `docs/pipeline/scv-statements/index.md` | Update table names |
| Modify | `docs/pipeline/scv-statements/final-statements.md` | Update table names |
| Modify | `docs/pipeline/vcv-statements/index.md` | Update table names |
| Modify | `docs/pipeline/vcv-statements/vcv-proc.md` | Update table names |
| Modify | `docs/pipeline/rcv-statements/index.md` | Update table names |
| Modify | `docs/pipeline/rcv-statements/rcv-proc.md` | Update table names |

---

## Prerequisites: SQL table renames and restructuring

All SQL and export changes must land before the assembler can be tested end-to-end.

### Task 0a: Standardise table names to `gks_dict_*`

The following renames bring every output table into consistent `gks_dict_<section>` nomenclature.

**Full rename mapping:**

| Old name | New name | Proc |
|---|---|---|
| `gks_traits` | `gks_dict_condition` | `gks-scv-condition-proc.sql` |
| `gks_trait_sets` | `gks_dict_condition_set` | `gks-scv-condition-proc.sql` |
| `gks_scv_statement_pre` | `gks_dict_scv` | `gks-scv-statement-proc.sql` |
| `gks_vcv_statement_pre` | `gks_dict_vcv` | `gks-vcv-statement-proc.sql` |
| `gks_rcv_statement_pre` | `gks_dict_rcv` | `gks-rcv-statement-proc.sql` |

**Files to update:**

- `src/procedures/gks-scv-condition-proc.sql` — rename `gks_traits` and `gks_trait_sets` everywhere they appear
- `src/procedures/gks-scv-statement-proc.sql` — rename `gks_scv_statement_pre`
- `src/procedures/gks-vcv-statement-proc.sql` — rename `gks_vcv_statement_pre`
- `src/procedures/gks-rcv-statement-proc.sql` — rename `gks_rcv_statement_pre`
- `src/procedures/gks-json-proc.sql` — update any cross-proc references
- `src/scripts/export-gks-dicts.sh` — update all five `extract` calls

**Docs to update** (replace old names throughout):

- `docs/pipeline/export.md`
- `docs/pipeline/index.md`
- `docs/pipeline/scv-statements/index.md`
- `docs/pipeline/scv-statements/final-statements.md`
- `docs/pipeline/vcv-statements/index.md`
- `docs/pipeline/vcv-statements/vcv-proc.md`
- `docs/pipeline/rcv-statements/index.md`
- `docs/pipeline/rcv-statements/rcv-proc.md`

### Task 0b: SQL structural changes

- [ ] **`gks-catvar-proc.sql`** — Split `gks_dict_allele` by VRS type:
  1. `gks_dict_allele` — add `WHERE vrs.type = 'Allele'`; remove `vrs.copies` and `vrs.copyChange`
  2. `gks_dict_copy_number_count` — `WHERE vrs.type = 'CopyNumberCount'`; project `id, type, digest, name, copies, location`; no `state`, no `expressions`
  3. `gks_dict_copy_number_change` — `WHERE vrs.type = 'CopyNumberChange'`; project `id, type, digest, name, copyChange, location`; no `state`, no `expressions`

- [ ] **`gks-catvar-proc.sql`** — Restructure `gks_dict_gene` as `MappableConcept`: `symbol` → `name`; `entrez_gene_id`/`hgnc_id` into `primaryCoding`/`mappings`; add `aliases`

- [ ] **`gks-catvar-proc.sql`** — Restructure `gks_dict_variation` as `MappableConcept + constraints`:
  - Top-level: `id, name, aliases, mappings, extensions, constraints`
  - Fix `members` FK: `CanonicalAllele` → `#/allele/`, `CategoricalCnvCount` → `#/copyNumberCount/`, `CategoricalCnvChange` → `#/copyNumberChange/`
  - `constraints` array: each item is `{type, allele, location, relations, matchCharacteristic, copies, copyChange}`

- [ ] **`gks-scv-condition-proc.sql`** — Restructure `gks_dict_condition` as `MappableConcept`: promote `t.synonyms` from the `aliases` extension entry to a top-level `aliases` field; output `id, conceptType, name, aliases, primaryCoding, mappings, iris, extensions`

- [ ] **`gks-scv-condition-proc.sql`** — Restructure `gks_dict_condition_set`: rename `condition_refs` → `concepts`; surface `rcv_trait_set_type` as `conceptSetType` and `membershipOperator` as top-level fields; output `id, conceptSetType, membershipOperator, concepts, extensions`

- [ ] **`gks-catvar-proc.sql`** — Change `catvar_type` ELSE value from `'Non-Constrained'` to `'Undefined'` (line 334); update `categoricalVariationType` extension value accordingly. Also update `schema/clinvar-gks/clinvar-variant-source.yaml` enum and docs referencing `Non-Constrained`.

- [ ] **Multiple procs** — Fix `coding.system` values to use URLs instead of plain strings: `ga4gh-gks-term:allele-relation`, `ga4gh-gks-term:location-match`, `ClinVar`, `omim`, `omim.ps`, `HP`, `mondo`, `medgen`, `orpha`, `mesh`, `ncbibook`. Also fix inconsistent trailing slashes on `sequenceontology.org`.

- [ ] **`gks-scv-statement-proc.sql`** — Extract `specifiedBy.methodType` and `specifiedBy.name` as top-level `methodType` and `methodName` fields on `gks_dict_scv` for Parquet extraction

- [ ] **`gks-scv-statement-proc.sql`, `gks-vcv-statement-proc.sql`, `gks-rcv-statement-proc.sql`** — Change `confidence` from a plain STRING to a concept struct `STRUCT('Confidence' AS conceptType, <label> AS name)` so it matches `_CONCEPT_LABEL_TYPE`. In SCV: wrap `scv.submission_level_label`. In VCV/RCV: wrap `sl.label` (classification/priority layers) and `agg.contributing_submission_level_label` (aggregate layer). All downstream references that carry `confidence` through layer structs must propagate the struct instead of a string.

- [ ] **`gks-scv-statement-proc.sql`** — Create `gks_dict_evidence_line` table from the `hasEvidenceLines` data currently inlined in Step 8. Each evidence line record has: `id, type, proposition` (FK to target proposition `#/proposition/{stp.id}`), `directionOfEvidenceProvided`, `evidenceOutcome` (`{conceptType: 'Outcome', name: '...'}`) , `extensions`. Modify `gks_scv_statement_pre` to output `hasEvidenceLines` as FK strings (`["#/evidenceLine/{id}"]`) instead of inlined objects.

- [ ] **`gks-vcv-statement-proc.sql`, `gks-rcv-statement-proc.sql`** — Create `gks_dict_aggregation_evidence_line` table from the classification and priority layer statements currently inlined as `evidenceItems`. Each record has: `id, type, direction, strength, confidence, classification, proposition` (FK), `extensions`, `hasEvidenceLines` (FK array to `#/evidenceLine/{id}`). Modify the aggregate layer to reference these via FKs instead of inlining. Also extract the `evidenceLines` on each layer into `gks_dict_evidence_line` records with `strengthOfEvidenceProvided`, `hasEvidenceItems` (FK array to `#/scv/{id}` or `#/aggregationEvidenceLine/{id}`), and `directionOfEvidenceProvided`.

- [ ] **`src/scripts/export-gks-dicts.sh`** — Add export lines for `gks_dict_copy_number_count`, `gks_dict_copy_number_change`, `gks_dict_evidence_line`, and `gks_dict_aggregation_evidence_line`

---

## Chunk 1: assemble-gks-dicts.py — dual output

### Task 1: Add `--parquet-dir` to `assemble-gks-dicts.py`

**Files:**
- Modify: `src/scripts/assemble-gks-dicts.py`

The assembler already streams every record once to build the bundle. With `--parquet-dir` set it will simultaneously write one Parquet file per section (ZSTD compression, typed schemas per `PARQUET_SECTION_CONFIGS`).

**How it works:**
- `open_parquet_writers(parquet_dir)` opens one `pq.ParquetWriter` per section into a dict `{section_name: (writer, batch, col_names, schema)}`.
- Inside each section's inner loop, after writing the record to the bundle buffer, call `_add_parquet_record(writers[section_name], pq_id, pq_value)`.
- Every section has a typed config in `PARQUET_SECTION_CONFIGS`; each record is JSON-parsed and run through the section's extractor to produce typed columns.
- Flush each section's writer after all its files are processed; close all writers at the end of `assemble()`.

**Key detail — what `pq_data_str` is in each branch:**
- `value_field is None` (stream_passthrough): `raw_json` is the full record line → `pq_data_str = raw_json`
- `value_field = "value"` (stream_kv): `value_json` is the serialized value field → `pq_data_str = value_json`

`pq_id = json_loads(key_json)` in both cases (strips outer quotes).

- [ ] **Step 1.1: Verify pyarrow is available in the project venv**

```bash
${PROJECT_ROOT}/venv/3.12/bin/python3 -c "import pyarrow; print(pyarrow.__version__)"
```

Where `PROJECT_ROOT=/Users/lbabb/Development/gks/clinvar-gks`. If it fails:

```bash
${PROJECT_ROOT}/venv/3.12/bin/pip install pyarrow
```

- [ ] **Step 1.2: Add pyarrow import block** (after the `orjson` try/except block, around line 55)

```python
# pyarrow is optional — only needed when --parquet-dir is used
try:
    import pyarrow as pa
    import pyarrow.parquet as pq
    _PYARROW_AVAILABLE = True
except ImportError:
    _PYARROW_AVAILABLE = False
```

- [ ] **Step 1.3: Add Parquet helpers** (after the `WRITE_BUFFER_SIZE` / `GZIP_COMPRESS_LEVEL` constants)

```python
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
# Any col_name not listed here defaults to pa.string().
_RANGE_TYPE = pa.struct([pa.field("min", pa.int64()), pa.field("max", pa.int64())])
_EXTENSION_TYPE = pa.list_(
    pa.struct([pa.field("name", pa.string()), pa.field("value", pa.string())])
)
_IRIS_TYPE = pa.list_(pa.string())
_EXPRESSION_TYPE = pa.list_(pa.struct([
    pa.field("syntax", pa.string()),
    pa.field("value", pa.string()),
    pa.field("syntax_version", pa.string()),
]))

_CODING_TYPE = pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("code", pa.string()),
    pa.field("system", pa.string()),
    pa.field("system_version", pa.string()),
    pa.field("iris", _IRIS_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
])

_MAPPING_TYPE = pa.list_(pa.struct([
    pa.field("coding", _CODING_TYPE),
    pa.field("relation", pa.string()),
    pa.field("extensions", _EXTENSION_TYPE),
]))

# MappableConcept as a struct (no nested mappings to avoid infinite recursion)
_MAPPABLE_CONCEPT_TYPE = pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("aliases", _IRIS_TYPE),
    pa.field("primary_coding", _CODING_TYPE),
    pa.field("iris", _IRIS_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
])

# Classification/strength/evidenceOutcome: concept with queryable primaryCoding
_CONCEPT_LABEL_TYPE = pa.struct([
    pa.field("concept_type", pa.string()),
    pa.field("name", pa.string()),
    pa.field("primary_coding", _CODING_TYPE),
    pa.field("extensions", _EXTENSION_TYPE),
])

# Contribution: who did what and when
_CONTRIBUTION_TYPE = pa.list_(pa.struct([
    pa.field("type", pa.string()),
    pa.field("contributor", pa.string()),      # FK → submitter
    pa.field("date", pa.string()),             # YYYY-MM-DD
    pa.field("activity_type", pa.string()),
]))

# ReportedIn: array of Document references
_REPORTED_IN_TYPE = pa.list_(pa.struct([
    pa.field("id", pa.string()),
    pa.field("name", pa.string()),
    pa.field("type", pa.string()),
    pa.field("document_type", pa.string()),
    pa.field("title", pa.string()),
    pa.field("doi", pa.string()),
    pa.field("pmid", pa.string()),
    pa.field("urls", pa.list_(pa.string())),
]))

# SpecifiedBy: method used to produce the statement
_SPECIFIED_BY_TYPE = pa.struct([
    pa.field("name", pa.string()),
    pa.field("method_type", pa.string()),
    pa.field("type", pa.string()),
    pa.field("reported_in", pa.string()),      # Document JSON
])

# Constraint struct embedded in variation.constraints
_CONSTRAINT_TYPE = pa.list_(pa.struct([
    pa.field("type", pa.string()),
    pa.field("allele", pa.string()),            # FK → allele / copyNumberCount / copyNumberChange
    pa.field("location", pa.string()),          # FK → location
    pa.field("relations", pa.list_(_MAPPABLE_CONCEPT_TYPE)),
    pa.field("match_characteristic", _MAPPABLE_CONCEPT_TYPE),
    pa.field("copies", pa.int64()),             # exact copy count (null if range or absent)
    pa.field("copies_range", _RANGE_TYPE),      # [min, max] copy range (null if exact or absent)
    pa.field("copy_change", pa.string()),       # EFO code e.g. efo:0030069
]))

_COLUMN_TYPES = {
    "start":               pa.int64(),
    "end":                 pa.int64(),
    "start_range":         _RANGE_TYPE,
    "end_range":           _RANGE_TYPE,
    "copies":              pa.int64(),
    "expressions":         _EXPRESSION_TYPE,
    "extensions":          _EXTENSION_TYPE,
    "iris":                _IRIS_TYPE,
    "aliases":             pa.list_(pa.string()),
    "concepts":            pa.list_(pa.string()),
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
    "has_evidence_lines":          pa.list_(pa.string()),
    "has_evidence_items":          pa.list_(pa.string()),
    "constraints":                  _CONSTRAINT_TYPE,
    "match_characteristic":         _MAPPABLE_CONCEPT_TYPE,
    "gene_context_qualifier":       _MAPPABLE_CONCEPT_TYPE,
    "mode_of_inheritance_qualifier": _MAPPABLE_CONCEPT_TYPE,
    "penetrance_qualifier":         _MAPPABLE_CONCEPT_TYPE,
}


def _make_schema(col_names):
    """Build a pyarrow schema; special column names get typed, everything else is string."""
    return pa.schema([
        pa.field(c, _COLUMN_TYPES.get(c, pa.string()))
        for c in col_names
    ])


SIMPLE_SCHEMA = _make_schema(SIMPLE_COLS)


# Typed column definitions for every section.
# Each entry: (col_names, extractor_fn)
# col_names: ordered list; last column is the raw JSON payload
# extractor: fn(id_str, value_dict) -> tuple matching col_names
# Schema is derived automatically via _make_schema(col_names).
#
# Every section has a typed config below.
PARQUET_SECTION_CONFIGS = {
    # --- VRS lookup sections ---
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
    # allele: type='Allele' only; raw column is "state" (the state sub-object)
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
    # copyNumberCount: type='CopyNumberCount' only; copies is a top-level INTEGER
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
    # copyNumberChange: type='CopyNumberChange' only; copyChange is a top-level STRING (EFO code)
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
        # MappableConcept: symbol → name; entrez/hgnc encoded in primaryCoding/mappings
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
    # --- Cat-VRS / condition sections ---
    # variation: MappableConcept + constraints array; allele FK uses correct section per vrs type
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
    # condition: MappableConcept; synonyms promoted from extensions to top-level aliases
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
    # submitter: VA-Spec Agent schema; type and agentType are always constant
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
    # --- Statement sections ---
    # proposition: object split into two nullable FK columns by prefix;
    # qualifier columns only populated on SCV propositions
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
            _ref(v.get("subject"), "#/variation/"),
            v.get("predicate"),
            _ref_if(v.get("object"), "#/condition/"),
            _ref_if(v.get("object"), "#/conditionSet/"),
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
    # evidenceLine: used by SCV (target propositions), VCV, and RCV
    # SCV: evidence_outcome populated, proposition_id populated
    # VCV/RCV: strength_of_evidence_provided populated, has_evidence_items populated
    # has_evidence_lines: FK array to nested evidenceLine records
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
    # aggregationEvidenceLine: VCV/RCV classification and priority layer statements
    # These are the intermediate aggregation statements that sit between the top-level
    # VCV/RCV aggregate statement and the bottom-layer SCVs. Built on the fly in the
    # vcv/rcv procs as evidenceItems at each grouping layer.
    # Classification layer: evidenceItems → SCVs (via evidenceLine FKs)
    # Priority layer: evidenceItems → classification-layer statements (via evidenceLine FKs)
    "aggregationEvidenceLine": (
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
```

- [ ] **Step 1.4: Add `parquet_dir` parameter to `assemble()`**

Change the function signature from:
```python
def assemble(source, output_path, is_gcs):
```
to:
```python
def assemble(source, output_path, is_gcs, parquet_dir=None):
```

- [ ] **Step 1.5: Open/close writers inside `assemble()`**

At the top of `assemble()`, after the `section_count = 0` / `total_entries = 0` lines, add:

```python
parquet_writers = open_parquet_writers(parquet_dir) if parquet_dir else {}
```

At the end of `assemble()`, after `out.close()` in the `finally` block, add:

```python
if parquet_writers:
    close_parquet_writers(parquet_writers)
```

- [ ] **Step 1.6: Write to Parquet batches inside the assembly loop**

In the `value_field is None` branch (around line 213), after the existing bundle-write lines and before `entry_count += 1`:

```python
                        if parquet_writers:
                            _add_parquet_record(
                                parquet_writers[section_name],
                                json_loads(key_json),
                                raw_json,
                                section_name,
                                entry_count,
                            )
```

In the `else` branch (stream_kv, around line 224), same position:

```python
                        if parquet_writers:
                            _add_parquet_record(
                                parquet_writers[section_name],
                                json_loads(key_json),
                                value_json,
                                section_name,
                                entry_count,
                            )
```

- [ ] **Step 1.7: Add `--parquet-dir` argument to argparse**

After the `--copy-to-gcs` argument (around line 290):

```python
    parser.add_argument(
        "--parquet-dir",
        metavar="DIR",
        help="Write 15 per-section typed Parquet files to DIR alongside the bundle",
    )
```

- [ ] **Step 1.8: Pass `parquet_dir` through `main()`**

Change the `assemble(...)` call in `main()` from:
```python
    assemble(source, output_path, is_gcs)
```
to:
```python
    assemble(source, output_path, is_gcs, parquet_dir=args.parquet_dir)
```

- [ ] **Step 1.9: Verify syntax**

```bash
python3 -m py_compile src/scripts/assemble-gks-dicts.py && echo "OK"
```

- [ ] **Step 1.10: Smoke test against the local bundle shards**

The assembled bundle is at `~/Downloads/clinvar-gks_00-latest_weekly.json.gz`. We need local NDJSON shards to feed the assembler. The quickest way: split the bundle back to NDJSON using `load_bundle_to_duckdb.py`'s split logic, then point the assembler at them.

Instead, use the assembler directly if local `./gks-dicts/` data is available. Check:

```bash
ls /Users/lbabb/Development/gks/clinvar-gks/gks-dicts/ 2>/dev/null | head -5
```

If shards are present:
```bash
cd /Users/lbabb/Development/gks/clinvar-gks
~/clinvar_venv/bin/python3 src/scripts/assemble-gks-dicts.py \
  ./gks-dicts/ 2026-05-10 \
  --keep-source \
  --parquet-dir=/tmp/clinvar-gks-parquet-test/
```

Expected: assembly completes, 16 `.parquet` files appear in `/tmp/clinvar-gks-parquet-test/`.

If no local shards, skip to verification with the existing bundle (see Task 4).

- [ ] **Step 1.11: Verify Parquet output with DuckDB**

```bash
~/clinvar_venv/bin/python3 - <<'EOF'
import duckdb, os
d = "/tmp/clinvar-gks-parquet-test"
for f in sorted(os.listdir(d)):
    if f.endswith(".parquet"):
        s = f[:-8]
        n = duckdb.sql(f"SELECT count(*) FROM read_parquet('{d}/{f}')").fetchone()[0]
        print(f"  {s:<20} {n:>10,}")
EOF
```

- [ ] **Step 1.12: Verify typed columns in scv**

```bash
~/clinvar_venv/bin/python3 - <<'EOF'
import duckdb
d = "/tmp/clinvar-gks-parquet-test"
print(duckdb.sql(f"""
  SELECT id, proposition_id, submitter_id,
         classification.name AS classif_name,
         strength.name AS strength_name,
         direction
  FROM read_parquet('{d}/scv.parquet')
  WHERE classification.name = 'Pathogenic'
  LIMIT 5
""").fetchdf())
EOF
```

Expected: 5 rows with non-null `proposition_id`, `submitter_id`, `classif_name = 'Pathogenic'`.

- [ ] **Step 1.13: Commit**

```bash
git add src/scripts/assemble-gks-dicts.py
git commit -m "Add --parquet-dir to assembler: emit 15 typed Parquet files during assembly"
```

---

## Chunk 2: release-gks.sh — wire up PARQUET_DIR

### Task 2: Pass PARQUET_DIR through release-gks.sh

**Files:**
- Modify: `src/scripts/release-gks.sh`

The pipeline stays at 3 steps. Changes:
1. Add `PARQUET_DIR` variable after `BUNDLE_FILE`
2. Add `Parquet dir:` to the header echo block
3. Pass `--parquet-dir="${PARQUET_DIR}"` to the assembler args in step 2
4. Pass `--parquet-dir="${PARQUET_DIR}"` to the upload args in step 3
5. Add `rm -rf "${PARQUET_DIR}"` to the cleanup block

When `--start-step=3` (upload only), the Parquet dir won't exist. `upload-gks-to-r2.sh` silently skips Parquet upload if the dir is absent.

- [ ] **Step 2.1: Add PARQUET_DIR variable** (after line 77 `BUNDLE_FILE=...`):

```bash
PARQUET_DIR="/tmp/clinvar-gks-${EXPORT_DATE}-parquet"
```

- [ ] **Step 2.2: Add Parquet dir to header echo block** (after `echo "  Bundle:        ${BUNDLE_FILE}"`):

```bash
echo "  Parquet dir:   ${PARQUET_DIR}"
```

- [ ] **Step 2.3: Pass `--parquet-dir` to assembler** (around line 116, add to `ASSEMBLE_ARGS`):

Change:
```bash
  ASSEMBLE_ARGS=("${GCS_DICTS_PATH}/" "${EXPORT_DATE}")
```
to:
```bash
  ASSEMBLE_ARGS=("${GCS_DICTS_PATH}/" "${EXPORT_DATE}" "--parquet-dir=${PARQUET_DIR}")
```

- [ ] **Step 2.4: Pass `--parquet-dir` to uploader** (around line 137, update `UPLOAD_ARGS`):

Change:
```bash
UPLOAD_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}" "${BUNDLE_FILE}")
```
to:
```bash
UPLOAD_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}" "${BUNDLE_FILE}" "--parquet-dir=${PARQUET_DIR}")
```

- [ ] **Step 2.5: Add PARQUET_DIR to cleanup** (around line 145):

Change:
```bash
if ! $DRY_RUN; then
  rm -f "${BUNDLE_FILE}"
fi
```
to:
```bash
if ! $DRY_RUN; then
  rm -f "${BUNDLE_FILE}"
  rm -rf "${PARQUET_DIR}"
fi
```

- [ ] **Step 2.6: Verify the script is valid bash**

```bash
bash -n src/scripts/release-gks.sh && echo "OK"
```

- [ ] **Step 2.7: Dry-run smoke test**

```bash
cd /Users/lbabb/Development/gks/clinvar-gks
src/scripts/release-gks.sh 2026-06-14 v2_5_0 --dry-run 2>&1
```

Expected: Step 2 dry-run line shows `--parquet-dir=/tmp/clinvar-gks-2026-06-14-parquet` in the assembler args; Step 3 shows `--parquet-dir=` in the upload args.

- [ ] **Step 2.8: Commit**

```bash
git add src/scripts/release-gks.sh
git commit -m "Wire PARQUET_DIR through release pipeline"
```

---

## Chunk 3: upload-gks-to-r2.sh — Parquet upload

### Task 3: Add Parquet upload to upload-gks-to-r2.sh

**Files:**
- Modify: `src/scripts/upload-gks-to-r2.sh`

The R2 path `datasets/parquet/` always holds the latest Parquet files (no versioning). Content-type: `application/vnd.apache.parquet`.

- [ ] **Step 3.1: Add PARQUET_DIR variable** (after the `DRY_RUN=false` line, around line 49):

```bash
PARQUET_DIR=""
```

- [ ] **Step 3.2: Add `--parquet-dir` to the arg parser** (inside the `for arg in "$@"` loop):

```bash
    --parquet-dir=*) PARQUET_DIR="${arg#--parquet-dir=}" ;;
```

Also update the unknown-arg error message usage line:
```bash
      echo "Usage: $0 <export_date> <dataset_version> <bundle_file> [--dry-run] [--parquet-dir=DIR]"
```

- [ ] **Step 3.3: Add `upload_parquet()` function** (before the `# =====================================================================` Main section):

```bash
upload_parquet() {
  local parquet_dir="$1"
  if [[ -z "$parquet_dir" || ! -d "$parquet_dir" ]]; then
    echo "  (no Parquet dir found, skipping)"
    return
  fi

  echo "--- Uploading Parquet section files ---"
  local uploaded=0
  for parquet_file in "${parquet_dir}"/*.parquet; do
    [[ -f "$parquet_file" ]] || continue
    local section
    section="$(basename "${parquet_file}" .parquet)"
    echo "  datasets/parquet/${section}.parquet"
    r2_upload \
      "${parquet_file}" \
      "datasets/parquet/${section}.parquet" \
      "application/vnd.apache.parquet"
    (( uploaded++ )) || true
  done
  echo "  ${uploaded} Parquet files uploaded."
}
```

- [ ] **Step 3.4: Call `upload_parquet` after the weekly upload block**

After the `r2_upload "${LOCAL_TMP}" "datasets/weekly/${LATEST_WEEKLY}"` line, add:

```bash
# --- Upload Parquet files (if generated) ---
if [[ -n "${PARQUET_DIR}" ]]; then
  echo ""
  upload_parquet "${PARQUET_DIR}"
fi
```

- [ ] **Step 3.5: Add Parquet URL to summary block**

After the existing summary `echo` lines:

```bash
if [[ -n "${PARQUET_DIR}" && -d "${PARQUET_DIR}" ]]; then
  echo "  Parquet: ${R2_PUBLIC_URL}/datasets/parquet/"
fi
```

- [ ] **Step 3.6: Verify the script is valid bash**

```bash
bash -n src/scripts/upload-gks-to-r2.sh && echo "OK"
```

- [ ] **Step 3.7: Dry-run with the test Parquet dir**

```bash
src/scripts/upload-gks-to-r2.sh \
  2026-06-14 v2_5_0 \
  /tmp/clinvar-gks-2026-06-14.json.gz \
  --parquet-dir=/tmp/clinvar-gks-parquet-test \
  --dry-run 2>&1 | grep -E "Parquet|parquet|dry-run"
```

Expected: lines showing `[dry-run] upload: datasets/parquet/scv.parquet` etc. for each `.parquet` file present.

- [ ] **Step 3.8: Commit**

```bash
git add src/scripts/upload-gks-to-r2.sh
git commit -m "Upload per-section Parquet files to datasets/parquet/ on each release"
```

---

## Chunk 4: End-to-end validation

### Task 4: Validate the full pipeline in dry-run mode

- [ ] **Step 4.1: Full pipeline dry run**

```bash
src/scripts/release-gks.sh 2026-06-14 v2_5_0 --dry-run 2>&1
```

Expected:
- `=== Step 1/3:` through `=== Step 3/3:`
- Step 2 dry-run line includes `--parquet-dir=/tmp/clinvar-gks-2026-06-14-parquet`
- Step 3 dry-run lines include `[dry-run] upload: datasets/parquet/scv.parquet` etc.

- [ ] **Step 4.2: Verify start-step=3 gracefully skips Parquet**

```bash
src/scripts/release-gks.sh 2026-06-14 v2_5_0 --start-step=3 --dry-run 2>&1
```

Expected: Steps 1 and 2 show `Skipped`; Step 3 upload shows `(no Parquet dir found, skipping)` for the Parquet section.

- [ ] **Step 4.3: Confirm Parquet files are DuckDB-queryable** (requires a real assembly run from Task 1 test data)

```bash
~/clinvar_venv/bin/python3 - <<'EOF'
import duckdb, os
d = "/tmp/clinvar-gks-parquet-test"
for f in sorted(os.listdir(d)):
    if f.endswith(".parquet"):
        s = f[:-8]
        r = duckdb.sql(
            f"SELECT count(*) FROM read_parquet('{d}/{f}')"
        ).fetchone()[0]
        print(f"  {s:<20} {r:>10,}")
EOF
```

Expected: All 16 sections with non-zero counts.
