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
  local table="$1"
  local basename="$2"
  echo "  Exporting ${table} -> ${basename} (Parquet)"
  bq extract --destination_format PARQUET --compression SNAPPY \
    "${DATASET}.${table}" "${GCS_PARQUET_PATH}/${basename}"
}

extract_parquet_kv() {
  # KV tables have a JSON-typed `value` column that bq extract cannot handle.
  # Use EXPORT DATA with TO_JSON_STRING to cast it to STRING.
  local table="$1"
  local basename="$2"
  local sharded="${basename%.parquet}-*.parquet"
  echo "  Exporting ${table} -> ${sharded} (Parquet via EXPORT DATA)"
  bq query --use_legacy_sql=false --nouse_cache \
    "EXPORT DATA OPTIONS(
      uri='${GCS_PARQUET_PATH}/${sharded}',
      format='PARQUET',
      compression='SNAPPY',
      overwrite=true
    ) AS
    SELECT key, TO_JSON_STRING(value) AS value
    FROM \`${DATASET}.${table}\`"
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

# Cat-VRS (KV tables — JSON value column requires EXPORT DATA)
extract_parquet_kv gks_dict_sequence_reference sequenceReference.parquet
extract_parquet_kv gks_dict_location location.parquet
extract_parquet_kv gks_dict_allele allele.parquet
extract_parquet_kv gks_dict_copy_number_count copyNumberCount.parquet
extract_parquet_kv gks_dict_copy_number_change copyNumberChange.parquet
extract_parquet_kv gks_dict_gene gene.parquet
extract_parquet gks_dict_variation variation.parquet

# Conditions
extract_parquet gks_dict_condition condition.parquet
extract_parquet gks_dict_condition_set conditionSet.parquet

# SCV (KV tables use EXPORT DATA)
extract_parquet_kv gks_dict_submitter submitter.parquet
extract_parquet_kv gks_dict_proposition proposition.parquet
extract_parquet gks_dict_evidence_line evidenceLine.parquet

# VCV/RCV (KV tables use EXPORT DATA)
extract_parquet_kv gks_dict_vcv_proposition vcv_proposition.parquet
extract_parquet gks_dict_vcv_evidence_line vcv_evidenceLine.parquet
extract_parquet_kv gks_dict_rcv_proposition rcv_proposition.parquet
extract_parquet gks_dict_rcv_evidence_line rcv_evidenceLine.parquet

# Statements
extract_parquet gks_dict_scv scv.parquet
extract_parquet gks_dict_vcv vcv.parquet
extract_parquet gks_dict_rcv rcv.parquet

echo "Done."
if ! $PARQUET_ONLY; then
  echo "  NDJSON:  ${GCS_PATH}/"
fi
echo "  Parquet: ${GCS_PARQUET_PATH}/"
