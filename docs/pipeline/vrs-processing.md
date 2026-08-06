# VRS Processing

## Overview

VRS processing is the manual step between [Variation Identity](variation-identity/index.md) extraction and [Cat-VRS](cat-vrs/index.md) generation. It translates the selected SPDI or HGVS expression for each variation's defining allele into a GA4GH VRS (Variation Representation Specification) object — producing a computable, digest-identified representation of the variant.

The step is driven by two scripts in this project with an external vrs-python step between them: `src/scripts/export-vi-table-to-gcs.sh` exports the input, [clinvar-gk-python](https://github.com/clingen-data-model/clinvar-gk-python) resolves VRS, and `src/scripts/vrs-to-bq-table.sh` transforms, loads, runs the downstream procedures, and publishes. Only the vrs-python resolution itself remains a manual, external invocation; a single end-to-end orchestrator is planned.

**This step is incremental.** vrs-python resolution is per-variation (no cross-variation dependency), so diffing `variation_identity` between releases is a clean driver: the export sends only the variations whose `variation_identity` changed since the prior release (~0.3% of a weekly release, versus the whole ~4.5M snapshot), and the `gks_vrs` load carries the prior release's results forward for the unchanged variations. This is where the largest cost reduction in the whole pipeline lands, because vrs-python is the most expensive stage.

VRS resolution is performed by the [clinvar-gk-python](https://github.com/clingen-data-model/clinvar-gk-python) project, which wraps [vrs-python](https://github.com/ga4gh/vrs-python) and the [variation-normalizer](https://github.com/GenomicMedLab/variation-normalizer) to resolve expressions against a local SeqRepo sequence repository. The location transformation step uses a lightweight Cloud Run job defined in this project under `src/vrs-location-transformer/`.

---

## Workflow

### Step 1: Export `variation_identity` from BigQuery

The `variation_identity` table is exported to Google Cloud Storage as gzipped NDJSON at `gs://clinvar-gks/YYYY-MM-DD/dev/vi.jsonl.gz`.

```bash
./src/scripts/export-vi-table-to-gcs.sh YYYY-MM-DD          # incremental (default)
./src/scripts/export-vi-table-to-gcs.sh YYYY-MM-DD --full   # whole table
```

By default the export is **incremental** — it diffs `variation_identity` against the prior release and writes only the changed variations, so vrs-python processes the delta. Pass `--full` for the first release or after a vrs-python / `variation_identity` transform change (see the version-invalidation note below).

Each record contains the single best expression source for a ClinVar variation — including the `source` expression string, `fmt` (spdi, hgvs, or gnomad), `vrs_class`, and copy number fields when applicable.

### Step 2: Run clinvar-gk-python

The `misc/clinvar-vrsification` script in the clinvar-gk-python repository orchestrates VRS resolution. It accepts a release date and invokes the Python entry point with parallelism, reading whatever `vi.jsonl.gz` Step 1 produced — the changed delta by default, or the full snapshot when Step 1 was run with `--full`:

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

This job is normally invoked by the `src/scripts/vrs-to-bq-table.sh` orchestrator (Step 4), not run by hand; the direct invocation is shown for reference:

```bash
gcloud run jobs execute vrs-to-vi-location-transformer \
  --args "gs://clinvar-gks/YYYY-MM-DD/dev/vi-normalized-no-liftover.jsonl.gz" \
  --args "gs://clinvar-gks/YYYY-MM-DD/dev/vi-final.jsonl.gz" \
  --wait --region us-east1
```

**Output:** `vi-final.jsonl.gz` on GCS.

### Step 4: Transform, load, and publish

Steps 3–4 and the downstream pipeline are run by a single orchestrator, `src/scripts/vrs-to-bq-table.sh`, which executes the Cloud Run transform (Step 3), loads `gks_vrs`, runs the downstream stored procedures, and exports/publishes the final artifacts:

```bash
./src/scripts/vrs-to-bq-table.sh YYYY-MM-DD          # from the start (Cloud Run transform)
./src/scripts/vrs-to-bq-table.sh YYYY-MM-DD 2        # resume from a later step (2=load, 3=procs, 4=publish)
```

The `gks_vrs` load is **incremental**: it clones the prior release's `gks_vrs` forward and merges in only the changed variations' new results (keyed on `in.variation_id`), rather than a `--replace` full load. It **self-corrects to a full `--replace`** when no baseline `gks_vrs` exists or when the staged rows are not the changed subset — so a full export (Step 1 `--full`) is loaded correctly without any flag change.

!!! warning "Version-invalidation"
    The incremental carry-forward assumes the prior release's `gks_vrs` was produced by the **same** vrs-python normalizer and the **same** `variation_identity` transform. After a change to either, run Step 1 with `--full` on the next release to reprocess and reseed every variation; the load's self-correction then does a full `--replace`. Resume incremental afterward.

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

The full release now runs from a single command — `src/scripts/run-release.sh` chains variation identity, the export, this vrsify stage (via `src/vrsify/vrsify.sh`), and the transform/load/procedures/publish stages. See [Single-command run](index.md#single-command-run). The vrsify resolver is installed as a pinned dependency rather than forked (see [`src/vrsify/README.md`](https://github.com/clingen-data-model/clinvar-gks/tree/main/src/vrsify)); it still requires the local SeqRepo / UTA / gene-normalizer services.

One area of improvement remains planned:

- **Broader expression coverage** — expand VRS processing to resolve **all variant expressions** in ClinVar — the full `hgvs_list` preserved in the `variation_hgvs` table — rather than only the single selected source. This will provide richer downstream representation with multiple VRS identities per variation.

---

## Dependencies

- **External tools**: [clinvar-gk-python](https://github.com/clingen-data-model/clinvar-gk-python) (specifically `misc/clinvar-vrsification`), [vrs-python](https://github.com/ga4gh/vrs-python), [variation-normalizer](https://github.com/GenomicMedLab/variation-normalizer), SeqRepo
- **Cloud Run job**: `vrs-to-vi-location-transformer` (`src/vrs-location-transformer/`) — location field flattening
- **BigQuery schema**: `schemas/vrs_output_2_0_1.schema.json`
- **Source table**: [`variation_identity`](variation-identity/variation-identity.md)
- **Downstream consumer**: [`gks_catvar_proc`](cat-vrs/index.md)
