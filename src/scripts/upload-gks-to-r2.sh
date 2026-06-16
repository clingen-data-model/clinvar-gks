#!/bin/bash

# Upload ClinVar-GKS bundle file from GCS to Cloudflare R2.
# Runs after export-gks-dicts.sh and assemble-gks-dicts.py have produced the bundle.
#
# Usage:
#   ./upload-gks-to-r2.sh                     # Upload current release
#   ./upload-gks-to-r2.sh --dry-run           # Show what would be uploaded
#   ./upload-gks-to-r2.sh --skip-current      # Only upload to dated archive
#
# Environment:
#   Requires AWS CLI configured with an R2 profile.
#   Set EXPORT_DATE and DATASET_VERSION below for each release.

set -e

# --- R2 Configuration ---
R2_ACCOUNT_ID="09208aa33790838db213a21f630c33e7"
R2_BUCKET="clinvar-gks"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
R2_PROFILE="r2"

# --- GCS Source Configuration ---
GCS_PUBLIC_BUCKET="clingen-public/clinvar-gks"

# --- Export Configuration: Change these for each release ---
EXPORT_DATE="2026-05-10"
DATASET_VERSION="v2_5_0"

# --- Derived values ---
YEAR="${EXPORT_DATE:0:4}"
MONTH="${EXPORT_DATE:0:7}"
ARCHIVE_PATH="${YEAR}/${MONTH}/${EXPORT_DATE}"

# --- Bundle filename ---
BUNDLE_FILENAME="clinvar-gks-${EXPORT_DATE}.json.gz"
CURRENT_FILENAME="clinvar-gks-current.json.gz"

# --- Parse flags ---
DRY_RUN=false
SKIP_CURRENT=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=true ;;
    --skip-current) SKIP_CURRENT=true ;;
    *)
      echo "ERROR: Unknown argument '${arg}'"
      echo "Usage: $0 [--dry-run] [--skip-current]"
      exit 1
      ;;
  esac
done

# --- Helper functions ---
r2_upload() {
  local src="$1" dest="$2" content_type="${3:-application/gzip}"
  if $DRY_RUN; then
    echo "  [dry-run] Would upload: ${dest}"
    return
  fi
  aws s3 cp "$src" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --profile "${R2_PROFILE}" \
    --content-type "${content_type}" \
    --quiet
}

generate_manifest() {
  local manifest_path="$1"
  cat > "$manifest_path" <<MANIFEST
{
  "release_date": "${EXPORT_DATE}",
  "schema_version": "${DATASET_VERSION}",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "format": "bundle",
  "files": ["${BUNDLE_FILENAME}"]
}
MANIFEST
}

# --- Main ---
echo "=== ClinVar-GKS Release Upload ==="
echo "  Release:  ${EXPORT_DATE} (${DATASET_VERSION})"
echo "  Bundle:   ${BUNDLE_FILENAME}"
echo ""

# Check if bundle file exists in GCS
GCS_URI="gs://${GCS_PUBLIC_BUCKET}/${EXPORT_DATE}/release/${BUNDLE_FILENAME}"
echo "Checking GCS: ${GCS_URI}"
if ! gsutil -q stat "${GCS_URI}" 2>/dev/null; then
  # Try alternate path without release/ subdirectory
  GCS_URI="gs://${GCS_PUBLIC_BUCKET}/${BUNDLE_FILENAME}"
  if ! gsutil -q stat "${GCS_URI}" 2>/dev/null; then
    echo "ERROR: Bundle file not found in GCS."
    echo "  Tried: gs://${GCS_PUBLIC_BUCKET}/${EXPORT_DATE}/release/${BUNDLE_FILENAME}"
    echo "  Tried: gs://${GCS_PUBLIC_BUCKET}/${BUNDLE_FILENAME}"
    echo ""
    echo "  Run export-gks-dicts.sh and assemble-gks-dicts.py first."
    exit 1
  fi
fi

# Download from GCS
LOCAL_TMP="/tmp/${BUNDLE_FILENAME}"
echo "Downloading bundle from GCS..."
if ! $DRY_RUN; then
  gsutil -o "GSUtil:check_hashes=never" -q cp "${GCS_URI}" "${LOCAL_TMP}"
fi

# Upload to dated archive
echo "Uploading to archive: ${ARCHIVE_PATH}/${BUNDLE_FILENAME}"
r2_upload "${LOCAL_TMP}" "${ARCHIVE_PATH}/${BUNDLE_FILENAME}"

# Upload to current/ with stable filename
if ! $SKIP_CURRENT; then
  echo "Uploading to current: current/${CURRENT_FILENAME}"
  r2_upload "${LOCAL_TMP}" "current/${CURRENT_FILENAME}"

  # Also upload with dated name to current/ for weekly browsing
  echo "Uploading to current: current/${BUNDLE_FILENAME}"
  r2_upload "${LOCAL_TMP}" "current/${BUNDLE_FILENAME}"
fi

# Generate and upload manifest
MANIFEST_TMP="/tmp/manifest_${EXPORT_DATE}.json"
generate_manifest "${MANIFEST_TMP}"

echo "Uploading archive manifest..."
r2_upload "${MANIFEST_TMP}" "${ARCHIVE_PATH}/manifest.json" "application/json"

if ! $SKIP_CURRENT; then
  echo "Updating current/ manifest..."
  r2_upload "${MANIFEST_TMP}" "current/manifest.json" "application/json"
fi

# Cleanup
if ! $DRY_RUN; then
  rm -f "${LOCAL_TMP}" "${MANIFEST_TMP}"
fi

echo ""
echo "=== Upload Complete ==="
echo "  Archive: https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/${ARCHIVE_PATH}/${BUNDLE_FILENAME}"
if ! $SKIP_CURRENT; then
  echo "  Current: https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/${CURRENT_FILENAME}"
fi
