#!/bin/bash

# Backfill a historical monthly ClinVar-GKS release to Cloudflare R2.
#
# Use this script to upload past monthly releases that were not captured
# by the normal pipeline. It uploads directly to the monthly destination
# without updating the 00-latest pointer.
#
# Destination is derived from the export year vs. the current calendar year:
#   Current year:  datasets/clinvar-gks_{YYYY}-{MM}.json.gz          (+ datasets/parquet/{YYYY-MM}/)
#   Prior year:    archives/{YYYY}/clinvar-gks_{YYYY}-{MM}.json.gz   (+ archives/{YYYY}/parquet/{YYYY-MM}/)
#
# Pass --parquet-dir=DIR to also backfill that month's typed Parquet set to the dated
# path (datasets/parquet/{YYYY-MM}/ or archives/{YYYY}/parquet/{YYYY-MM}/).
#
# The 00-latest pointers (JSON and Parquet) are NOT updated — this is a backfill, not the
# most recent release. Run the normal upload-gks-to-r2.sh for current releases.
#
# Usage:
#   ./backfill-monthly-to-r2.sh <export_date> <dataset_version> <bundle_file> [--dry-run] [--parquet-dir=DIR]
#
# Examples:
#   ./backfill-monthly-to-r2.sh 2026-03-29 v2_5_0 /tmp/clinvar-gks-2026-03-29.json.gz
#   ./backfill-monthly-to-r2.sh 2025-11-28 v2_4_0 /tmp/clinvar-gks-2025-11-28.json.gz --dry-run
#   ./backfill-monthly-to-r2.sh 2026-03-29 v2_5_0 /tmp/bundle.json.gz --parquet-dir=/tmp/parquet

set -e

# --- Positional arguments ---
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <export_date> <dataset_version> <bundle_file> [--dry-run] [--parquet-dir=DIR]"
  echo "  export_date      ClinVar release date (YYYY-MM-DD)"
  echo "  dataset_version  Dataset version (e.g. v2_5_0)"
  echo "  bundle_file      Local path to the assembled bundle (.json.gz)"
  exit 1
fi

EXPORT_DATE="$1"
DATASET_VERSION="$2"
BUNDLE_FILE="$3"
shift 3

# Validate date format
if ! [[ "$EXPORT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: export_date must be YYYY-MM-DD format, got '${EXPORT_DATE}'"
  exit 1
fi

# --- Parse flags ---
DRY_RUN=false
PARQUET_DIR=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --parquet-dir=*) PARQUET_DIR="${arg#--parquet-dir=}" ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      exit 1
      ;;
  esac
done

# --- R2 Configuration ---
R2_ACCOUNT_ID="09208aa33790838db213a21f630c33e7"
R2_BUCKET="clinvar-gks"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
R2_PROFILE="r2"
R2_PUBLIC_URL="https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# --- Derived date components ---
YEAR="${EXPORT_DATE:0:4}"
MM="${EXPORT_DATE:5:2}"
CURRENT_YEAR="$(date +%Y)"

# --- Filenames ---
MONTHLY_FILE="clinvar-gks_${YEAR}-${MM}.json.gz"

# --- Destination (JSON bundle + dated Parquet set) ---
if [[ "$YEAR" == "$CURRENT_YEAR" ]]; then
  DEST="datasets/${MONTHLY_FILE}"
  PARQUET_DEST_PREFIX="datasets/parquet/${YEAR}-${MM}"
else
  DEST="archives/${YEAR}/${MONTHLY_FILE}"
  PARQUET_DEST_PREFIX="archives/${YEAR}/parquet/${YEAR}-${MM}"
fi

# =====================================================================
# Helper functions
# =====================================================================

r2_upload() {
  local src="$1" dest="$2" content_type="${3:-application/gzip}"
  if $DRY_RUN; then
    echo "  [dry-run] upload: ${dest}"
    return
  fi
  aws s3 cp "$src" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --content-type "${content_type}" \
    --quiet
}

r2_ls() {
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    2>/dev/null | awk '{print $NF}' || true
}

r2_ls_with_size() {
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    2>/dev/null | awk '/\.json\.gz$/ {print $3, $4}' || true
}

upload_parquet_backfill() {
  # Backfill this month's typed Parquet to the dated path. Like the JSON backfill it does
  # NOT touch datasets/parquet/00-latest/ — that pointer belongs to the most recent release.
  local parquet_dir="$1"
  if [[ -z "$parquet_dir" || ! -d "$parquet_dir" ]]; then
    echo "  (no Parquet dir found, skipping)"
    return
  fi
  echo "--- Uploading Parquet section files -> ${PARQUET_DEST_PREFIX}/ ---"
  local uploaded=0
  for parquet_file in "${parquet_dir}"/*.parquet; do
    [[ -f "$parquet_file" ]] || continue
    local section
    section="$(basename "${parquet_file}" .parquet)"
    echo "  ${PARQUET_DEST_PREFIX}/${section}.parquet"
    r2_upload "${parquet_file}" "${PARQUET_DEST_PREFIX}/${section}.parquet" \
      "application/vnd.apache.parquet"
    (( uploaded++ )) || true
  done
  echo "  ${uploaded} Parquet files uploaded to ${PARQUET_DEST_PREFIX}/."
}

# =====================================================================
# Main
# =====================================================================

echo "=== ClinVar-GKS Backfill Monthly ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Version:       ${DATASET_VERSION}"
echo "  Monthly file:  ${MONTHLY_FILE}"
echo "  Destination:   ${DEST}"
if $DRY_RUN; then
  echo "  Mode:          DRY RUN"
fi
echo ""

# --- Check bundle file ---
echo "Checking bundle: ${BUNDLE_FILE}"
if ! $DRY_RUN && [[ ! -f "${BUNDLE_FILE}" ]]; then
  echo "ERROR: Bundle file not found at ${BUNDLE_FILE}"
  exit 1
fi
echo ""

# --- Upload monthly file ---
echo "--- Uploading monthly release ---"
echo "  ${DEST}"
r2_upload "${BUNDLE_FILE}" "${DEST}"
echo ""

# --- Upload dated Parquet set (if provided) ---
if [[ -n "${PARQUET_DIR}" ]]; then
  upload_parquet_backfill "${PARQUET_DIR}"
  echo ""
fi

# --- Regenerate index.json via the shared delta-aware generator ---
# (Do NOT inline an index builder here — it would write the retired weekly-schema index and
#  clobber the deltas-aware index.json. generate-r2-index.sh reflects current R2 state:
#  monthly fulls + archives + deltas.)
echo "--- Regenerating index.json ---"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEX_ARGS=()
$DRY_RUN && INDEX_ARGS+=("--dry-run")
"${SCRIPT_DIR}/generate-r2-index.sh" "${INDEX_ARGS[@]}"

# --- Summary ---
echo ""
echo "=== Backfill Complete ==="
echo "  Monthly: ${R2_PUBLIC_URL}/${DEST}"
if [[ -n "${PARQUET_DIR}" && -d "${PARQUET_DIR}" ]]; then
  echo "  Parquet: ${R2_PUBLIC_URL}/${PARQUET_DEST_PREFIX}/"
fi
echo "  Index:   ${R2_PUBLIC_URL}/index.json"
