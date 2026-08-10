#!/bin/bash
# Release the per-release GKS DELTA: export delta_<dict> tables, assemble a delta
# bundle, merge delta Parquet, build manifest.json, upload the delta tree to R2.
#
# Usage: ./release-gks-delta.sh <export_date> <dataset_version> [--start-step=N] [--dry-run]
set -e
[[ $# -lt 2 ]] && { echo "Usage: $0 <export_date> <dataset_version> [--start-step=N] [--dry-run]"; exit 1; }
EXPORT_DATE="$1"; DATASET_VERSION="$2"; shift 2
[[ "$EXPORT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR: bad date '${EXPORT_DATE}'"; exit 1; }

DRY_RUN=false; START_STEP=1
for arg in "$@"; do case "$arg" in
  --dry-run) DRY_RUN=true ;;
  --start-step=*) START_STEP="${arg#--start-step=}" ;;
  *) echo "ERROR: unknown arg '${arg}'"; exit 1 ;;
esac; done

GCS_BUCKET="clinvar-gks"
GCS_DELTAS_PREFIX="gks-deltas"
GCS_DELTAS_PATH="gs://${GCS_BUCKET}/${GCS_DELTAS_PREFIX}"
GCS_DELTAS_PARQUET_PATH="gs://${GCS_BUCKET}/${GCS_DELTAS_PREFIX}-parquet"
DATE_US="${EXPORT_DATE//-/_}"
BQ_DATASET="clinvar_${DATE_US}_${DATASET_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON="python3"; [[ -x "${PROJECT_ROOT}/venv/3.12/bin/python3" ]] && PYTHON="${PROJECT_ROOT}/venv/3.12/bin/python3"

DELTA_BUNDLE="/tmp/clinvar-gks-delta-${EXPORT_DATE}.json.gz"
DELTA_PARQUET_DIR="/tmp/clinvar-gks-delta-${EXPORT_DATE}-parquet"
MANIFEST_FILE="/tmp/clinvar-gks-delta-${EXPORT_DATE}-manifest.json"

echo "=== ClinVar-GKS DELTA release ${EXPORT_DATE} (dataset ${BQ_DATASET}) ==="
$DRY_RUN && echo "  Mode: DRY RUN"

# Step 1: export delta tables -> GCS
if (( START_STEP <= 1 )); then
  echo "=== [1/4] export delta tables ==="
  if $DRY_RUN; then
    echo "  [dry-run] export-gks-dicts.sh ${BQ_DATASET} ${GCS_BUCKET} ${GCS_DELTAS_PREFIX} --delta"
  else
    gsutil -m -q rm -r "${GCS_DELTAS_PATH}/" 2>/dev/null || true
    gsutil -m -q rm -r "${GCS_DELTAS_PARQUET_PATH}/" 2>/dev/null || true
    "${SCRIPT_DIR}/export-gks-dicts.sh" "${BQ_DATASET}" "${GCS_BUCKET}" "${GCS_DELTAS_PREFIX}" --delta
  fi
fi

# Step 2: assemble delta NDJSON -> delta bundle (with cleanup)
if (( START_STEP <= 2 )); then
  echo "=== [2/4] assemble delta bundle ==="
  if $DRY_RUN; then
    echo "  [dry-run] assemble-gks-dicts.py ${GCS_DELTAS_PATH}/ ${EXPORT_DATE} --delta-name"
  else
    "${PYTHON}" "${SCRIPT_DIR}/assemble-gks-dicts.py" "${GCS_DELTAS_PATH}/" "${EXPORT_DATE}" --output "${DELTA_BUNDLE}"
  fi
fi

# Step 3: download + merge delta Parquet shards -> per-section parquet
if (( START_STEP <= 3 )); then
  echo "=== [3/4] merge delta Parquet ==="
  if $DRY_RUN; then
    echo "  [dry-run] download+merge ${GCS_DELTAS_PARQUET_PATH}/ -> ${DELTA_PARQUET_DIR}/"
  else
    mkdir -p "${DELTA_PARQUET_DIR}"; SH="${DELTA_PARQUET_DIR}/_gcs"; mkdir -p "${SH}"
    gsutil -m cp "${GCS_DELTAS_PARQUET_PATH}/*.parquet" "${SH}/" 2>/dev/null || echo "  (no delta parquet shards)"
    for first in "${SH}"/*-000000000000.parquet; do
      [ -f "$first" ] || continue
      base="$(basename "$first" | sed 's/-000000000000\.parquet//')"
      duckdb -c "COPY (SELECT * FROM read_parquet('${SH}/${base}-*.parquet')) TO '${DELTA_PARQUET_DIR}/${base}.parquet' (FORMAT PARQUET, COMPRESSION SNAPPY);"
    done
    rm -rf "${SH}"
  fi
fi

# Step 4: build manifest + upload delta tree (upload wired in Chunk 4)
if (( START_STEP <= 4 )); then
  echo "=== [4/4] manifest + upload ==="
  MANIFEST_ARGS=("${EXPORT_DATE}" "${DATASET_VERSION}" "${MANIFEST_FILE}")
  if $DRY_RUN; then
    echo "  [dry-run] build-delta-manifest.py ${MANIFEST_ARGS[*]}"
  else
    "${PYTHON}" "${SCRIPT_DIR}/build-delta-manifest.py" "${MANIFEST_ARGS[@]}"
  fi
  UPLOAD_ARGS=("${EXPORT_DATE}" "${DELTA_BUNDLE}" "${MANIFEST_FILE}" "--parquet-dir=${DELTA_PARQUET_DIR}")
  $DRY_RUN && UPLOAD_ARGS+=("--dry-run")
  "${SCRIPT_DIR}/upload-gks-delta-to-r2.sh" "${UPLOAD_ARGS[@]}"
fi

if ! $DRY_RUN; then rm -f "${DELTA_BUNDLE}" "${MANIFEST_FILE}"; rm -rf "${DELTA_PARQUET_DIR}"; fi
echo "=== DELTA release ${EXPORT_DATE} complete ==="
