#!/bin/bash
#
# This script integrates four processes into a single pipeline:
# 1. Executes a Google Cloud Run job to transform a JSONL file.
# 2. Loads the output of that job from GCS into a BigQuery table.
# 3. Executes a series of BigQuery stored procedures to process the new data.
# 4. Exports final tables to GCS, composes them using a robust multi-level
#    strategy, and copies them to a public bucket.
#
# USAGE:
#   ./run_pipeline.sh [start_step]
#
# ARGUMENTS:
#   start_step    (Optional) The step number (1-4) to start execution from.
#                 Defaults to 1 if not provided.
#                 - 1: Cloud Run Job
#                 - 2: BigQuery Load
#                 - 3: BigQuery Procedures
#                 - 4: Export & Publish
#
# The script iterates over a list of release dates, performing all designated
# steps for each date sequentially.

# --- SCRIPT SETUP ---
# Exit immediately if a command exits with a non-zero status.
set -o errexit
# Treat unset variables as an error.
set -o nounset
# Pipelines fail if any command in the pipe fails.
set -o pipefail

# --- CONFIGURATION ---
# Please set the variables below before running.

# Google Cloud Project ID
PROJECT_ID='clingen-dev'
# GCS Bucket for intermediate and final files
BUCKET_NAME='clinvar-gks'
# Public GCS Bucket for final distribution. Leave empty to skip public copy.
PUBLIC_BUCKET_NAME='clingen-public/clinvar-gks'

# Cloud Run Job Configuration
GCLOUD_JOB_NAME='vrs-to-vi-location-transformer'
GCLOUD_JOB_REGION='us-east1'

# BigQuery Load Configuration
TABLE_ID='gks_vrs'
SCHEMA_FILE_PATH='vrs_output_2_0_1.schema.json'
DATASET_VERSION='v2_4_3' # The version suffix of the dataset

# BigQuery Stored Procedures to run in order.
BIGQUERY_PROCEDURES=(
  'clinvar_ingest.gks_catvar_proc'
  'clinvar_ingest.gks_scv_condition_mapping_proc'
  'clinvar_ingest.gks_trait_proc'
  'clinvar_ingest.gks_scv_condition_sets_proc'
  'clinvar_ingest.gks_scv_proc'
  'clinvar_ingest.gks_scv_proposition_proc'
  'clinvar_ingest.gks_statement_scv_proc'
)

# BigQuery Export Configuration
EXPORT_TABLE_NAMES=(
  "gks_catvar"
  "gks_statement_scv_by_ref"
  "gks_statement_scv_inline"
)
EXPORT_OUTPUT_NAMES=(
  "variation"
  "scv_by_ref"
  "scv_inline"
)

# Array of release dates to process (format: YYYY-MM-DD)
RELEASE_DATES=(
  # '2025-09-15'
  # '2025-09-23'
  # '2025-09-28'
  # '2025-10-06'
  # '2025-10-13'
  # '2025-10-19'
  # '2025-10-27'
  # '2025-11-03'
  # '2025-11-09'
  # '2025-11-16'
  # '2025-11-23'
  # '2025-12-01'
  # '2025-12-08'
  # '2025-12-15'
  # '2025-12-20'
  # '2025-12-27'
  # '2026-01-04'
  # '2026-01-13'
  '2026-01-20'
  # Add more dates as needed
)
# --- END OF CONFIGURATION ---


# --- FUNCTIONS ---

# Prints an initial status message without a newline.
print_status() { echo -n -e "$1"; }
# Overwrite an initial status message with new text.
rewrite_status() { echo -n -e "\r\033[K$1"; }
# Overwrites the previous status line with a final message and moves to the next line.
finalize_status() { echo -e "\r\033[K$1"; }

generate_dataset_id() {
  local date=$1
  echo "clinvar_${date//-/_}_${DATASET_VERSION}"
}

load_vrs_data() {
  local release_date=$1
  local dataset_id; dataset_id=$(generate_dataset_id "$release_date")
  local gcs_json_path="gs://${BUCKET_NAME}/${release_date}/dev/vi-final.jsonl.gz"
  
  echo "Attempting to load data for $release_date..."
  echo "  - BigQuery Table: $PROJECT_ID:$dataset_id.$TABLE_ID"
  echo "  - GCS Source: $gcs_json_path"
  
  if ! gcloud storage ls "$gcs_json_path" &>/dev/null; then
    echo "❌ ERROR: GCS file not found. Ensure Step 1 completed successfully: $gcs_json_path"; return 1;
  fi
  
  if bq --project_id="$PROJECT_ID" load --source_format=NEWLINE_DELIMITED_JSON --schema="$SCHEMA_FILE_PATH" --max_bad_records=2 --ignore_unknown_values --replace "$dataset_id.$TABLE_ID" "$gcs_json_path"; then
    echo "✅ BigQuery load succeeded."; return 0;
  else
    echo "❌ BigQuery load failed."; return 1;
  fi
}

