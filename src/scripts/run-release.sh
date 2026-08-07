#!/bin/bash
#
# run-release.sh — end-to-end ClinVar-GKS release pipeline for a single release date.
#
# Chains the five stages that turn an ingested ClinVar release into published GKS output:
# Stage 0 (dataset_diff_on) runs ahead of stage 1 to build the {S}.diff_* drivers, and a
# version stamp (gks_pipeline_version) is written between stages 3 and 4.
#
#   1. variation_identity   BigQuery CALL   (incremental by default; full with --full)
#   2. export-vi-to-gcs      src/scripts/export-vi-table-to-gcs.sh   -> gs://.../vi.jsonl.gz
#   3. vrsify                src/vrsify/vrsify.sh   (external vrs-python; needs local services)
#   4. vrs-to-bq             src/scripts/vrs-to-bq-table.sh
#                            (Cloud Run transform -> load gks_vrs -> gks_* procs)
#   5. release               src/scripts/release-gks.sh
#                            (export dict bundle + Parquet -> assemble -> upload to Cloudflare R2)
#
# Stages 1 and 2 are incremental by default (recompute only changed variations, carry the
# rest forward). Stage 4 self-corrects between incremental and full loads. --full forces a
# full rebuild across stages 1-2 and is REQUIRED after any version-invalidating change (the
# variation_identity transform, or the vrsify pin in src/vrsify/requirements.txt).
#
# Stage 5 publishes to the public R2 bucket. Use --dry-run to run everything but have the
# release stage only print what it would upload (no R2 writes) — use it for test runs.
# NOTE: --dry-run still writes the pipeline_version stamp to BigQuery; --dry-run only gates
# Stage 5 / R2 upload.
#
# USAGE:
#   ./src/scripts/run-release.sh YYYY-MM-DD [--full] [--dry-run] [--start-step N]
#
#   --full          full rebuild of stages 1-2 (reseed the baseline)
#   --dry-run       stage 5 (release-gks.sh) runs in dry-run: no R2 upload / no GCS writes
#   --start-step N  begin at stage N (1-5); default 1. Stage 3 (vrsify) needs the local
#                   SeqRepo/UTA/gene-norm services — see src/vrsify/README.md.
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
DRY_RUN=false
START_STEP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --start-step) START_STEP="${2:?--start-step needs a number}"; shift 2 ;;
    --start-step=*) START_STEP="${1#*=}"; shift ;;
    -*) echo "ERROR: unknown flag: $1" >&2; exit 1 ;;
    *) if [[ -z "$DATE" ]]; then DATE="$1"; shift; else echo "ERROR: unexpected arg: $1" >&2; exit 1; fi ;;
  esac
done

if [[ -z "$DATE" ]]; then
  echo "Usage: $0 YYYY-MM-DD [--full] [--dry-run] [--start-step N]" >&2
  exit 1
fi

echo "=== run-release ${DATE} (full=${FULL}, dry-run=${DRY_RUN}, start-step=${START_STEP}, project=${PROJECT_ID}) ==="

# --- Stage 0: dataset diff (produces {S}.diff_* — drivers for all incremental procs) ----
# Idempotent (CREATE OR REPLACE). On the first release it emits a warning and writes no
# diff tables, which correctly makes the incremental guards fall back to a full rebuild.
if (( START_STEP <= 1 )); then
  echo ">>> [0/5] dataset_diff_on (build {S}.diff_* drivers)"
  bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
    "CALL \`clinvar_ingest.dataset_diff_on\`(DATE '${DATE}')"
fi

# --- Stage 1: variation_identity -------------------------------------------------------
if (( START_STEP <= 1 )); then
  if $FULL; then
    echo ">>> [1/5] variation_identity (FULL rebuild)"
    bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
      "CALL \`clinvar_ingest.variation_identity\`(DATE '${DATE}', FALSE)"
  else
    echo ">>> [1/5] variation_identity_incremental"
    bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
      "CALL \`clinvar_ingest.variation_identity_incremental\`(DATE '${DATE}', FALSE)"
  fi
