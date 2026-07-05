#!/bin/bash
# export-gks-dicts.sh
# Export all GKS dictionary tables to GCS as NDJSON
#
# Usage: ./export-gks-dicts.sh <dataset> <gcs_bucket> [prefix]
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clinvar-gks gks-dicts

set -euo pipefail

DATASET="${1:?Usage: $0 <dataset> <gcs_bucket> [prefix]}"
BUCKET="${2:?Usage: $0 <dataset> <gcs_bucket> [prefix]}"
PREFIX="${3:-gks-dicts}"
GCS_PATH="gs://${BUCKET}/${PREFIX}"

echo "Exporting GKS dictionaries from ${DATASET} to ${GCS_PATH}"

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

echo "Done. Files exported to ${GCS_PATH}/"