execute_bq_procedures() {
  local release_date=$1
  echo "Executing BigQuery stored procedures for date: $release_date"

  for proc in "${BIGQUERY_PROCEDURES[@]}"; do
    echo "  - Calling procedure: $proc..."
    if ! bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false "CALL \`${proc}\`('$release_date')" > /dev/null; then
      echo "❌ Procedure call FAILED for: $proc"; return 1;
    fi
    echo "    ✅ Success."
  done
  echo "✅ All BigQuery procedures completed successfully."; return 0;
}

export_and_publish_tables() {
    local release_date=$1
    local dataset_id; dataset_id=$(generate_dataset_id "$release_date")
    local export_root_path="${release_date}"
    local type="jsonl"
    local date_suffix="_${release_date//-/_}"
    local public_file_version="_${DATASET_VERSION}"

    echo "Starting export and publish process for dataset: ${dataset_id}"

    for i in "${!EXPORT_TABLE_NAMES[@]}"; do
        local table="${EXPORT_TABLE_NAMES[$i]}"
        local output_name="${EXPORT_OUTPUT_NAMES[$i]}"

        local gcs_root_path="gs://${BUCKET_NAME}/${export_root_path}"
        local gcs_temp_path="${gcs_root_path}/${output_name}-temp-shards"
        local shard_export_uri="${gcs_temp_path}/shard-*.${type}.gz"
        local composed_file_uri="${gcs_root_path}/${output_name}.${type}.gz"
        local public_filename="clinvar_gks_${output_name}${date_suffix}${public_file_version}.${type}.gz"
        local public_file_uri="gs://${PUBLIC_BUCKET_NAME}/${public_filename}"

        local select_fields
        if [[ "${table}" == "gks_catvar" ]]; then
            select_fields='rec.aliases, rec.constraints, rec.description, rec.extensions, rec.id, rec.mappings, rec.members, rec.name, rec.type'
        else
            select_fields='rec.aliases, rec.classification, rec.contributions, rec.description, rec.direction, rec.extensions, rec.hasEvidenceLines, rec.id, rec.name, rec.proposition, rec.reportedIn, rec.score, rec.specifiedBy, rec.strength, rec.type'
        fi

        echo "--- Processing table: ${table} ---"
        
        # 1. Export Data
        print_status "1. Exporting data to shards..."
        bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false --quiet "EXPORT DATA OPTIONS(uri='${shard_export_uri}', format='JSON', compression='GZIP', overwrite=true) AS SELECT ${select_fields} FROM \`${PROJECT_ID}.${dataset_id}.${table}\`"
        finalize_status "1. Export completed."

        # 2. Robust Two-Level Hierarchical Compose
        read -r -d '' -a source_shards < <(gcloud storage ls "${shard_export_uri}" 2>/dev/null && printf '\0' || true)

        if [ ${#source_shards[@]} -eq 0 ]; then
            print_status "2. No shards found to compose..."
            echo -n | gzip | gcloud storage cp - "${composed_file_uri}" &> /dev/null
            finalize_status "2. Composition complete (empty file created)."
        elif [ ${#source_shards[@]} -le 32 ]; then # Simple case
            print_status "2. Composing final set of ${#source_shards[@]} shards..."
            gcloud storage objects compose "${source_shards[@]}" "${composed_file_uri}" &> /dev/null
            finalize_status "2. Composition complete."
        else # Multi-level case for > 32 shards
            composed_batches=()
            batch_counter=1
            total_batches=$(( (${#source_shards[@]} + 31) / 32 ))
            for (( j=0; j < ${#source_shards[@]}; j+=32 )); do
            batch_to_compose=( "${source_shards[@]:j:32}" )
            temp_batch_uri="${gcs_temp_path}/composed-batch_${batch_counter}.gz"
            rewrite_status "2. Composing batch ${batch_counter} of ${total_batches}..."
            gcloud storage objects compose "${batch_to_compose[@]}" "${temp_batch_uri}" &> /dev/null
            composed_batches+=( "${temp_batch_uri}" )
            ((batch_counter++))
            done
            rewrite_status "2. Composing final file from ${#composed_batches[@]} batches..."
            gcloud storage objects compose "${composed_batches[@]}" "${composed_file_uri}" &> /dev/null
            gcloud storage rm "${composed_batches[@]}" &> /dev/null
            finalize_status "2. Composition complete."
        fi

        # 3. Cleanup
        print_status "3. Cleaning up temporary shards..."
        gcloud storage rm -r "${gcs_temp_path}" &>/dev/null || true
        finalize_status "3. Cleanup complete."

        # 4. Validation
        print_status "4. Validating record counts..."
        local bq_count; bq_count=$(bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false --format=csv "SELECT COUNT(*) FROM \`${PROJECT_ID}.${dataset_id}.${table}\`" | tail -n 1)
        local gcs_count; gcs_count=$(gcloud storage cat "${composed_file_uri}" | gunzip -c | wc -l)
        bq_count=$(echo "$bq_count" | tr -d '[:space:]'); gcs_count=$(echo "$gcs_count" | tr -d '[:space:]')

        if [[ "${bq_count}" -eq "${gcs_count}" ]]; then
            finalize_status "4. ✅ VALIDATION SUCCESS: Record counts match (${bq_count})."
        else
            finalize_status "4. ❌ VALIDATION FAILED: BQ count (${bq_count}) != GCS count (${gcs_count}) for ${table}!"
            return 1
        fi

        # 5. Public Copy
        if [[ -n "${PUBLIC_BUCKET_NAME}" ]]; then
            print_status "5. Copying to public bucket..."
            gcloud storage cp "${composed_file_uri}" "${public_file_uri}" &> /dev/null
            finalize_status "5. ✅ Public copy complete."
            echo "   - Copied to: ${public_file_uri}"
        else
            echo "5. Skipping public copy (PUBLIC_BUCKET_NAME is not set)."
        fi
        echo "-------------------------------------"
    done
    return 0
}


# --- MAIN EXECUTION ---

# Set start step from command-line argument, default to 1
START_STEP=${1:-1}

# Validate the start step input
if ! [[ "$START_STEP" =~ ^[1-4]$ ]]; then
    echo "❌ Error: Invalid start step '$START_STEP'. Please provide a number between 1 and 4."
    exit 1
fi

echo "Starting ClinVar 4-Step Pipeline..."
echo "Project: $PROJECT_ID / Dates to process: ${#RELEASE_DATES[@]}"
echo ">>> Starting from Step ${START_STEP} <<<"
echo "=================================================="

success_count=0; failure_count=0; failed_dates_details=()

for date in "${RELEASE_DATES[@]}"; do
  echo; echo "--- Processing release date: $date ---"
  
  # --- STEP 1: Execute Cloud Run Job ---
  if (( START_STEP <= 1 )); then
    echo "[1/4] Executing Cloud Run job..."
    INPUT_FILE="gs://${BUCKET_NAME}/${date}/dev/vi-normalized-no-liftover.jsonl.gz"
    OUTPUT_FILE="gs://${BUCKET_NAME}/${date}/dev/vi-final.jsonl.gz"
    if ! gcloud run jobs execute "$GCLOUD_JOB_NAME" --args "$INPUT_FILE" --args "$OUTPUT_FILE" --wait --region "$GCLOUD_JOB_REGION"; then
      echo "❌ [FAIL] Cloud Run job failed."; ((failure_count++)); failed_dates_details+=("$date (Cloud Run Job)"); continue;
    fi
    echo "✅ Cloud Run job completed."
  fi

  # --- STEP 2: Load Data into BigQuery ---
  if (( START_STEP <= 2 )); then
    echo "[2/4] Loading data into BigQuery..."
    if ! load_vrs_data "$date"; then
      echo "❌ [FAIL] BigQuery data load failed."; ((failure_count++)); failed_dates_details+=("$date (BigQuery Load)"); continue;
    fi
    echo "✅ BigQuery data load completed."
  fi

  # --- STEP 3: Execute BigQuery Stored Procedures ---
  if (( START_STEP <= 3 )); then
    echo "[3/4] Executing downstream BigQuery procedures..."
    if ! execute_bq_procedures "$date"; then
      echo "❌ [FAIL] BigQuery procedure execution failed."; ((failure_count++)); failed_dates_details+=("$date (BigQuery Procedures)"); continue;
    fi
    echo "✅ BigQuery procedures completed."
  fi
  
  # --- STEP 4: Export and Publish Tables ---
  if (( START_STEP <= 4 )); then
    echo "[4/4] Exporting and publishing result tables..."
    if ! export_and_publish_tables "$date"; then
      echo "❌ [FAIL] Export and publish step failed."; ((failure_count++)); failed_dates_details+=("$date (Export/Publish)"); continue;
    fi
    echo "✅ Export and publish step completed."
  fi

  echo "--- ✅ All steps completed successfully for date: $date ---"
  ((success_count++))
done


# --- SUMMARY ---
echo; echo "=================================================="
echo "Pipeline processing complete!"
echo "✅ Successful dates: $success_count"
echo "❌ Failed dates:     $failure_count"

if [ ${#failed_dates_details[@]} -gt 0 ]; then
  echo "--------------------------------------------------"; echo "Details of failures:"
  printf " - %s\n" "${failed_dates_details[@]}"; exit 1;
else
  echo "All dates processed successfully!"; exit 0;
fi