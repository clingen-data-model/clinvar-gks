#!/bin/bash
#
# run-release.sh — end-to-end ClinVar-GKS release pipeline for a single release date.
#
# Chains the four stages that turn an ingested ClinVar release into published GKS output:
#
#   1. variation_identity   BigQuery CALL   (incremental by default; full with --full)
#   2. export-vi-to-gcs      src/scripts/export-vi-table-to-gcs.sh   -> gs://.../vi.jsonl.gz
#   3. vrsify                src/vrsify/vrsify.sh   (external vrs-python; needs local services)
#   4. vrs-to-bq             src/scripts/vrs-to-bq-table.sh
#                            (Cloud Run transform -> load gks_vrs -> gks_* procs -> export/publish)
#
# Stages 1 and 2 are incremental by default (recompute only changed variations, carry the
# rest forward). Stage 4 self-corrects between incremental and full loads. --full forces a
# full rebuild across the whole chain and is REQUIRED after any version-invalidating change
# (the variation_identity transform, or the vrsify pin in src/vrsify/requirements.txt).
#
# USAGE:
#   ./src/scripts/run-release.sh YYYY-MM-DD [--full] [--start-step N]
#
#   --full          full rebuild of stage 1 + full export in stage 2 (reseed the baseline)
#   --start-step N  begin at stage N (1-4); default 1. Stage 3 (vrsify) needs the local
#                   SeqRepo/UTA/gene-norm services running — see src/vrsify/README.md.
#
# NOTE: stage 3 cannot run in CI/headless environments; run it on a host with the
# variation-normalizer service topology, or use --start-step to run the BigQuery-side
# stages separately from vrsify.

set -o errexit
set -o nounset
set -o pipefail

PROJECT_ID="${PROJECT_ID:-clingen-dev}"
# Keep gcloud/bq defaulting to the same project so the bq wrapper does not prepend a
# mismatched --project_id (a wrong gcloud default can wedge bq on status polling).
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DATE=""
FULL=false
START_STEP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=true; shift ;;
    --start-step) START_STEP="${2:?--start-step needs a number}"; shift 2 ;;
    --start-step=*) START_STEP="${1#*=}"; shift ;;
    -*) echo "ERROR: unknown flag: $1" >&2; exit 1 ;;
    *) if [[ -z "$DATE" ]]; then DATE="$1"; shift; else echo "ERROR: unexpected arg: $1" >&2; exit 1; fi ;;
  esac
done

if [[ -z "$DATE" ]]; then
  echo "Usage: $0 YYYY-MM-DD [--full] [--start-step N]" >&2
  exit 1
fi

echo "=== run-release ${DATE} (full=${FULL}, start-step=${START_STEP}, project=${PROJECT_ID}) ==="

# --- Stage 1: variation_identity -------------------------------------------------------
if (( START_STEP <= 1 )); then
  if $FULL; then
    echo ">>> [1/4] variation_identity (FULL rebuild)"
    bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
      "CALL \`clinvar_ingest.variation_identity\`(DATE '${DATE}', FALSE)"
  else
    echo ">>> [1/4] variation_identity_incremental"
    bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
      "CALL \`clinvar_ingest.variation_identity_incremental\`(DATE '${DATE}', FALSE)"
  fi
fi

# --- Stage 2: export variation_identity to GCS -----------------------------------------
if (( START_STEP <= 2 )); then
  echo ">>> [2/4] export-vi-table-to-gcs.sh"
  if $FULL; then
    "${REPO_ROOT}/src/scripts/export-vi-table-to-gcs.sh" "${DATE}" --full
  else
    "${REPO_ROOT}/src/scripts/export-vi-table-to-gcs.sh" "${DATE}"
  fi
fi

# --- Stage 3: vrsify (external vrs-python) ---------------------------------------------
if (( START_STEP <= 3 )); then
  echo ">>> [3/4] vrsify.sh (vrs-python; requires local SeqRepo/UTA/gene-norm services)"
  "${REPO_ROOT}/src/vrsify/vrsify.sh" "${DATE}"
fi

# --- Stage 4: transform -> load gks_vrs -> gks_* procs -> export/publish ----------------
if (( START_STEP <= 4 )); then
  echo ">>> [4/4] vrs-to-bq-table.sh"
  "${REPO_ROOT}/src/scripts/vrs-to-bq-table.sh" "${DATE}"
fi

echo "=== run-release ${DATE} complete ==="
