#!/bin/bash

# Upload ClinVar-GKS bundle file from GCS to Cloudflare R2.
# Runs after export-gks-dicts.sh and assemble-gks-dicts.py have produced the bundle.
#
# Manages the R2 directory structure:
#   datasets/                  — monthly files for the current year + 00-latest
#   datasets/weekly/           — weekly files for the current month + 00-latest_weekly
#   archives/{yyyy}/           — monthly files from prior years
#   release_notes/             — pipeline change notes
#   README.txt                 — bucket overview
#
# On each upload the script auto-detects month and year boundaries:
#   - Always: uploads weekly file + updates latest weekly
#   - New month: promotes last weekly from prior month as that month's monthly
#               release + updates latest, then deletes prior month's weekly files
#   - New year: archives prior year's monthly files to archives/{yyyy}/ (after promoting)
#
# Usage:
#   ./upload-gks-to-r2.sh <export_date> <dataset_version> <bundle_file> [--dry-run]
#
# Examples:
#   ./upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz
#   ./upload-gks-to-r2.sh 2026-06-14 v2_5_0 /tmp/clinvar-gks-2026-06-14.json.gz --dry-run

set -e

# --- Positional arguments ---
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <export_date> <dataset_version> <bundle_file> [--dry-run]"
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


# --- Derived date components ---
YEAR="${EXPORT_DATE:0:4}"
MM="${EXPORT_DATE:5:2}"
DD="${EXPORT_DATE:8:2}"
MMDD="${MM}${DD}"                # 0614

# --- Filenames ---
WEEKLY_FILE="clinvar-gks_${YEAR}-${MMDD}.json.gz"
LATEST_WEEKLY="clinvar-gks_00-latest_weekly.json.gz"
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

r2_ls_with_size() {
  # Returns "SIZE FILENAME" lines for .json.gz files under a prefix
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    2>/dev/null | awk '/\.json\.gz$/ {print $3, $4}' || true
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
    # Filename: clinvar-gks_2026-0607.json.gz
    local date_part="${first#clinvar-gks_}"   # 2026-0607.json.gz
    PREV_YEAR="${date_part:0:4}"              # 2026
    PREV_MONTH="${date_part:5:2}"             # 06

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
  # Weekly files are never archived — they stay in datasets/weekly/ indefinitely.
  # Note: LATEST_MONTHLY is retained; it gets overwritten by the new upload.
  echo "--- Year rollover: archiving ${PREV_YEAR} monthly files to archives/${PREV_YEAR}/ ---"

  local monthly_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && monthly_files+=("$f")
  done < <(r2_ls "datasets/clinvar-gks_" | grep -v "00-latest" || true)

  for f in "${monthly_files[@]}"; do
    echo "  Moving datasets/${f} -> archives/${PREV_YEAR}/${f}"
    r2_copy "datasets/${f}" "archives/${PREV_YEAR}/${f}"
    r2_rm "datasets/${f}"
  done
}

