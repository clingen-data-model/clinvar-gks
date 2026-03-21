#!/bin/bash

# Set variables
PROJECT_ID="clingen-stage"
DATASET_ID="clinvar_2024_08_12_v1_6_62"
LOCATION="US"
BUCKET_NAME="clinvar-releases"  # Replace with your bucket name
SCHEMA_PATH="${EXPORT_PATH}/schemas"
EXPORT_PATH="exports/clinvar_2024_08_12_v1_6_62"
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


# # Loop over each table and export to JSON with GZIP compression
# for TABLE in "${TABLES[@]}"; do
#   EXPORT_URI="gs://${BUCKET_NAME}/${EXPORT_PATH}/${TABLE}-*.json.gz"
  
#   bq --location="${LOCATION}" extract \
#     --destination_format=NEWLINE_DELIMITED_JSON \
#     --compression=GZIP \
#     "${PROJECT_ID}:${DATASET_ID}.${TABLE}" \
#     "${EXPORT_URI}"
    
#   if [ $? -eq 0 ]; then
#     echo "Exported ${TABLE} to ${EXPORT_URI}"
#   else
#     echo "Failed to export ${TABLE}"
#   fi
# done

# echo "All exports completed."

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

bq extract \
  --destination_format NEWLINE_DELIMITED_JSON \
  --compression GZIP \
  'clinvar_2025_07_29_v2_3_1.variation_identity' \
  gs://clinvar-gks/2025-07-29/dev/vi.json.gz
#   # gs://clinvar-gks/20??-??-??/dev/vi.json.gz