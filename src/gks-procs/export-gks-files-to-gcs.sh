#!/bin/bash

# --- DEBUGGING: Print every command as it's executed ---
# set -x

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
PROJECT_ID="clingen-dev"
BUCKET_NAME="clinvar-gks"

# --- Public Copy Configuration ---
# Default public bucket. Can be overridden if needed.
# If this is left empty, Step 5 will be skipped.
PUBLIC_BUCKET_NAME="clingen-public/clinvar-gks" 

# --- Date Configuration: Change this date to run for a different export ---
EXPORT_DATE="2025-09-28"
DATASET_VERSION="v2_4_3" # The version suffix of the dataset

# --- Dynamic Configuration (Derived from Date) ---
DATASET_ID="clinvar_${EXPORT_DATE//-/_}_${DATASET_VERSION}"
EXPORT_ROOT_PATH="${EXPORT_DATE}" # Root path in the bucket
TYPE="jsonl" # Using jsonl to be more specific, as it's newline-delimited JSON
DATE_SUFFIX="_${EXPORT_DATE//-/_}" # Creates _YYYY_MM_DD for public filenames
# PUBLIC_FILE_VERSION is now derived from DATASET_VERSION for consistency
PUBLIC_FILE_VERSION="_${DATASET_VERSION}"

# --- Table and Output Mapping ---
TABLE_NAMES=(
  "gks_catvar"
  "gks_statement_scv_by_ref"
  "gks_statement_scv_inline"
)
OUTPUT_NAMES=(
  "variation"
  "scv_by_ref"
  "scv_inline"
)

# --- Helper Functions for dynamic console output ---

# Prints an initial status message without a newline.
print_status() {
  echo -n -e "$1"
}

# Overwrite an initial status message without a newline.
rewrite_status() {
  # \r: carriage return, \033[K: clear line from cursor to end
  echo -n -e "\r\033[K$1"
}

# Overwrites the previous status line with a final message and moves to the next line.
finalize_status() {
  # \r: carriage return, \033[K: clear line from cursor to end
  echo -e "\r\033[K$1"
}

