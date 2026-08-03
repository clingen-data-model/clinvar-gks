#!/bin/bash

# Release ClinVar-GKS: export from BigQuery, assemble bundle, upload to R2.
#
# Combines four pipeline steps into a single command:
#   1. export-gks-dicts.sh  — export dictionary tables to GCS as NDJSON + Parquet
#   2. assemble-gks-dicts.py — assemble NDJSON into a single JSON bundle
#   3. Download Parquet files from GCS to local disk
#   4. upload-gks-to-r2.sh  — upload bundle + Parquet to Cloudflare R2
#
# Usage:
#   ./release-gks.sh <export_date> <dataset_version> [--start-step=N] [--keep-source] [--dry-run]
#
# Examples:
#   ./release-gks.sh 2026-05-03 v2_5_0
#   ./release-gks.sh 2026-05-03 v2_5_0 --dry-run
#   ./release-gks.sh 2026-05-03 v2_5_0 --keep-source
#   ./release-gks.sh 2026-05-03 v2_5_0 --start-step=2  # re-run from assemble step
#   ./release-gks.sh 2026-05-03 v2_5_0 --start-step=4  # re-run upload only

set -e

# --- Positional arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <export_date> <dataset_version> [--start-step=N] [--keep-source] [--dry-run]"
  echo "  export_date      ClinVar release date (YYYY-MM-DD)"
  echo "  dataset_version  Dataset version (e.g. v2_5_0)"
  echo "  --start-step=N   Start at step N (1=export, 2=assemble, 3=download parquet, 4=upload)"
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
START_STEP=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --keep-source) KEEP_SOURCE=true ;;
    --start-step=*) START_STEP="${arg#--start-step=}" ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      exit 1
      ;;
  esac
done

if ! [[ "$START_STEP" =~ ^[1-4]$ ]]; then
  echo "ERROR: --start-step must be 1, 2, 3, or 4, got '${START_STEP}'"
  exit 1
fi

# --- Configuration ---
GCS_BUCKET="clinvar-gks"
GCS_DICTS_PREFIX="gks-dicts"
GCS_DICTS_PATH="gs://${GCS_BUCKET}/${GCS_DICTS_PREFIX}"
GCS_PARQUET_PREFIX="${GCS_DICTS_PREFIX}-parquet"
GCS_PARQUET_PATH="gs://${GCS_BUCKET}/${GCS_PARQUET_PREFIX}"
DATE_UNDERSCORED="${EXPORT_DATE//-/_}"
BQ_DATASET="clinvar_${DATE_UNDERSCORED}_${DATASET_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [[ -x "${PROJECT_ROOT}/venv/3.12/bin/python3" ]]; then
  PYTHON="${PROJECT_ROOT}/venv/3.12/bin/python3"
else
  PYTHON="python3"
fi

BUNDLE_FILE="/tmp/clinvar-gks-${EXPORT_DATE}.json.gz"
PARQUET_DIR="/tmp/clinvar-gks-${EXPORT_DATE}-parquet"

echo "=== ClinVar-GKS Release Pipeline ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Version:       ${DATASET_VERSION}"
echo "  BQ dataset:    ${BQ_DATASET}"
echo "  GCS dicts:     ${GCS_DICTS_PATH}/"
echo "  GCS parquet:   ${GCS_PARQUET_PATH}/"
echo "  Bundle:        ${BUNDLE_FILE}"
echo "  Parquet dir:   ${PARQUET_DIR}"
$DRY_RUN && echo "  Mode:          DRY RUN"
$KEEP_SOURCE && echo "  Keep source:   YES"
[[ "$START_STEP" -gt 1 ]] && echo "  Start step:    ${START_STEP}"
echo ""

# =====================================================================
# Step 1: Export dictionary tables from BigQuery to GCS
# =====================================================================

