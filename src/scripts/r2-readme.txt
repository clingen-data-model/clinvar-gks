ClinVar-GKS Data Distribution
==============================

This bucket contains ClinVar data transformed into GA4GH GKS format
(VRS, Cat-VRS, VA-Spec). Files are gzip-compressed JSON bundles.

Directory Structure
-------------------

datasets/
  Monthly dataset files for the current year.
  clinvar-gks_00-latest.json.gz  — always the most recent monthly release.
  clinvar-gks_yyyy-mm.json.gz    — monthly release for a specific month.

datasets/weekly/
  Weekly dataset files for the current month.
  clinvar-gks_00-latest_weekly.json.gz  — always the most recent weekly release.
  clinvar-gks_yyyy-mmdd.json.gz         — weekly release for a specific date.

archives/
  Prior years' monthly and weekly files, organized by year.
  archives/yyyy/                        — monthly files for that year.
  archives/yyyy/weekly/                 — weekly files for that year.

release_notes/
  Pipeline change notes describing additions, fixes, or structural changes
  to the GKS output format. Named yyyymmdd-description.txt.

Quick Start
-----------

Download the latest release:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

Download the latest weekly:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz

Documentation: https://clingen-data-model.github.io/clinvar-gks/
Source: https://github.com/clingen-data-model/clinvar-gks
