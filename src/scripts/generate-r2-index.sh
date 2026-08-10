#!/bin/bash

# Regenerate index.json from the CURRENT Cloudflare R2 bucket state.
#
# Standalone generator called by BOTH uploaders (upload-gks-to-r2.sh and
# upload-gks-delta-to-r2.sh) so the published index is consistent regardless of
# which one ran last. Lists:
#   datasets.monthly — monthly full bundles in datasets/ (00-latest marked)
#   archives         — prior-year monthly files under archives/{yyyy}/
#   deltas           — per-release delta dirs under deltas/ (00-latest marked)
#
# Usage:
#   ./generate-r2-index.sh [--dry-run]

set -e

# --- Parse flags ---
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      echo "Usage: $0 [--dry-run]"
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

LATEST_MONTHLY="clinvar-gks_00-latest.json.gz"

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
  # Returns "SIZE FILENAME" lines for .json.gz files under a prefix
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    2>/dev/null | awk '/\.json\.gz$/ {print $3, $4}' || true
}

# Build a JSON array of file objects from "SIZE FILENAME" lines under a prefix.
# Args: prefix (R2 path like "datasets/" or "archives/2025/")
#       latest_name (filename to mark "latest": true, or "" for none)
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

# Build the deltas JSON array — one object per release dir under deltas/.
# Each entry: {release, path, manifest, latest}. deltas/00-latest is marked latest.
build_deltas_array() {
  local first=true
  local arr="["

  while IFS= read -r dir; do
    dir="${dir%/}"
    [[ -z "$dir" ]] && continue

    if ! $first; then arr+=","; fi
    first=false

    local release path is_latest
    if [[ "$dir" == "00-latest" ]]; then
      release="latest"
      is_latest="true"
    else
      # Dir name is YYYY-MMDD -> release date YYYY-MM-DD
      release="${dir:0:4}-${dir:5:2}-${dir:7:2}"
      is_latest="false"
    fi
    path="deltas/${dir}/"

    arr+=$(printf '{"release":"%s","path":"%s","manifest":"%smanifest.json","latest":%s}' \
      "$release" "$path" "$path" "$is_latest")
  done < <(r2_ls "deltas/" 2>/dev/null)

  arr+="]"
  echo "$arr"
}

# =====================================================================
# Main
# =====================================================================

echo "--- Generating index.json ---"

INDEX_TMP="/tmp/clinvar-gks-index.json"

# datasets.monthly (weekly section dropped — full is month-end only now)
DS_MONTHLY=$(build_file_array "datasets/" "${LATEST_MONTHLY}")

# archives — per-year discovery
ARCHIVES_JSON="{"
FIRST_YEAR=true
while IFS= read -r year_dir; do
  year_dir="${year_dir%/}"
  [[ -z "$year_dir" ]] && continue

  if ! $FIRST_YEAR; then ARCHIVES_JSON+=","; fi
  FIRST_YEAR=false

  ARCH_MONTHLY=$(build_file_array "archives/${year_dir}/")
  ARCHIVES_JSON+=$(printf '"%s":{"monthly":%s}' "$year_dir" "$ARCH_MONTHLY")
done < <(r2_ls "archives/" 2>/dev/null)
ARCHIVES_JSON+="}"

# deltas — per-release dirs
DELTAS_JSON=$(build_deltas_array)

cat > "$INDEX_TMP" <<INDEXEOF
{
  "description": "ClinVar-GKS release index",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "base_url": "${R2_PUBLIC_URL}",
  "datasets": {
    "monthly": ${DS_MONTHLY}
  },
  "archives": ${ARCHIVES_JSON},
  "deltas": ${DELTAS_JSON}
}
INDEXEOF

r2_upload "$INDEX_TMP" "index.json" "application/json"
if ! $DRY_RUN; then
  rm -f "$INDEX_TMP"
fi
echo "  index.json uploaded."
