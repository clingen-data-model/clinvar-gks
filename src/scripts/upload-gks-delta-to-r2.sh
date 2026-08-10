#!/bin/bash

# Upload a ClinVar-GKS DELTA tree (bundle + manifest + Parquet) to Cloudflare R2.
# Runs after release-gks-delta.sh has produced the delta bundle, manifest.json,
# and merged per-section delta Parquet.
#
# R2 layout written:
#   deltas/<YYYY-MMDD>/clinvar-gks-delta_<YYYY-MMDD>.json.gz   — the delta bundle
#   deltas/<YYYY-MMDD>/manifest.json                          — per-release manifest
#   deltas/<YYYY-MMDD>/parquet/<section>.parquet              — per-section delta Parquet
#   deltas/00-latest/{clinvar-gks-delta_00-latest.json.gz, manifest.json, parquet/*}
#
# Before upload it resolves manifest.checkpoint_full = the newest monthly FULL
# currently in datasets/ (clinvar-gks_YYYY-MM.json.gz), so a consumer knows which
# full bundle this delta chain replays onto. Then regenerates index.json.
#
# Usage:
#   ./upload-gks-delta-to-r2.sh <export_date> <delta_bundle> <manifest_file> [--parquet-dir=DIR] [--dry-run]

set -e

# --- Positional arguments ---
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <export_date> <delta_bundle> <manifest_file> [--parquet-dir=DIR] [--dry-run]"
  echo "  export_date    ClinVar release date (YYYY-MM-DD)"
  echo "  delta_bundle   Local path to the assembled delta bundle (.json.gz)"
  echo "  manifest_file  Local path to manifest.json"
  exit 1
fi

EXPORT_DATE="$1"
DELTA_BUNDLE="$2"
MANIFEST_FILE="$3"
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
      echo "Usage: $0 <export_date> <delta_bundle> <manifest_file> [--parquet-dir=DIR] [--dry-run]"
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
MMDD="${MM}${DD}"                    # 0706
PREFIX="deltas/${YEAR}-${MMDD}"     # deltas/2026-0706
LATEST_PREFIX="deltas/00-latest"

DELTA_NAME="clinvar-gks-delta_${YEAR}-${MMDD}.json.gz"
LATEST_DELTA_NAME="clinvar-gks-delta_00-latest.json.gz"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =====================================================================
# Helper functions (shared with upload-gks-to-r2.sh)
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

# =====================================================================
# Main
# =====================================================================

echo "=== ClinVar-GKS DELTA Upload ==="
echo "  Release date:  ${EXPORT_DATE}"
echo "  Delta prefix:  ${PREFIX}/"
echo "  Delta bundle:  ${DELTA_NAME}"
$DRY_RUN && echo "  Mode:          DRY RUN"
echo ""

# --- Check local artifacts (skip strict checks in dry-run — orchestrator does not
#     produce them when dry-running the earlier steps) ---
if ! $DRY_RUN; then
  if [[ ! -f "${DELTA_BUNDLE}" ]]; then
    echo "ERROR: delta bundle not found at ${DELTA_BUNDLE}"; exit 1
  fi
  if [[ ! -f "${MANIFEST_FILE}" ]]; then
    echo "ERROR: manifest not found at ${MANIFEST_FILE}"; exit 1
  fi
fi

# --- (a) Resolve checkpoint_full from current R2 monthly state ------------------------
echo "--- Resolving checkpoint_full (newest monthly FULL in datasets/) ---"
CHECKPOINT_FILE=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Keep only clinvar-gks_YYYY-MM.json.gz (monthly full); exclude 00-latest + weekly.
  [[ "$f" == *"00-latest"* ]] && continue
  [[ "$f" =~ ^clinvar-gks_[0-9]{4}-[0-9]{2}\.json\.gz$ ]] || continue
  # lexically-last wins (YYYY-MM sorts chronologically)
  if [[ -z "$CHECKPOINT_FILE" || "$f" > "$CHECKPOINT_FILE" ]]; then
    CHECKPOINT_FILE="$f"
  fi
done < <(r2_ls "datasets/clinvar-gks_")

