#!/bin/bash

# Upload ClinVar-GKS files from GCS public bucket to Cloudflare R2.
# Runs after export-gks-files-to-gcs.sh has published files to GCS.
#
# Usage:
#   ./upload-gks-to-r2.sh                    # Upload all 3 file types
#   ./upload-gks-to-r2.sh variation           # Upload only variation
#   ./upload-gks-to-r2.sh scv_by_ref scv_inline  # Upload specific types
#
# Modes:
#   --dry-run     Show what would be uploaded without uploading
#   --skip-current  Only upload to the dated archive, not current/
#   --backfill    Upload all historical files from GCS (ignores EXPORT_DATE)

set -e

# --- R2 Configuration ---
R2_ACCOUNT_ID="09208aa33790838db213a21f630c33e7"
R2_BUCKET="clinvar-gks"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
R2_PROFILE="r2"

# --- GCS Source Configuration ---
GCS_PUBLIC_BUCKET="clingen-public/clinvar-gks"

# --- Export Configuration: Change these for each release ---
EXPORT_DATE="2026-03-15"
DATASET_VERSION="v2_4_3"

# --- Derived values ---
DATE_SUFFIX="${EXPORT_DATE//-/_}"
YEAR="${EXPORT_DATE:0:4}"
MONTH="${EXPORT_DATE:0:7}"

# --- All output types ---
ALL_OUTPUT_NAMES=("variation" "scv_by_ref" "scv_inline" "vcv" "rcv")

# --- Parse flags and arguments ---
DRY_RUN=false
SKIP_CURRENT=false
BACKFILL=false
SELECTED_OUTPUTS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --skip-current) SKIP_CURRENT=true ;;
    --backfill)    BACKFILL=true ;;
    *)             SELECTED_OUTPUTS+=("$arg") ;;
  esac
done

