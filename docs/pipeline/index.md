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
│ 4. Condition Mapping         │  gks_scv_condition_mapping_proc
│    Map traits & conditions   │  → condition mapping tables
│    between SCVs and RCVs     │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 5. Traits                    │  gks_trait_proc
│    Generate normalized       │  → gks_trait table
│    trait records              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 6. Condition Sets            │  gks_scv_condition_sets_proc
│    Build submitted           │  → condition set tables
│    condition sets            │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 7. SCV Records               │  gks_scv_proc
│    Build SCV records with    │  → gks_scv table
│    propositions              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 8. SCV Propositions          │  gks_scv_proposition_proc
│    Generate variant          │  → gks_scv_proposition table
│    propositions              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 9. SCV Statements            │  gks_statement_scv_proc
│    Assemble final GKS SCV    │  → gks_statement_scv tables
│    statements                │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 10. Export                   │  export-gks-files-to-gcs.sh
│     Export to GCS &          │  → public bucket
│     public bucket            │
└──────────────────────────────┘
```

## Running the Pipeline

### Step 1: Variation Identity

From the BigQuery console:

```sql
CALL `clinvar_ingest.variation_identity_proc`(CURRENT_DATE());
```

### Step 2: VRS Processing

Export, process externally with vrs-python, and load back. See [VRS Processing](vrs-processing.md).

### Step 3: Cat-VRS through SCV Statements

From the BigQuery console:

```sql
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_scv_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_scv_proposition_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_statement_scv_proc`(CURRENT_DATE());
```

### Step 4: Export

```bash
./src/scripts/export-gks-files-to-gcs.sh
```

See [Export](export.md) for configuration and naming details.

## Detailed Documentation

Each pipeline step has its own documentation page:

- [Variation Identity](variation-identity/index.md) — variant extraction, normalization, VRS class assignment
- [VRS Processing](vrs-processing.md) — external VRS Python step
- [Cat-VRS](cat-vrs/index.md) — categorical variant generation
- [Conditions & Traits](conditions-and-traits/index.md) — condition mapping, traits, condition sets
- [SCV Statements](scv-statements/index.md) — SCV records, propositions, final statements
- [VCV Statements](vcv-statements/index.md) — aggregate VCV/RCV statements (in progress)
- [Export](export.md) — export to Google Cloud Storage
