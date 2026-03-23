# VRS Processing

## Overview

VRS processing is the manual step between [Variation Identity](variation-identity/index.md) extraction and [Cat-VRS](cat-vrs/index.md) generation. It translates the selected SPDI or HGVS expression for each variation's defining allele into a GA4GH VRS (Variation Representation Specification) object — producing a computable, digest-identified representation of the variant.

Unlike the automated BigQuery procedures that handle the rest of the pipeline, this step is currently a manual process requiring several sequential operations: exporting the `variation_identity` table to GCS, running an external Python tool to generate VRS representations, transforming the output for BigQuery compatibility, and loading the results back into BigQuery. Once this step is complete, the remaining pipeline — from Cat-VRS generation through final JSON export — runs as a sequence of automated stored procedures.

VRS resolution is performed by the [clinvar-gk-python](https://github.com/clingen-data-model/clinvar-gk-python) project, which wraps [vrs-python](https://github.com/ga4gh/vrs-python) and the [variation-normalizer](https://github.com/GenomicMedLab/variation-normalizer) to resolve expressions against a local SeqRepo sequence repository. The location transformation step uses a lightweight Cloud Run job defined in this project under `src/vrs-location-transformer/`.

---

## Workflow

### Step 1: Export `variation_identity` from BigQuery

The `variation_identity` table is exported from BigQuery to Google Cloud Storage as gzipped NDJSON.

```bash
bq extract --destination_format NEWLINE_DELIMITED_JSON --compression GZIP \
  'clinvar_YYYY_MM_DD_v2_4_3.variation_identity' \
  gs://clinvar-gks/YYYY-MM-DD/dev/vi.jsonl.gz
```

Each record contains the single best expression source for a ClinVar variation — including the `source` expression string, `fmt` (spdi, hgvs, or gnomad), `vrs_class`, and copy number fields when applicable.

### Step 2: Run clinvar-gk-python

The `misc/clinvar-vrsification` script in the clinvar-gk-python repository orchestrates VRS resolution. It accepts a release date and invokes the Python entry point with parallelism:

```bash
misc/clinvar-vrsification YYYY-MM-DD
```

For each input record, the tool attempts to resolve the `source` expression into a VRS object according to its `vrs_class`. Not every variation can be resolved — vrs-python handles a subset of expression types, and records that fail resolution carry an `errors` field in the output. The supported VRS classes are:

- **Allele** — translates SPDI or HGVS into a VRS `Allele` with a `SequenceLocation` and `state`
- **CopyNumberChange** — resolves the location and applies the `copyChange` designation (gain/loss)
- **CopyNumberCount** — resolves the location and attaches the `copies` value

Each output record pairs the original `variation_identity` input (`in`) with the VRS resolution result (`out`).

**Output:** `vi-normalized-no-liftover.jsonl.gz` on GCS.

### Step 3: Transform VRS locations

VRS `SequenceLocation` objects use array-valued `start` and `end` fields to represent imprecise ranges (inner/outer bounds). BigQuery does not natively support loading these mixed scalar/array values, so a minor transformation is needed before the data can be imported.

The `vrs-to-vi-location-transformer` Cloud Run job — defined in this project at `src/vrs-location-transformer/` — streams the VRS output through a `jq` filter that flattens each location's `start` and `end` arrays into separate scalar fields: `start`, `start_inner`, `start_outer`, `end`, `end_inner`, `end_outer`. When `start` or `end` is already a scalar (precise variants), the value is left unchanged.

```bash
gcloud run jobs execute vrs-to-vi-location-transformer \
  --args "gs://clinvar-gks/YYYY-MM-DD/dev/vi-normalized-no-liftover.jsonl.gz" \
  --args "gs://clinvar-gks/YYYY-MM-DD/dev/vi-final.jsonl.gz" \
  --wait --region us-east1
```

**Output:** `vi-final.jsonl.gz` on GCS.

### Step 4: Load into BigQuery

The transformed output is loaded into the `gks_vrs` table using the `vrs_output_2_0_1` schema.

```bash
bq load --source_format=NEWLINE_DELIMITED_JSON \
  --schema=vrs_output_2_0_1.schema.json \
  --max_bad_records=2 --ignore_unknown_values --replace \
  'clinvar_YYYY_MM_DD_v2_4_3.gks_vrs' \
  gs://clinvar-gks/YYYY-MM-DD/dev/vi-final.jsonl.gz
```

---

## Output Table (`gks_vrs`)

The `gks_vrs` table contains one row per variation that was submitted for VRS processing. Each row is a two-part record:

<div class="field-table" markdown>

| Field | Type | Description |
|---|---|---|
| `in` | record | The original `variation_identity` record — all fields from the input including `variation_id`, `source`, `fmt`, `vrs_class`, copy number fields, and metadata |
| `out` | record | The VRS resolution result — contains `id` (VRS digest identifier), `type` (Allele, CopyNumberChange, CopyNumberCount), `location`, `state`, `copyChange`, `copies`, and `errors` when resolution failed |

</div>

The `out.location` record includes the flattened position fields: `start`, `end`, `start_inner`, `start_outer`, `end_inner`, `end_outer`. For precise variants only `start` and `end` are populated; imprecise ranges use the inner/outer fields.

---

## Current Scope and Future Direction

!!! warning "Limited Scope"
    VRS processing currently resolves only the **single best expression** per variation — the defining allele for each Canonical Allele as selected by the [precedence hierarchy](variation-identity/index.md#precedence-hierarchy). Only variations that vrs-python can handle are successfully resolved; the remainder carry errors in the output.

Two areas of improvement are planned:

- **Broader expression coverage** — expand VRS processing to resolve **all variant expressions** in ClinVar — the full `hgvs_list` preserved in the `variation_hgvs` table — rather than only the single selected source. This will provide richer downstream representation with multiple VRS identities per variation.
- **Tighter pipeline integration** — automate this step so it no longer requires manual orchestration between the BigQuery procedures on either side. The goal is a single end-to-end pipeline invocation from `variation_identity` through final JSON export.

---

## Dependencies

- **External tools**: [clinvar-gk-python](https://github.com/clingen-data-model/clinvar-gk-python) (specifically `misc/clinvar-vrsification`), [vrs-python](https://github.com/ga4gh/vrs-python), [variation-normalizer](https://github.com/GenomicMedLab/variation-normalizer), SeqRepo
- **Cloud Run job**: `vrs-to-vi-location-transformer` (`src/vrs-location-transformer/`) — location field flattening
- **BigQuery schema**: `schemas/vrs_output_2_0_1.schema.json`
- **Source table**: [`variation_identity`](variation-identity/variation-identity.md)
- **Downstream consumer**: [`gks_catvar_proc`](cat-vrs/index.md)
