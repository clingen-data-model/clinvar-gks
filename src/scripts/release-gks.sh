#!/bin/bash

# Release ClinVar-GKS: export from BigQuery, assemble bundle, upload to R2.
#
# Combines three pipeline steps into a single command:
#   1. export-gks-dicts.sh  — export dictionary tables to GCS as NDJSON
#   2. assemble-gks-dicts.py — assemble NDJSON into a single JSON bundle
#   3. upload-gks-to-r2.sh  — upload bundle from GCS to Cloudflare R2
#
# Usage:
#   ./release-gks.sh <export_date> <dataset_version> [--keep-source] [--dry-run] [--skip-export]
#
# Examples:
#   ./release-gks.sh 2026-05-03 v2_5_0
#   ./release-gks.sh 2026-05-03 v2_5_0 --dry-run
#   ./release-gks.sh 2026-05-03 v2_5_0 --keep-source
#   ./release-gks.sh 2026-05-03 v2_5_0 --skip-export   # re-run from assemble step

set -e

# --- Positional arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <export_date> <dataset_version> [--keep-source] [--dry-run] [--skip-export]"
  echo "  export_date      ClinVar release date (YYYY-MM-DD)"
  echo "  dataset_version  Dataset version (e.g. v2_5_0)"
  exit 1
fi

EXPORT_DATE="$1"
DATASET_VERSION="$2"
shift 2

# Validate date format
if ! [[ "$EXPORT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: export_date must be YYYY-MM-DD format, got '${EXPORT_DATE}'"
  exit 1
fi

# --- Parse flags ---
DRY_RUN=false
KEEP_SOURCE=false
SKIP_EXPORT=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --keep-source) KEEP_SOURCE=true ;;
    --skip-export) SKIP_EXPORT=true ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      exit 1
      ;;
  esac
done

# --- Configuration ---
GCS_BUCKET="clinvar-gks"
GCS_DICTS_PREFIX="gks-dicts"
GCS_DICTS_PATH="gs://${GCS_BUCKET}/${GCS_DICTS_PREFIX}"
DATE_UNDERSCORED="${EXPORT_DATE//-/_}"
BQ_DATASET="clinvar_${DATE_UNDERSCORED}_${DATASET_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [[ -x "${PROJECT_ROOT}/venv/3.12/bin/python3" ]]; then
  PYTHON="${PROJECT_ROOT}/venv/3.12/bin/python3"
else
  PYTHON="python3"
fi

echo "=== ClinVar-GKS Release Pipeline ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Version:       ${DATASET_VERSION}"
echo "  BQ dataset:    ${BQ_DATASET}"
echo "  GCS dicts:     ${GCS_DICTS_PATH}/"
echo "  GCS output:    gs://${GCS_BUCKET}/${EXPORT_DATE}/release/clinvar-gks-${EXPORT_DATE}.json.gz"
$DRY_RUN && echo "  Mode:          DRY RUN"
$KEEP_SOURCE && echo "  Keep source:   YES"
$SKIP_EXPORT && echo "  Skip export:   YES"
echo ""

# =====================================================================
# Step 1: Export dictionary tables from BigQuery to GCS
# =====================================================================

if ! $SKIP_EXPORT; then
  echo "=== Step 1/3: Exporting dictionary tables ==="
  if $DRY_RUN; then
    echo "  [dry-run] Would run: export-gks-dicts.sh ${BQ_DATASET} ${GCS_BUCKET} ${GCS_DICTS_PREFIX}"
  else
    "${SCRIPT_DIR}/export-gks-dicts.sh" "${BQ_DATASET}" "${GCS_BUCKET}" "${GCS_DICTS_PREFIX}"
  fi
  echo ""
else
  echo "=== Step 1/3: Skipped (--skip-export) ==="
  echo ""
fi

# =====================================================================
# Step 2: Assemble NDJSON into a single JSON bundle
# =====================================================================

echo "=== Step 2/3: Assembling bundle ==="
ASSEMBLE_ARGS=("${GCS_DICTS_PATH}/" "${EXPORT_DATE}")
if $KEEP_SOURCE; then
  ASSEMBLE_ARGS+=("--keep-source")
fi

if $DRY_RUN; then
  echo "  [dry-run] Would run: ${PYTHON} assemble-gks-dicts.py ${ASSEMBLE_ARGS[*]}"
else
  "${PYTHON}" "${SCRIPT_DIR}/assemble-gks-dicts.py" "${ASSEMBLE_ARGS[@]}"
fi
echo ""

# =====================================================================
# Step 3: Upload bundle from GCS to Cloudflare R2
# =====================================================================

echo "=== Step 3/3: Uploading to R2 ==="
UPLOAD_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}")
if $DRY_RUN; then
  UPLOAD_ARGS+=("--dry-run")
fi

"${SCRIPT_DIR}/upload-gks-to-r2.sh" "${UPLOAD_ARGS[@]}"
