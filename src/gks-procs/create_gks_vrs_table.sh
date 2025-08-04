#!/bin/bash

# Set the project id
PROJECT_ID='clingen-dev'

# Array of release dates to process
RELEASE_DATES=(
  '2025-07-20'
  '2025-07-29'
  # Add more dates as needed
)

# Set the table id
TABLE_ID='gks_vrs'

# Set the BigQuery schema
SCHEMA_FILE_PATH='vrs_output_2_0_1.schema.json'

# Function to generate dataset ID from date
generate_dataset_id() {
  local date=$1
  echo "clinvar_${date//-/_}_v2_3_1"
}

# Function to load data for a single date
load_vrs_data() {
  local release_date=$1
  local dataset_id
  dataset_id=$(generate_dataset_id "$release_date")
  local gcs_json_path="gs://clinvar-gks/${release_date}/dev/vi-normalized-no-liftover-fix.jsonl.gz"
  
  echo "Processing release date: $release_date"
  echo "Dataset: $dataset_id"
  echo "GCS Path: $gcs_json_path"
  echo "---"
  
  # Check if GCS file exists
  if ! gsutil ls "$gcs_json_path" &>/dev/null; then
    echo "WARNING: GCS file not found: $gcs_json_path"
    echo "Skipping $release_date"
    echo
    return 1
  fi
  
  # Load the data from the GCS JSON file into the BigQuery table
  echo "Loading data for $release_date..."
  if bq --project_id="$PROJECT_ID" load \
     --source_format=NEWLINE_DELIMITED_JSON \
     --schema="$SCHEMA_FILE_PATH" \
     --max_bad_records=2 \
     --ignore_unknown_values \
     --replace \
     "$dataset_id.$TABLE_ID" \
     "$gcs_json_path"; then
    echo "✅ Data load succeeded for $release_date"
  else
    echo "❌ Data load failed for $release_date"
    return 1
  fi
  echo
}

# Main execution
echo "Starting VRS table creation for multiple dates..."
echo "Project: $PROJECT_ID"
echo "Schema: $SCHEMA_FILE_PATH"
echo "Dates to process: ${#RELEASE_DATES[@]}"
echo "=================================="

success_count=0
failure_count=0
failed_dates=()

# Process each date
for date in "${RELEASE_DATES[@]}"; do
  if load_vrs_data "$date"; then
    ((success_count++))
  else
    ((failure_count++))
    failed_dates+=("$date")
  fi
done

# Summary
echo "=================================="
echo "Processing complete!"
echo "✅ Successful loads: $success_count"
echo "❌ Failed loads: $failure_count"

if [ ${#failed_dates[@]} -gt 0 ]; then
  echo "Failed dates: ${failed_dates[*]}"
  exit 1
else
  echo "All dates processed successfully!"
  exit 0
fi
