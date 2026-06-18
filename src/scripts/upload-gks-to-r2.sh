#!/bin/bash

# Upload ClinVar-GKS bundle file from GCS to Cloudflare R2.
# Runs after export-gks-dicts.sh and assemble-gks-dicts.py have produced the bundle.
#
# Manages the R2 directory structure:
#   datasets/                  — monthly files for the current year + 00-latest
#   datasets/weekly/           — weekly files for the current month + 00-latest_weekly
#   archives/{yyyy}/           — monthly files from prior years
#   archives/{yyyy}/weekly/    — weekly files from prior months
#   release_notes/             — pipeline change notes
#   README.txt                 — bucket overview
#
# On each upload the script auto-detects month and year boundaries:
#   - Always: uploads weekly file + updates latest weekly
#   - New month: archives previous weekly files, creates monthly file + updates latest
#   - New year: archives previous monthly files, then performs new-month steps
#
# Usage:
#   ./upload-gks-to-r2.sh <export_date> <dataset_version> [--dry-run]
#
# Examples:
#   ./upload-gks-to-r2.sh 2026-06-14 v2_5_0
#   ./upload-gks-to-r2.sh 2026-06-14 v2_5_0 --dry-run

set -e

# --- Positional arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <export_date> <dataset_version> [--dry-run]"
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
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      echo "Usage: $0 <export_date> <dataset_version> [--dry-run]"
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

# --- GCS Source Configuration ---
GCS_PUBLIC_BUCKET="clingen-public/clinvar-gks"

# --- Derived date components ---
YEAR="${EXPORT_DATE:0:4}"
MM="${EXPORT_DATE:5:2}"
DD="${EXPORT_DATE:8:2}"
YEAR_MONTH="${YEAR}-${MM}"       # 2026-06
MMDD="${MM}${DD}"                # 0614

# --- Filenames ---
WEEKLY_FILE="clinvar-gks_${YEAR}-${MMDD}.json.gz"
LATEST_WEEKLY="clinvar-gks_00-latest_weekly.json.gz"
MONTHLY_FILE="clinvar-gks_${YEAR_MONTH}.json.gz"
LATEST_MONTHLY="clinvar-gks_00-latest.json.gz"

# --- Locate script directory for r2-readme.txt ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

r2_copy() {
  local src="$1" dest="$2"
  if $DRY_RUN; then
    echo "  [dry-run] copy: ${src} -> ${dest}"
    return
  fi
  aws s3 cp "s3://${R2_BUCKET}/${src}" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --quiet
}

r2_ls() {
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    2>/dev/null | awk '{print $NF}' || true
}

r2_rm() {
  local key="$1"
  if $DRY_RUN; then
    echo "  [dry-run] delete: ${key}"
    return
  fi
  aws s3 rm "s3://${R2_BUCKET}/${key}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --quiet
}

# =====================================================================
# Detect current state
# =====================================================================