# --- Main Logic ---
for i in "${!TABLE_NAMES[@]}"; do
  TABLE="${TABLE_NAMES[$i]}"
  OUTPUT_NAME="${OUTPUT_NAMES[$i]}"

  # --- Define Paths (with distinct naming for shards) ---
  GCS_ROOT_PATH="gs://${BUCKET_NAME}/${EXPORT_ROOT_PATH}"
  GCS_TEMP_PATH="${GCS_ROOT_PATH}/${OUTPUT_NAME}"
  SHARD_EXPORT_URI="${GCS_TEMP_PATH}/shard-*.${TYPE}.gz"
  # Composed file is created inside in the EXPORT_ROOT_PATH folder of the BUCKET
  COMPOSED_FILE_URI="${GCS_ROOT_PATH}/${OUTPUT_NAME}.${TYPE}.gz"

  # --- Define SELECT fields based on the table name ---
  if [[ "${TABLE}" == "gks_catvar" ]]; then
    SELECT_FIELDS=$(cat <<-SQL
  rec.aliases, rec.constraints, rec.description, rec.extensions, rec.id,
  rec.mappings, rec.members, rec.name, rec.type
SQL
)
  else
    SELECT_FIELDS=$(cat <<-SQL
  rec.aliases, rec.classification, rec.contributions, rec.description,
  rec.direction, rec.extensions, rec.hasEvidenceLines, rec.id, rec.name,
  rec.proposition, rec.reportedIn, rec.score, rec.specifiedBy, rec.strength, rec.type
SQL
)
  fi

  echo "--- Starting process for table: ${TABLE} ---"
  
  # --- Step 1: Export Data ---
  print_status "1. Exporting data to temporary shards..."
  bq query \
    --project_id="${PROJECT_ID}" \
    --use_legacy_sql=false \
    --sync=true \
    --quiet \
  << EOF > /dev/null
    EXPORT DATA OPTIONS(
      uri="${SHARD_EXPORT_URI}",
      format="JSON",
      compression="GZIP",
      overwrite=true
    ) AS
    SELECT ${SELECT_FIELDS}
    FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE}\`;
EOF
  finalize_status "1. Export completed."

  # --- Step 2: Robust Two-Level Hierarchical Compose ---
  read -r -d '' -a source_shards < <(gsutil -m ls "${SHARD_EXPORT_URI}" && printf '\0' || true)

  if [ ${#source_shards[@]} -eq 0 ]; then
    print_status "2. No shards found to compose..."
    echo -n | gzip | gsutil cp - "${COMPOSED_FILE_URI}" &> /dev/null
    finalize_status "2. Composition complete (empty file created)."
  elif [ ${#source_shards[@]} -le 32 ]; then # Simple case
    print_status "2. Composing final set of ${#source_shards[@]} shards..."
    gsutil compose "${source_shards[@]}" "${COMPOSED_FILE_URI}" &> /dev/null
    finalize_status "2. Composition complete."
  else # Multi-level case
    composed_batches=()
    batch_counter=1
    total_batches=$(( (${#source_shards[@]} + 31) / 32 ))
    for (( i=0; i < ${#source_shards[@]}; i+=32 )); do
      batch_to_compose=( "${source_shards[@]:i:32}" )
      temp_batch_uri="${GCS_TEMP_PATH}/composed-batch_${batch_counter}.gz"
      rewrite_status "2. Composing batch ${batch_counter} of ${total_batches}..."
      gsutil compose "${batch_to_compose[@]}" "${temp_batch_uri}" &> /dev/null
      composed_batches+=( "${temp_batch_uri}" )
      ((batch_counter++))
    done
    rewrite_status "2. Composing final file from ${#composed_batches[@]} batches..."
    gsutil compose "${composed_batches[@]}" "${COMPOSED_FILE_URI}" &> /dev/null
    gsutil -m rm "${composed_batches[@]}" &> /dev/null
    finalize_status "2. Composition complete."
  fi

  # --- Step 3: Clean up temporary directories ---
  print_status "3. Cleaning up temporary directory..."
  # Deletes the entire folder (shards, composed file, etc.)
  gsutil -m rm -r "${GCS_TEMP_PATH}" &>/dev/null || true
  finalize_status "3. Cleanup complete."

  # --- Step 4: Validation ---
  print_status "4. Validating record counts..."
  bq_count=$(bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false --format=csv "SELECT COUNT(*) FROM \`${PROJECT_ID}.${DATASET_ID}.${TABLE}\`" | tail -n 1)
  
  # Define the public filename for validation counting
  PUBLIC_FILENAME="clinvar_gks_${OUTPUT_NAME}${DATE_SUFFIX}${PUBLIC_FILE_VERSION}.${TYPE}.gz"
  PUBLIC_FILE_URI="gs://${PUBLIC_BUCKET_NAME}/${PUBLIC_FILENAME}"
  
  # rewrite_status "4. Validating record counts... (Counting records in GCS)"
  if [[ -n "${PUBLIC_BUCKET_NAME}" ]] && gsutil -q stat "${PUBLIC_FILE_URI}"; then
    gcs_count=$(gsutil cat "${PUBLIC_FILE_URI}" | gunzip -c | wc -l)
  else
    gcs_count=0
  fi
  
  bq_count=$(echo "$bq_count" | tr -d '[:space:]')
  gcs_count=$(echo "$gcs_count" | tr -d '[:space:]')

  if [[ "${bq_count}" -eq "${gcs_count}" ]]; then
    finalize_status "4. ✅ VALIDATION SUCCESS: Record counts match (${bq_count})."
  else
    finalize_status "4. ❌ VALIDATION FAILED: Record count Mismatch for table ${TABLE}!"
    echo "   - Source BigQuery Table Count: ${bq_count}"
    echo "   - Final GCS File Record Count: ${gcs_count}"
    exit 1
  fi

  # --- Step 5: Copy to Public Bucket ---
  if [[ -n "${PUBLIC_BUCKET_NAME}" ]]; then
    print_status "5. Copying to public bucket..."
    gsutil cp "${COMPOSED_FILE_URI}" "${PUBLIC_FILE_URI}" #&> /dev/null
    finalize_status "5. ✅ Public copy complete."
    echo "   - Copied to: ${PUBLIC_FILE_URI}"
  else
    echo "5. Skipping public copy (PUBLIC_BUCKET_NAME is not set)."
  fi
  
  echo "✅ Successfully processed table ${TABLE}."
  echo "----------------------------------------------------------------"
done

echo "All jobs have completed successfully."