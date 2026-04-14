#!/bin/bash

# Set variables
PROJECT_ID="clingen-dev"
DATASET_ID="clinvar_2026_04_04_v2_4_3"
LOCATION="US"
BUCKET_NAME="clingen-public/upenn/clinvar_scvs_2026_04_04"  # Replace with your bucket name
SCHEMA_PATH="${EXPORT_PATH}/schemas"
EXPORT_PATH="exports/clinvar_2026_04_04_v2_4_3"
TABLES=(
  "clinical_assertion"
  "clinical_assertion_observation"
  "clinical_assertion_trait"
  "clinical_assertion_trait_set"
  "clinical_assertion_variation"
  "gene"
  "gene_association"
  "rcv_accession"
  "scv_summary"
  "single_gene_variation"
  "submission"
  "submitter"
  "trait"
  "trait_mapping"
  "trait_set"
  "variation"
  "variation_archive"
)


# Server-side compose all shards matching a wildcard into a single object.
# gsutil compose supports at most 32 source components per call, so for tables
# with more shards we compose hierarchically in batches of 32. Concatenated
# gzip streams are themselves a valid gzip stream, so the result is a readable
# .json.gz file.
compose_shards() {
  local pattern="$1"
  local dest="$2"
  local sources=()

  while IFS= read -r line; do
    sources+=("$line")
  done < <(gsutil ls "$pattern" 2>/dev/null | sort)

  if [ ${#sources[@]} -eq 0 ]; then
    echo "No shards found for pattern: $pattern" >&2
    return 1
  fi

  # Single shard: just rename it to the combined name.
  if [ ${#sources[@]} -eq 1 ]; then
    gsutil mv "${sources[0]}" "$dest"
    return $?
  fi

  local round=0
  while [ ${#sources[@]} -gt 32 ]; do
    local next=()
    local i=0
    while [ $i -lt ${#sources[@]} ]; do
      local count=32
      [ $((i + count)) -gt ${#sources[@]} ] && count=$((${#sources[@]} - i))
      local intermediate="${dest}.compose.r${round}.b$((i / 32))"
      gsutil compose "${sources[@]:i:count}" "$intermediate" || return 1
      next+=("$intermediate")
      i=$((i + 32))
    done
    sources=("${next[@]}")
    round=$((round + 1))
  done

  gsutil compose "${sources[@]}" "$dest" || return 1
}

# Loop over each table and export to JSON with GZIP compression, then combine
# the sharded output back into a single .json.gz file per table.
for TABLE in "${TABLES[@]}"; do
  SHARD_URI="gs://${BUCKET_NAME}/${EXPORT_PATH}/${TABLE}-*.json.gz"
  COMBINED_URI="gs://${BUCKET_NAME}/${EXPORT_PATH}/${TABLE}.json.gz"

  if ! bq --location="${LOCATION}" extract \
    --destination_format=NEWLINE_DELIMITED_JSON \
    --compression=GZIP \
    "${PROJECT_ID}:${DATASET_ID}.${TABLE}" \
    "${SHARD_URI}"; then
    echo "Failed to export ${TABLE}"
    continue
  fi
  echo "Exported ${TABLE} shards to ${SHARD_URI}"

  if compose_shards "${SHARD_URI}" "${COMBINED_URI}"; then
    # Remove the original shards and any hierarchical compose intermediates.
    gsutil -m rm "${SHARD_URI}" 2>/dev/null
    gsutil -m rm "${COMBINED_URI}.compose.*" 2>/dev/null
    echo "Combined ${TABLE} into ${COMBINED_URI}"
  else
    echo "Failed to combine shards for ${TABLE}"
  fi
done

echo "All exports completed."

# Loop over each table and export the schema to a JSON file in the GCS bucket
for TABLE in "${TABLES[@]}"; do
  SCHEMA_FILE="${TABLE}_schema.json"
  LOCAL_SCHEMA_FILE="./${SCHEMA_FILE}"
  GCS_SCHEMA_FILE="gs://${BUCKET_NAME}/${SCHEMA_PATH}/${SCHEMA_FILE}"
  
  # Export schema to a local JSON file
  bq show --format=prettyjson "${PROJECT_ID}:${DATASET_ID}.${TABLE}" > ${LOCAL_SCHEMA_FILE}
  
  if [ $? -eq 0 ]; then
    echo "Exported schema for ${TABLE} to ${LOCAL_SCHEMA_FILE}"
    
    # Upload the schema file to GCS
    gsutil cp ${LOCAL_SCHEMA_FILE} ${GCS_SCHEMA_FILE}
    
    if [ $? -eq 0 ]; then
      echo "Uploaded schema for ${TABLE} to ${GCS_SCHEMA_FILE}"
    else
      echo "Failed to upload schema for ${TABLE}"
    fi
    
    # Clean up local schema file
    rm ${LOCAL_SCHEMA_FILE}
  else
    echo "Failed to export schema for ${TABLE}"
  fi
done

echo "All schema exports completed."

# below is a single table export

# bq extract \
#   --destination_format NEWLINE_DELIMITED_JSON \
#   --compression GZIP \
#   'clinvar_2025_07_29_v2_3_1.variation_identity' \
#   gs://clinvar-gks/2025-07-29/dev/vi.json.gz
# #   # gs://clinvar-gks/20??-??-??/dev/vi.json.gz