# Default to all outputs if none specified
if [ ${#SELECTED_OUTPUTS[@]} -eq 0 ]; then
  SELECTED_OUTPUTS=("${ALL_OUTPUT_NAMES[@]}")
fi

# Validate output names
for name in "${SELECTED_OUTPUTS[@]}"; do
  valid=false
  for valid_name in "${ALL_OUTPUT_NAMES[@]}"; do
    if [[ "$name" == "$valid_name" ]]; then valid=true; break; fi
  done
  if ! $valid; then
    echo "ERROR: Unknown output type '${name}'. Valid types: ${ALL_OUTPUT_NAMES[*]}"
    exit 1
  fi
done

# --- Helper functions ---
r2_upload() {
  local src="$1" dest="$2"
  if $DRY_RUN; then
    echo "  [dry-run] Would upload: ${dest}"
    return
  fi
  aws s3 cp "$src" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --content-type "application/gzip" \
    --quiet
}

r2_upload_json() {
  local src="$1" dest="$2"
  if $DRY_RUN; then
    echo "  [dry-run] Would upload: ${dest}"
    return
  fi
  aws s3 cp "$src" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --content-type "application/json" \
    --quiet
}

generate_manifest() {
  local release_date="$1" version="$2" manifest_path="$3"
  shift 3
  local files=("$@")

  local files_json=""
  for f in "${files[@]}"; do
    if [ -n "$files_json" ]; then files_json+=","; fi
    files_json+="\"${f}\""
  done

  cat > "$manifest_path" <<MANIFEST
{
  "release_date": "${release_date}",
  "schema_version": "${version}",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "files": [${files_json}]
}
MANIFEST
}

# Build index.json from all manifests currently in R2.
# Lists every release by scanning for manifest.json files in the archive paths.
update_root_index() {
  echo "Updating root index.json..."
  local index_tmp="/tmp/r2_index.json"

  # List all manifest.json files in the bucket (excluding current/)
  local manifests
  manifests=$(aws s3 ls "s3://${R2_BUCKET}/" --recursive --endpoint-url "${R2_ENDPOINT}" --profile "${R2_PROFILE}" \
    | grep 'manifest.json' | grep -v 'current/' | awk '{print $4}' | sort)

  if [ -z "$manifests" ]; then
    echo "  No release manifests found in R2."
    return
  fi

  # Build releases array by downloading each manifest
  local releases_json="["
  local first=true
  while read -r manifest_key; do
    # Extract path components: YYYY/YYYY-MM/YYYY-MM-DD/manifest.json
    local release_path
    release_path=$(dirname "$manifest_key")
    local release_date
    release_date=$(basename "$release_path")

    # Fetch the manifest to get version and file list
    local manifest_content
    manifest_content=$(aws s3 cp "s3://${R2_BUCKET}/${manifest_key}" - \
      --endpoint-url "${R2_ENDPOINT}" --profile "${R2_PROFILE}" 2>/dev/null)

    local version
    version=$(echo "$manifest_content" | python3 -c "import sys,json; print(json.load(sys.stdin)['schema_version'])" 2>/dev/null || echo "unknown")

    local files_array
    files_array=$(echo "$manifest_content" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['files']))" 2>/dev/null || echo "[]")

    if ! $first; then releases_json+=","; fi
    first=false
    releases_json+=$(printf '\n    {"date": "%s", "version": "%s", "path": "%s/", "files": %s}' \
      "$release_date" "$version" "$release_path" "$files_array")
  done <<< "$manifests"

  releases_json+=$'\n  ]'

  cat > "$index_tmp" <<INDEX
{
  "description": "ClinVar-GKS weekly data releases",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "base_url": "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev",
  "releases": ${releases_json}
}
INDEX

  r2_upload_json "$index_tmp" "index.json"
  rm -f "$index_tmp"
  echo "  Root index.json updated."
}

upload_single_release() {
  local export_date="$1" dataset_version="$2"
  local date_suffix="${export_date//-/_}"
  local year="${export_date:0:4}"
  local month="${export_date:0:7}"
  local archive_path="${year}/${month}/${export_date}"
  local uploaded_files=()
  local has_error=false

  echo "=== Release: ${export_date} (${dataset_version}) ==="

  for name in "${SELECTED_OUTPUTS[@]}"; do
    local filename="clinvar_gks_${name}_${date_suffix}_${dataset_version}.jsonl.gz"
    local gcs_uri="gs://${GCS_PUBLIC_BUCKET}/${filename}"
    local local_tmp="/tmp/${filename}"

    # Check if file exists in GCS
    if ! gsutil -q stat "${gcs_uri}" 2>/dev/null; then
      echo "  SKIP: ${filename} (not found in GCS)"
      continue
    fi

    echo "  Downloading ${name}..."
    if ! $DRY_RUN; then
      gsutil -o "GSUtil:check_hashes=never" -q cp "${gcs_uri}" "${local_tmp}"
    fi

    # Upload to dated archive
    echo "  Uploading ${name} to archive..."
    r2_upload "${local_tmp}" "${archive_path}/${filename}"

    # Upload to current/ (latest, stable URL)
    if ! $SKIP_CURRENT; then
      echo "  Uploading ${name} to current/..."
      r2_upload "${local_tmp}" "current/clinvar_gks_${name}.jsonl.gz"
    fi

    uploaded_files+=("${filename}")

    # Clean up temp file
    if ! $DRY_RUN; then
      rm -f "${local_tmp}"
    fi

    echo "  Done: ${name}"
  done

  # Generate and upload manifest for the dated archive
  if [ ${#uploaded_files[@]} -gt 0 ]; then
    local manifest_tmp="/tmp/manifest_${export_date}.json"
    generate_manifest "${export_date}" "${dataset_version}" "${manifest_tmp}" "${uploaded_files[@]}"

    echo "  Uploading archive manifest..."
    r2_upload_json "${manifest_tmp}" "${archive_path}/manifest.json"

    # Update current/ manifest (only if we uploaded to current/)
    if ! $SKIP_CURRENT; then
      echo "  Updating current/ manifest..."
      r2_upload_json "${manifest_tmp}" "current/manifest.json"
    fi

    if ! $DRY_RUN; then
      rm -f "${manifest_tmp}"
    fi
  fi

  echo "=== Done: ${export_date} ==="
  echo ""
}

# --- Backfill mode: discover and upload all releases from GCS ---
if $BACKFILL; then
  echo "Discovering releases in gs://${GCS_PUBLIC_BUCKET}/..."
  # Extract unique release dates from GCS filenames
  release_dates=$(gsutil ls "gs://${GCS_PUBLIC_BUCKET}/" | \
    sed -n 's|.*clinvar_gks_variation_\([0-9_]*\)_v\(.*\)\.jsonl\.gz|\1 v\2|p' | \
    sort -u)

  if [ -z "$release_dates" ]; then
    echo "No releases found in GCS."
    exit 0
  fi

  echo "Found releases:"
  echo "$release_dates" | while read -r date_part version; do
    echo "  ${date_part//_/-} (${version})"
  done
  echo ""

  # Process each release (oldest first, so current/ ends up with the newest)
  echo "$release_dates" | while read -r date_part version; do
    export_date="${date_part//_/-}"
    upload_single_release "$export_date" "$version"
  done

  update_root_index
  echo "Backfill complete."
  exit 0
fi

# --- Normal mode: upload a single release ---
upload_single_release "$EXPORT_DATE" "$DATASET_VERSION"
update_root_index

echo "Upload complete."
echo "  Archive: s3://${R2_BUCKET}/${YEAR}/${MONTH}/${EXPORT_DATE}/"
if ! $SKIP_CURRENT; then
  echo "  Current: s3://${R2_BUCKET}/current/"
fi
echo "  Public:  https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/"
