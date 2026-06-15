#!/bin/bash
# export-gks-dicts.sh
# Export all GKS dictionary tables to GCS as NDJSON
#
# Usage: ./export-gks-dicts.sh <dataset> <gcs_bucket> [prefix]
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clingen-dev-clinvar-gks gks-dicts

set -euo pipefail

DATASET="${1:?Usage: $0 <dataset> <gcs_bucket> [prefix]}"
BUCKET="${2:?Usage: $0 <dataset> <gcs_bucket> [prefix]}"
PREFIX="${3:-gks-dicts}"
GCS_PATH="gs://${BUCKET}/${PREFIX}"

echo "Exporting GKS dictionaries from ${DATASET} to ${GCS_PATH}"

extract() {
  local table="$1"
  local filename="$2"
  echo "  Exporting ${table} -> ${filename}"
  bq extract --destination_format NEWLINE_DELIMITED_JSON \
    "${DATASET}.${table}" "${GCS_PATH}/${filename}"
}

# Cat-VRS dictionaries (from gks_catvar_proc)
extract gks_dict_sequence_reference sequenceReference.ndjson.gz
extract gks_dict_location location.ndjson.gz
extract gks_dict_allele allele.ndjson.gz
extract gks_dict_gene gene.ndjson.gz
extract gks_dict_variation variation.ndjson.gz

# Condition dictionaries (from gks_scv_condition_proc)
extract gks_traits condition.ndjson.gz
extract gks_trait_sets conditionSet.ndjson.gz

# SCV dictionaries (from gks_scv_statement_proc)
extract gks_dict_submitter submitter.ndjson.gz
extract gks_dict_proposition proposition.ndjson.gz

# VCV/RCV proposition dictionaries
extract gks_dict_vcv_proposition vcv_proposition.ndjson.gz
extract gks_dict_rcv_proposition rcv_proposition.ndjson.gz

# Statement outputs
extract gks_scv_statement_pre scv.ndjson.gz
extract gks_vcv_statement_pre vcv.ndjson.gz
extract gks_rcv_statement_pre rcv.ndjson.gz

echo "Done. Files exported to ${GCS_PATH}/"
