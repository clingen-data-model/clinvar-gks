#!/bin/bash

# Backfill a historical monthly ClinVar-GKS release to Cloudflare R2.
#
# Use this script to upload past monthly releases that were not captured
# by the normal pipeline. It uploads directly to the monthly destination
# without touching datasets/weekly/ or the 00-latest pointer.
#
# Destination is derived from the export year vs. the current calendar year:
#   Current year:  datasets/clinvar-gks_{YYYY}-{MM}.json.gz
#   Prior year:    archives/{YYYY}/clinvar-gks_{YYYY}-{MM}.json.gz
#
# The 00-latest pointer is NOT updated — this is a backfill, not the
# most recent release. Run the normal upload-gks-to-r2.sh for current releases.
#
# Usage:
#   ./backfill-monthly-to-r2.sh <export_date> <dataset_version> <bundle_file> [--dry-run]
#
# Examples:
#   ./backfill-monthly-to-r2.sh 2026-03-29 v2_5_0 /tmp/clinvar-gks-2026-03-29.json.gz
#   ./backfill-monthly-to-r2.sh 2025-11-28 v2_4_0 /tmp/clinvar-gks-2025-11-28.json.gz --dry-run

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
LATEST_MONTHLY="clinvar-gks_00-latest.json.gz"
LATEST_WEEKLY="clinvar-gks_00-latest_weekly.json.gz"

# --- Destination ---
if [[ "$YEAR" == "$CURRENT_YEAR" ]]; then
  DEST="datasets/${MONTHLY_FILE}"
else
  DEST="archives/${YEAR}/${MONTHLY_FILE}"
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

# --- Generate and upload index.json ---
echo "--- Generating index.json ---"
generate_index() {
  local index_tmp="/tmp/clinvar-gks-index.json"

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

  local ds_monthly
  ds_monthly=$(build_file_array "datasets/" "${LATEST_MONTHLY}")
  local ds_weekly
  ds_weekly=$(build_file_array "datasets/weekly/" "${LATEST_WEEKLY}")

  local archives_json="{"
  local first_year=true
  while IFS= read -r year_dir; do
    year_dir="${year_dir%/}"
    [[ -z "$year_dir" ]] && continue

    if ! $first_year; then archives_json+=","; fi
    first_year=false

    local arch_monthly
    arch_monthly=$(build_file_array "archives/${year_dir}/")

    archives_json+=$(printf '"%s":{"monthly":%s}' "$year_dir" "$arch_monthly")
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
echo "=== Backfill Complete ==="
echo "  Monthly: ${R2_PUBLIC_URL}/${DEST}"
echo "  Index:   ${R2_PUBLIC_URL}/index.json"
