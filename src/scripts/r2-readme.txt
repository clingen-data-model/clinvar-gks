ClinVar-GKS Data Distribution
==============================

This bucket contains ClinVar data transformed into GA4GH GKS format
(VRS, Cat-VRS, VA-Spec). The full dataset is a gzip-compressed keyed JSON
bundle (plus typed Parquet, one file per section). Per-release weekly
deltas ship the records that changed since the prior release so consumers
can stay current without re-downloading the full set every week.

Distribution model
------------------

  * Full bundle + Parquet: published MONTHLY (the last release of each month).
  * Weekly deltas: published EVERY release (added/updated records + a manifest
    of deletes), in the same section structure as the full bundle.

To reconstruct the latest state: download the most recent monthly full, then
replay the contiguous weekly deltas published after it (apply each delta's
manifest deletes, then upsert its records — section by section).

Directory Structure
-------------------

datasets/
  Monthly full bundles for the current year.
  clinvar-gks_00-latest.json.gz  — always the most recent monthly full.
  clinvar-gks_yyyy-mm.json.gz    — monthly full for a specific month.

datasets/parquet/
  Typed Parquet for the latest monthly full, one file per section
  (<section>.parquet).

deltas/
  Per-release weekly deltas.
  deltas/yyyy-mmdd/
    clinvar-gks-delta_yyyy-mmdd.json.gz — added + updated records (same
                                          section structure as the full bundle).
    manifest.json                       — release/baseline/compare stamps,
                                          checkpoint_full pointer, and per-section
                                          added/updated counts + deleted keys.
    parquet/<section>.parquet           — typed Parquet for the delta's sections.
  deltas/00-latest/                     — mirror of the most recent delta.

archives/
  Prior years' monthly full bundles, organized by year (archives/yyyy/).

index.json
  Machine-readable listing of the monthly fulls, archives, and delta releases.

Quick Start
-----------

Download the latest monthly full:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

Fetch the latest weekly delta + its manifest:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/manifest.json

Documentation: https://clingen-data-model.github.io/clinvar-gks/
Source: https://github.com/clingen-data-model/clinvar-gks
