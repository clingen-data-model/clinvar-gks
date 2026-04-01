# Pipeline Overview

The ClinVar-GKS pipeline transforms ClinVar XML release data into GA4GH GKS format through a series of BigQuery stored procedures with an external VRS Python processing step.

## Pipeline Steps

The pipeline executes in the following order. Each step is a BigQuery stored procedure unless otherwise noted.

```
┌──────────────────────────────┐
│ 1. Variation Identity        │  variation_identity_proc
│    Extract & normalize       │  → variation_identity table
│    variant data              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 2. VRS Processing            │  External: vrs-python
│    Export → VRS Python →     │  → gks_vrs table
│    Import back to BigQuery   │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 3. Cat-VRS Generation        │  gks_catvar_proc
│    Canonical alleles &       │  → gks_catvar table
│    categorical variants      │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 4. Conditions & Traits       │  gks_scv_condition_proc
│    Map traits, build         │  → condition mapping &
│    conditions & condition    │    condition set tables
│    sets                      │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 5. SCV Statements            │  gks_scv_statement_proc
│    Build SCV records,        │  → gks_scv_statement_pre table
│    propositions & statements │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 6. VCV Statements            │  gks_vcv_proc +
│    Aggregate SCVs into       │  gks_vcv_statement_proc
│    variant-level statements  │  → gks_vcv_statement_pre table
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 7. JSON Output               │  gks_json_proc
│    Convert pre-tables to     │  → gks_catvar, gks_scv_statement
│    final JSON artifacts      │    _by_ref, _inline, gks_vcv_statement
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 8. Export                    │  export-gks-files-to-gcs.sh
│     Export to GCS &          │  → public bucket
│     public bucket            │
└──────────────────────────────┘
```

## Running the Pipeline

### Step 1: Variation Identity

From the BigQuery console:

```sql
CALL `clinvar_ingest.variation_identity_proc`(CURRENT_DATE(), FALSE);
```

### Step 2: VRS Processing

Export, process externally with vrs-python, and load back. See [VRS Processing](vrs-processing.md).

### Step 3: Cat-VRS through VCV Statements

From the BigQuery console:

```sql
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_scv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_vcv_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_vcv_statement_proc`(CURRENT_DATE(), FALSE);
CALL `clinvar_ingest.gks_json_proc`(CURRENT_DATE(), 'all', FALSE);
```

### Step 4: Export

```bash
./src/scripts/export-gks-files-to-gcs.sh
```

See [Export](export.md) for configuration and naming details.

## Documentation Tracks

The pipeline documentation serves two audiences:

- **Pipeline** (this section) — documents how data flows through BigQuery stored procedures, including internal table schemas, transformation logic, and step-by-step workflows. Each step is tagged as <span class="role-badge badge-pipeline">Pipeline table</span>, <span class="role-badge badge-artifact">JSON artifact</span>, or <span class="role-badge badge-internal">Internal</span> to indicate its role
- **[Output Reference](../output-reference/index.md)** — documents the JSON output files from a consumer perspective, covering record structure, field meanings, and usage guidance

---

## Detailed Documentation

Each pipeline step has its own documentation page:

- [Variation Identity](variation-identity/index.md) — variant extraction, normalization, VRS class assignment
- [VRS Processing](vrs-processing.md) — external VRS Python step
- [Cat-VRS](cat-vrs/index.md) — categorical variant generation
- [Conditions & Traits](conditions-and-traits/index.md) — condition mapping, traits, condition sets
- [SCV Statements](scv-statements/index.md) — SCV records, propositions, final statements
- [VCV Statements](vcv-statements/index.md) — aggregate VCV/RCV statements (in progress)
- [Export](export.md) — export to Google Cloud Storage