if [[ -n "$CHECKPOINT_FILE" ]]; then
  CHECKPOINT_PATH="datasets/${CHECKPOINT_FILE}"
  CHECKPOINT_RELEASE="${CHECKPOINT_FILE#clinvar-gks_}"   # 2026-06.json.gz
  CHECKPOINT_RELEASE="${CHECKPOINT_RELEASE%.json.gz}"     # 2026-06
  echo "  checkpoint_full = ${CHECKPOINT_PATH} (release ${CHECKPOINT_RELEASE})"
  if $DRY_RUN; then
    echo "  [dry-run] would patch manifest.checkpoint_full = {path, release}"
  else
    "${PYTHON:-python3}" -c '
import json, sys
path, cp_path, cp_rel = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    d = json.load(fh)
d["checkpoint_full"] = {"path": cp_path, "release": cp_rel}
with open(path, "w") as fh:
    json.dump(d, fh, indent=2)
' "${MANIFEST_FILE}" "${CHECKPOINT_PATH}" "${CHECKPOINT_RELEASE}"
    echo "  patched manifest.checkpoint_full"
  fi
else
  echo "  WARNING: no monthly FULL found in datasets/ — checkpoint_full stays null"
  echo "           (expected on the initial rollout; the first delta bootstraps from itself)"
fi
echo ""

# --- (b) Upload the delta tree --------------------------------------------------------
echo "--- Uploading delta tree to ${PREFIX}/ ---"
r2_upload "${DELTA_BUNDLE}" "${PREFIX}/${DELTA_NAME}"
r2_upload "${MANIFEST_FILE}" "${PREFIX}/manifest.json" "application/json"

PARQUET_SECTIONS=()
if [[ -n "${PARQUET_DIR}" && -d "${PARQUET_DIR}" ]]; then
  for parquet_file in "${PARQUET_DIR}"/*.parquet; do
    [[ -f "$parquet_file" ]] || continue
    section="$(basename "${parquet_file}" .parquet)"
    PARQUET_SECTIONS+=("$section")
    r2_upload "${parquet_file}" "${PREFIX}/parquet/${section}.parquet" \
      "application/vnd.apache.parquet"
  done
  echo "  ${#PARQUET_SECTIONS[@]} Parquet sections uploaded."
elif $DRY_RUN; then
  echo "  [dry-run] (no local Parquet dir; would upload ${PREFIX}/parquet/<section>.parquet)"
else
  echo "  (no Parquet dir found, skipping)"
fi
echo ""

# --- (c) Refresh deltas/00-latest/ (server-side copy of the three artifact kinds) -----
echo "--- Refreshing ${LATEST_PREFIX}/ ---"
r2_copy "${PREFIX}/${DELTA_NAME}" "${LATEST_PREFIX}/${LATEST_DELTA_NAME}"
r2_copy "${PREFIX}/manifest.json" "${LATEST_PREFIX}/manifest.json"
if [[ ${#PARQUET_SECTIONS[@]} -gt 0 ]]; then
  for section in "${PARQUET_SECTIONS[@]}"; do
    r2_copy "${PREFIX}/parquet/${section}.parquet" "${LATEST_PREFIX}/parquet/${section}.parquet"
  done
elif $DRY_RUN; then
  echo "  [dry-run] (would copy ${PREFIX}/parquet/<section>.parquet -> ${LATEST_PREFIX}/parquet/)"
fi
echo ""

# --- (d) Regenerate index.json --------------------------------------------------------
INDEX_ARGS=()
$DRY_RUN && INDEX_ARGS+=("--dry-run")
"${SCRIPT_DIR}/generate-r2-index.sh" "${INDEX_ARGS[@]}"

# --- Summary --------------------------------------------------------------------------
echo ""
echo "=== Delta Upload Complete ==="
echo "  Delta:   ${R2_PUBLIC_URL}/${PREFIX}/${DELTA_NAME}"
echo "  Manifest:${R2_PUBLIC_URL}/${PREFIX}/manifest.json"
echo "  Latest:  ${R2_PUBLIC_URL}/${LATEST_PREFIX}/${LATEST_DELTA_NAME}"
echo "  Index:   ${R2_PUBLIC_URL}/index.json"
