#!/bin/bash
# export-gks-dicts.sh
# Export all GKS dictionary tables to GCS as NDJSON and/or Parquet
#
# Usage: ./export-gks-dicts.sh <dataset> <gcs_bucket> [prefix] [--parquet-only]
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clinvar-gks gks-dicts
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clinvar-gks gks-dicts --parquet-only

set -euo pipefail

# Parse positional args and flags
DATASET="${1:?Usage: $0 <dataset> <gcs_bucket> [prefix] [--parquet-only]}"
BUCKET="${2:?Usage: $0 <dataset> <gcs_bucket> [prefix] [--parquet-only]}"
PREFIX="${3:-gks-dicts}"
PARQUET_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --parquet-only) PARQUET_ONLY=true ;;
  esac
done

GCS_PATH="gs://${BUCKET}/${PREFIX}"
PARQUET_PREFIX="${PREFIX}-parquet"
GCS_PARQUET_PATH="gs://${BUCKET}/${PARQUET_PREFIX}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_DIR="${SCRIPT_DIR}/parquet-schemas"

echo "Exporting GKS dictionaries from ${DATASET}"

extract() {
  local table="$1"
  local basename="$2"
  # Use wildcard sharding to handle large tables
  # e.g., allele.ndjson.gz -> allele-*.ndjson.gz
  local sharded="${basename%.ndjson.gz}-*.ndjson.gz"
  echo "  Exporting ${table} -> ${sharded}"
  bq extract --destination_format NEWLINE_DELIMITED_JSON --compression GZIP \
    "${DATASET}.${table}" "${GCS_PATH}/${sharded}"
}

extract_parquet() {
  # Raw Parquet export via bq extract — for tables with no FK columns to clean.
  local table="$1"
  local basename="$2"
  local sharded="${basename%.parquet}-*.parquet"
  echo "  Exporting ${table} -> ${sharded} (Parquet)"
  bq extract --destination_format PARQUET --compression SNAPPY \
    "${DATASET}.${table}" "${GCS_PARQUET_PATH}/${sharded}"
}

extract_parquet_typed() {
  # Export via EXPORT DATA using a SQL schema file from parquet-schemas/.
  # Schema files define typed columns, FK cleanup, and data column.
  # The {DATASET} placeholder is substituted with the target dataset.
  local basename="$1"
  local sql_file="$2"
  local sharded="${basename%.parquet}-*.parquet"
  local schema_path="${SCHEMA_DIR}/${sql_file}"
  if [[ ! -f "${schema_path}" ]]; then
    echo "  ERROR: Schema file not found: ${schema_path}" >&2
    return 1
  fi
  local sql
  sql=$(<"${schema_path}")
  sql="${sql//\{DATASET\}/${DATASET}}"
  echo "  Exporting ${sql_file%.sql} -> ${sharded} (Parquet via EXPORT DATA)"
  bq query --use_legacy_sql=false --nouse_cache \
    "EXPORT DATA OPTIONS(
      uri='${GCS_PARQUET_PATH}/${sharded}',
      format='PARQUET',
      compression='SNAPPY',
      overwrite=true
    ) AS
    ${sql}"
}

if ! $PARQUET_ONLY; then
  echo "Exporting NDJSON files to ${GCS_PATH}"

  # Cat-VRS dictionaries (from gks_catvar_proc)
  extract gks_dict_sequence_reference sequenceReference.ndjson.gz
  extract gks_dict_location location.ndjson.gz
  extract gks_dict_allele allele.ndjson.gz
  extract gks_dict_copy_number_count copyNumberCount.ndjson.gz
  extract gks_dict_copy_number_change copyNumberChange.ndjson.gz
  extract gks_dict_gene gene.ndjson.gz
  extract gks_dict_variation variation.ndjson.gz

  # Condition dictionaries (from gks_scv_condition_proc)
  extract gks_dict_condition condition.ndjson.gz
  extract gks_dict_condition_set conditionSet.ndjson.gz

  # SCV dictionaries (from gks_scv_statement_proc)
  extract gks_dict_submitter submitter.ndjson.gz
  extract gks_dict_proposition proposition.ndjson.gz
  extract gks_dict_evidence_line evidenceLine.ndjson.gz

  # VCV/RCV proposition and evidence line dictionaries
  extract gks_dict_vcv_proposition vcv_proposition.ndjson.gz
  extract gks_dict_vcv_evidence_line vcv_evidenceLine.ndjson.gz
  extract gks_dict_rcv_proposition rcv_proposition.ndjson.gz
  extract gks_dict_rcv_evidence_line rcv_evidenceLine.ndjson.gz

  # Statement outputs
  extract gks_dict_scv scv.ndjson.gz
  extract gks_dict_vcv vcv.ndjson.gz
  extract gks_dict_rcv rcv.ndjson.gz
fi

echo ""
echo "Exporting Parquet files to ${GCS_PARQUET_PATH}"

# Cat-VRS (typed columns extracted from KV JSON values)
extract_parquet_typed sequenceReference.parquet sequenceReference.sql
extract_parquet_typed location.parquet location.sql
extract_parquet_typed allele.parquet allele.sql
extract_parquet_typed copyNumberCount.parquet copyNumberCount.sql
extract_parquet_typed copyNumberChange.parquet copyNumberChange.sql
extract_parquet_typed gene.parquet gene.sql
extract_parquet_typed variation.parquet variation.sql

# Conditions
extract_parquet gks_dict_condition condition.parquet
extract_parquet_typed conditionSet.parquet conditionSet.sql

# SCV
extract_parquet_typed submitter.parquet submitter.sql
extract_parquet_typed proposition.parquet proposition.sql
extract_parquet_typed evidenceLine.parquet evidenceLine.sql

# VCV/RCV
extract_parquet_typed vcv_proposition.parquet vcv_proposition.sql
extract_parquet_typed vcv_evidenceLine.parquet vcv_evidenceLine.sql
extract_parquet_typed rcv_proposition.parquet rcv_proposition.sql
extract_parquet_typed rcv_evidenceLine.parquet rcv_evidenceLine.sql

# Statements
extract_parquet_typed scv.parquet scv.sql
extract_parquet_typed vcv.parquet vcv.sql
extract_parquet_typed rcv.parquet rcv.sql

echo "Done."
if ! $PARQUET_ONLY; then
  echo "  NDJSON:  ${GCS_PATH}/"
fi
echo "  Parquet: ${GCS_PARQUET_PATH}/"