cleanup_prior_weeklies() {
  # Delete the prior month's weekly files from datasets/weekly/.
  # They are not archived — only monthly files are retained long-term.
  if [[ ${#EXISTING_WEEKLY_FILES[@]} -eq 0 ]]; then
    return
  fi
  echo "--- Month rollover: deleting prior month's weekly files ---"
  for f in "${EXISTING_WEEKLY_FILES[@]}"; do
    echo "  Deleting datasets/weekly/${f}"
    r2_rm "datasets/weekly/${f}"
  done
}

promote_monthly() {
  # Promote the last weekly from the prior month as that month's monthly release.
  # Must run before archive_yearly (so promoted monthly gets swept to archives on year rollover).
  if [[ ${#EXISTING_WEEKLY_FILES[@]} -eq 0 ]]; then
    echo "--- No prior weekly files to promote (first-ever upload) ---"
    return
  fi

  local last="${EXISTING_WEEKLY_FILES[-1]}"
  PREV_MONTHLY_FILE="clinvar-gks_${YEAR}-${MM}.json.gz"

  echo "--- Month rollover: promoting last prior weekly to monthly ---"
  echo "  Source:   datasets/weekly/${last}"
  echo "  Monthly:  datasets/${PREV_MONTHLY_FILE}"

  r2_copy "datasets/weekly/${last}" "datasets/${PREV_MONTHLY_FILE}"

  echo "  Updating datasets/${LATEST_MONTHLY}"
  r2_copy "datasets/weekly/${last}" "datasets/${LATEST_MONTHLY}"
}

# =====================================================================
# Main
# =====================================================================

echo "=== ClinVar-GKS Release Upload ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Version:       ${DATASET_VERSION}"
echo "  Weekly file:   ${WEEKLY_FILE}"
if $DRY_RUN; then
  echo "  Mode:          DRY RUN"
fi
echo ""

# --- Check bundle file ---
echo "Checking bundle: ${BUNDLE_FILE}"
if ! $DRY_RUN && [[ ! -f "${BUNDLE_FILE}" ]]; then
  echo "ERROR: Bundle file not found at ${BUNDLE_FILE}"
  echo "  Run export-gks-dicts.sh and assemble-gks-dicts.py first."
  exit 1
fi
LOCAL_TMP="${BUNDLE_FILE}"

# --- Detect month/year boundaries ---
echo ""
echo "Detecting release boundaries..."
detect_boundaries
echo "  New month: ${IS_NEW_MONTH}"
echo "  New year:  ${IS_NEW_YEAR}"
echo ""

# --- Month rollover: promote, archive (year only), delete prior weeklies ---
if $IS_NEW_MONTH; then
  promote_monthly
  echo ""

  if $IS_NEW_YEAR; then
    archive_yearly
    echo ""
  fi

  cleanup_prior_weeklies
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

# --- Generate and upload index.json ---
echo ""
echo "--- Generating index.json ---"
generate_index() {
  local index_tmp="/tmp/clinvar-gks-index.json"

  # Helper: build JSON array of file objects from "SIZE FILENAME" lines
  # Args: prefix (R2 path prefix like "datasets/" or "archives/2025/")
  #        latest_name (filename to mark with "latest": true, or "" for none)
  build_file_array() {
    local prefix="$1" latest_name="$2"
    local first=true
    local arr="["

    while IFS=' ' read -r size filename; do
      [[ -z "$filename" ]] && continue
      if ! $first; then arr+=","; fi
      first=false

      local is_latest="false"
      if [[ -n "$latest_name" && "$filename" == "$latest_name" ]]; then
        is_latest="true"
      fi

      arr+=$(printf '{"name":"%s","path":"%s%s","size":%s,"latest":%s}' \
        "$filename" "$prefix" "$filename" "$size" "$is_latest")
    done < <(r2_ls_with_size "$prefix")

    arr+="]"
    echo "$arr"
  }

  # Build datasets section
  local ds_monthly
  ds_monthly=$(build_file_array "datasets/" "${LATEST_MONTHLY}")
  local ds_weekly
  ds_weekly=$(build_file_array "datasets/weekly/" "${LATEST_WEEKLY}")

  # Build archives section — discover archive years
  local archives_json="{"
  local first_year=true
  while IFS= read -r year_dir; do
    year_dir="${year_dir%/}"
    [[ -z "$year_dir" ]] && continue

    if ! $first_year; then archives_json+=","; fi
    first_year=false

    local arch_monthly
    arch_monthly=$(build_file_array "archives/${year_dir}/")
    local arch_weekly
    arch_weekly=$(build_file_array "archives/${year_dir}/weekly/")

    archives_json+=$(printf '"%s":{"monthly":%s,"weekly":%s}' \
      "$year_dir" "$arch_monthly" "$arch_weekly")
  done < <(r2_ls "archives/" 2>/dev/null)
  archives_json+="}"

  cat > "$index_tmp" <<INDEXEOF
{
  "description": "ClinVar-GKS release index",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "base_url": "${R2_PUBLIC_URL}",
  "datasets": {
    "monthly": ${ds_monthly},
    "weekly": ${ds_weekly}
  },
  "archives": ${archives_json}
}
INDEXEOF

  r2_upload "$index_tmp" "index.json" "application/json"
  if ! $DRY_RUN; then
    rm -f "$index_tmp"
  fi
  echo "  index.json uploaded."
}

generate_index

# --- Summary ---
echo ""
echo "=== Upload Complete ==="
echo "  Weekly:  ${R2_PUBLIC_URL}/datasets/weekly/${WEEKLY_FILE}"
echo "  Latest:  ${R2_PUBLIC_URL}/datasets/weekly/${LATEST_WEEKLY}"
if $IS_NEW_MONTH && [[ -n "${PREV_MONTHLY_FILE:-}" ]]; then
  echo "  Monthly: ${R2_PUBLIC_URL}/datasets/${PREV_MONTHLY_FILE}"
  echo "  Latest:  ${R2_PUBLIC_URL}/datasets/${LATEST_MONTHLY}"
fi
echo "  Index:   ${R2_PUBLIC_URL}/index.json"