if [[ "$START_STEP" -le 1 ]]; then
  echo "=== Step 1/4: Exporting dictionary tables ==="
  if $DRY_RUN; then
    echo "  [dry-run] Would clear ${GCS_DICTS_PATH}/ and ${GCS_PARQUET_PATH}/, then run: export-gks-dicts.sh ${BQ_DATASET} ${GCS_BUCKET} ${GCS_DICTS_PREFIX}"
  else
    # Clear gks-dicts and gks-parquet before export to ensure no stale shards from a prior run
    echo "  Clearing ${GCS_DICTS_PATH}/ ..."
    gsutil -m -q rm -r "${GCS_DICTS_PATH}/" 2>/dev/null || true
    echo "  Clearing ${GCS_PARQUET_PATH}/ ..."
    gsutil -m -q rm -r "${GCS_PARQUET_PATH}/" 2>/dev/null || true
    "${SCRIPT_DIR}/export-gks-dicts.sh" "${BQ_DATASET}" "${GCS_BUCKET}" "${GCS_DICTS_PREFIX}"
  fi
  echo ""
else
  echo "=== Step 1/4: Skipped (--start-step=${START_STEP}) ==="
  echo ""
fi

# =====================================================================
# Step 2: Assemble NDJSON into a single JSON bundle
# =====================================================================

if [[ "$START_STEP" -le 2 ]]; then
  echo "=== Step 2/4: Assembling bundle ==="
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
else
  echo "=== Step 2/4: Skipped (--start-step=${START_STEP}) ==="
  echo ""
fi

# =====================================================================
# Step 3: Download Parquet files from GCS
# =====================================================================

if [[ "$START_STEP" -le 3 ]]; then
  echo "=== Step 3/4: Downloading Parquet files from GCS ==="
  if $DRY_RUN; then
    echo "  [dry-run] Would download ${GCS_PARQUET_PATH}/ to ${PARQUET_DIR}/"
  else
    mkdir -p "${PARQUET_DIR}"
    GCS_DOWNLOAD_DIR="${PARQUET_DIR}/_gcs_shards"
    mkdir -p "${GCS_DOWNLOAD_DIR}"
    gsutil -m cp "${GCS_PARQUET_PATH}/*.parquet" "${GCS_DOWNLOAD_DIR}/"

    # Merge sharded Parquet files into one file per section.
    # BQ export produces shards like allele-000000000000.parquet, allele-000000000001.parquet.
    # Consumers expect a single allele.parquet per section.
    echo "  Merging shards into single files per section..."
    for first_shard in "${GCS_DOWNLOAD_DIR}"/*-000000000000.parquet; do
      [ -f "$first_shard" ] || continue
      section_base="$(basename "$first_shard" | sed 's/-000000000000\.parquet//')"
      merged="${PARQUET_DIR}/${section_base}.parquet"
      echo "    ${section_base} ($(ls -1 "${GCS_DOWNLOAD_DIR}/${section_base}"-*.parquet | wc -l) shards)"
      duckdb -c "COPY (SELECT * FROM read_parquet('${GCS_DOWNLOAD_DIR}/${section_base}-*.parquet')) TO '${merged}' (FORMAT PARQUET, COMPRESSION SNAPPY);"
    done
    rm -rf "${GCS_DOWNLOAD_DIR}"

    echo "  ${PARQUET_DIR}/ contains $(ls -1 "${PARQUET_DIR}"/*.parquet 2>/dev/null | wc -l) Parquet files"
  fi
  echo ""
else
  echo "=== Step 3/4: Skipped (--start-step=${START_STEP}) ==="
  echo ""
fi

# =====================================================================
# Step 4: Upload bundle and Parquet to Cloudflare R2
# =====================================================================

echo "=== Step 4/4: Uploading to R2 ==="
UPLOAD_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}" "${BUNDLE_FILE}" "--parquet-dir=${PARQUET_DIR}")
if $DRY_RUN; then
  UPLOAD_ARGS+=("--dry-run")
fi

"${SCRIPT_DIR}/upload-gks-to-r2.sh" "${UPLOAD_ARGS[@]}"

# --- Cleanup ---
if ! $DRY_RUN; then
  rm -f "${BUNDLE_FILE}"
  rm -rf "${PARQUET_DIR}"
  if ! $KEEP_SOURCE; then
    echo "  Cleaning up GCS Parquet files..."
    gsutil -m -q rm -r "${GCS_PARQUET_PATH}/" 2>/dev/null || true
  fi
fi