detect_boundaries() {
  # List existing dated weekly files (exclude 00-latest)
  EXISTING_WEEKLY_FILES=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && EXISTING_WEEKLY_FILES+=("$f")
  done < <(r2_ls "datasets/weekly/clinvar-gks_" | grep -v "00-latest" || true)

  IS_NEW_MONTH=false
  IS_NEW_YEAR=false
  PREV_YEAR=""
  PREV_MONTH=""

  if [[ ${#EXISTING_WEEKLY_FILES[@]} -gt 0 ]]; then
    # Extract year-month from first existing weekly file
    # Filename: clinvar-gks_2026-0607.json.gz -> year=2026, month=06
    local first="${EXISTING_WEEKLY_FILES[0]}"
    PREV_YEAR=$(echo "$first" | sed 's/clinvar-gks_\([0-9]\{4\}\)-.*/\1/')
    PREV_MONTH=$(echo "$first" | sed 's/clinvar-gks_[0-9]\{4\}-\([0-9]\{2\}\).*/\1/')

    if [[ "$YEAR" != "$PREV_YEAR" ]]; then
      IS_NEW_YEAR=true
      IS_NEW_MONTH=true
    elif [[ "$MM" != "$PREV_MONTH" ]]; then
      IS_NEW_MONTH=true
    fi
  else
    # No existing weekly files — treat as new month (first-ever upload or clean state)
    IS_NEW_MONTH=true
  fi
}

# =====================================================================
# Archive operations
# =====================================================================

archive_yearly() {
  # Move dated monthly files from datasets/ to archives/{prev_year}/
  echo "--- Year rollover: archiving ${PREV_YEAR} monthly files ---"

  local monthly_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && monthly_files+=("$f")
  done < <(r2_ls "datasets/clinvar-gks_" | grep -v "00-latest" || true)

  for f in "${monthly_files[@]}"; do
    echo "  Moving datasets/${f} -> archives/${PREV_YEAR}/${f}"
    r2_copy "datasets/${f}" "archives/${PREV_YEAR}/${f}"
    r2_rm "datasets/${f}"
  done

  # Clean up the old latest monthly (it will be recreated)
  if r2_ls "datasets/${LATEST_MONTHLY}" | grep -q "${LATEST_MONTHLY}"; then
    echo "  Removing old datasets/${LATEST_MONTHLY}"
    r2_rm "datasets/${LATEST_MONTHLY}"
  fi
}

archive_monthly() {
  # Move dated weekly files from datasets/weekly/ to archives/{archive_year}/weekly/
  local archive_year="${PREV_YEAR:-$YEAR}"
  echo "--- Month rollover: archiving weekly files to archives/${archive_year}/weekly/ ---"

  for f in "${EXISTING_WEEKLY_FILES[@]}"; do
    echo "  Moving datasets/weekly/${f} -> archives/${archive_year}/weekly/${f}"
    r2_copy "datasets/weekly/${f}" "archives/${archive_year}/weekly/${f}"
    r2_rm "datasets/weekly/${f}"
  done

  # Clean up old latest weekly
  if r2_ls "datasets/weekly/${LATEST_WEEKLY}" | grep -q "${LATEST_WEEKLY}"; then
    echo "  Removing old datasets/weekly/${LATEST_WEEKLY}"
    r2_rm "datasets/weekly/${LATEST_WEEKLY}"
  fi
}

# =====================================================================
# Main
# =====================================================================

echo "=== ClinVar-GKS Release Upload ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Version:       ${DATASET_VERSION}"
echo "  Weekly file:   ${WEEKLY_FILE}"
echo "  Monthly file:  ${MONTHLY_FILE}"
if $DRY_RUN; then
  echo "  Mode:          DRY RUN"
fi
echo ""

# --- Check GCS for the bundle ---
GCS_URI="gs://${GCS_PUBLIC_BUCKET}/${EXPORT_DATE}/release/clinvar-gks-${EXPORT_DATE}.json.gz"
echo "Checking GCS: ${GCS_URI}"
if ! gsutil -q stat "${GCS_URI}" 2>/dev/null; then
  GCS_URI="gs://${GCS_PUBLIC_BUCKET}/clinvar-gks-${EXPORT_DATE}.json.gz"
  if ! gsutil -q stat "${GCS_URI}" 2>/dev/null; then
    echo "ERROR: Bundle file not found in GCS."
    echo "  Run export-gks-dicts.sh and assemble-gks-dicts.py first."
    exit 1
  fi
fi

# --- Download bundle ---
LOCAL_TMP="/tmp/clinvar-gks-${EXPORT_DATE}.json.gz"
echo "Downloading bundle from GCS..."
if ! $DRY_RUN; then
  gsutil -o "GSUtil:check_hashes=never" -q cp "${GCS_URI}" "${LOCAL_TMP}"
fi

# --- Detect month/year boundaries ---
echo ""
echo "Detecting release boundaries..."
detect_boundaries
echo "  New month: ${IS_NEW_MONTH}"
echo "  New year:  ${IS_NEW_YEAR}"
echo ""

# --- Year rollover ---
if $IS_NEW_YEAR; then
  archive_yearly
  echo ""
fi

# --- Month rollover ---
if $IS_NEW_MONTH; then
  archive_monthly
  echo ""

  # Create monthly file
  echo "--- Creating monthly release ---"
  echo "  Uploading datasets/${MONTHLY_FILE}"
  r2_upload "${LOCAL_TMP}" "datasets/${MONTHLY_FILE}"

  echo "  Updating datasets/${LATEST_MONTHLY}"
  r2_upload "${LOCAL_TMP}" "datasets/${LATEST_MONTHLY}"
  echo ""
fi

# --- Always: upload weekly file ---
echo "--- Uploading weekly release ---"
echo "  Uploading datasets/weekly/${WEEKLY_FILE}"
r2_upload "${LOCAL_TMP}" "datasets/weekly/${WEEKLY_FILE}"

echo "  Updating datasets/weekly/${LATEST_WEEKLY}"
r2_upload "${LOCAL_TMP}" "datasets/weekly/${LATEST_WEEKLY}"

# --- Upload README.txt ---
README_SRC="${SCRIPT_DIR}/r2-readme.txt"
if [[ -f "${README_SRC}" ]]; then
  echo ""
  echo "Uploading README.txt"
  r2_upload "${README_SRC}" "README.txt" "text/plain"
fi

# --- Cleanup ---
if ! $DRY_RUN; then
  rm -f "${LOCAL_TMP}"
fi

# --- Summary ---
echo ""
echo "=== Upload Complete ==="
echo "  Weekly:  ${R2_PUBLIC_URL}/datasets/weekly/${WEEKLY_FILE}"
echo "  Latest:  ${R2_PUBLIC_URL}/datasets/weekly/${LATEST_WEEKLY}"
if $IS_NEW_MONTH; then
  echo "  Monthly: ${R2_PUBLIC_URL}/datasets/${MONTHLY_FILE}"
  echo "  Latest:  ${R2_PUBLIC_URL}/datasets/${LATEST_MONTHLY}"
fi