fi

# --- Stage 2: export variation_identity to GCS -----------------------------------------
if (( START_STEP <= 2 )); then
  echo ">>> [2/5] export-vi-table-to-gcs.sh"
  if $FULL; then
    "${REPO_ROOT}/src/scripts/export-vi-table-to-gcs.sh" "${DATE}" --full
  else
    "${REPO_ROOT}/src/scripts/export-vi-table-to-gcs.sh" "${DATE}"
  fi
fi

# --- Stage 3: vrsify (external vrs-python) ---------------------------------------------
if (( START_STEP <= 3 )); then
  echo ">>> [3/5] vrsify.sh (vrs-python; requires local SeqRepo/UTA/gene-norm services)"
  "${REPO_ROOT}/src/vrsify/vrsify.sh" "${DATE}"
fi

# --- Version stamp: record provenance + the carry-forward gate key -----------------------
# audit_stamp = full git describe (provenance, always). gate_key = last commit touching the
# build-relevant paths (only advances when build logic changes; docs-only commits don't).
if (( START_STEP <= 4 )); then
  AUDIT_STAMP="$(git -C "${REPO_ROOT}" describe --tags --always --dirty)"
  if $FULL; then
    # A forced full rebuild deliberately invalidates carry-forward: stamp a unique gate so no
    # baseline can match it this release (the downstream procs then all full-rebuild).
    GATE_KEY="FULL-${AUDIT_STAMP}-$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  else
    GATE_KEY="$(git -C "${REPO_ROOT}" log -1 --format=%H -- src/procedures src/scripts src/vrsify)"
  fi
  # These values are spliced into a single-quoted SQL literal below; a stray single quote
  # would break out of it. Abort rather than emit malformed SQL.
  case "${AUDIT_STAMP}${GATE_KEY}" in *\'*) echo "ERROR: version stamp contains a single quote" >&2; exit 1;; esac
  echo ">>> stamping pipeline_version audit=${AUDIT_STAMP} gate=${GATE_KEY}"
  bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
    "CALL \`clinvar_ingest.gks_pipeline_version\`(DATE '${DATE}', '${AUDIT_STAMP}', '${GATE_KEY}')"
fi

# --- Stage 4: transform -> load gks_vrs -> gks_* procs ---------------------------------
if (( START_STEP <= 4 )); then
  echo ">>> [4/5] vrs-to-bq-table.sh (transform, load gks_vrs, run gks_* procs)"
  "${REPO_ROOT}/src/scripts/vrs-to-bq-table.sh" "${DATE}"
fi

# --- Stage 5: export bundle + Parquet, upload to R2 ------------------------------------
if (( START_STEP <= 5 )); then
  echo ">>> [5/5] release-gks.sh (export bundle + Parquet, upload to R2)"
  # release-gks.sh needs the dataset version (e.g. v2_5_0); derive it from the dataset name.
  DATE_US="${DATE//-/_}"
  DATASET_ID="$(bq ls --project_id="${PROJECT_ID}" --max_results=10000 \
    | awk '{$1=$1; print}' | grep "^clinvar_${DATE_US}_" | head -n 1)"
  if [[ -z "${DATASET_ID}" ]]; then
    echo "ERROR: no dataset found matching clinvar_${DATE_US}_* in ${PROJECT_ID}" >&2
    exit 1
  fi
  DATASET_VERSION="${DATASET_ID#clinvar_"${DATE_US}"_}"
  echo "    dataset=${DATASET_ID} version=${DATASET_VERSION}"

  RELEASE_ARGS=("${DATE}" "${DATASET_VERSION}")
  $DRY_RUN && RELEASE_ARGS+=("--dry-run")
  "${REPO_ROOT}/src/scripts/release-gks.sh" "${RELEASE_ARGS[@]}"
fi

echo "=== run-release ${DATE} complete ==="
