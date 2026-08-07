#!/bin/bash
#
# This script integrates three processes into a single pipeline:
# 1. Executes a Google Cloud Run job to transform a JSONL file.
# 2. Loads the output of that job from GCS into a BigQuery table.
# 3. Executes a series of BigQuery stored procedures to process the new data.
#
# Export & publish (GCS bundle + Parquet + R2 upload) is handled separately by
# release-gks.sh, not here. run-release.sh chains this script (steps 1-3) and then
# release-gks.sh.
#
# USAGE:
#   ./vrs-to-bq-table.sh <YYYY-MM-DD> [start_step]
#
# ARGUMENTS:
#   release_date  (Required) The ClinVar release date to process (YYYY-MM-DD).
#   start_step    (Optional) The step number (1-3) to start execution from.
#                 Defaults to 1 if not provided.
#                 - 1: Cloud Run Job
#                 - 2: BigQuery Load
#                 - 3: BigQuery Procedures
#
# The script performs all designated steps for the single given release date.

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
# Force gcloud/bq to default to the same project. Otherwise the bq wrapper prepends
# gcloud's core/project as a first --project_id ahead of our --project_id, and if they
# differ (e.g. a stray clingen-cvc-dev default) the client can hang polling job status
# against the wrong project. Keeping them identical avoids that.
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
# GCS Bucket for intermediate and final files
BUCKET_NAME='clinvar-gks'

# Incremental gks_vrs load: carry the prior release's gks_vrs forward and merge in
# only the changed variations (produced when export-vi-table-to-gcs.sh runs in its
# default incremental mode, so vi-final.jsonl.gz holds only the changed set). Falls
# back to a full --replace load automatically when no baseline gks_vrs exists.
# Set INCREMENTAL=false for a full --replace load (e.g. after a vrs-python or
# variation_identity transform version change, which invalidates carry-forward).
INCREMENTAL="${INCREMENTAL:-true}"

# Cloud Run Job Configuration
GCLOUD_JOB_NAME='vrs-to-vi-location-transformer'
GCLOUD_JOB_REGION='us-east1'

# BigQuery Load Configuration
TABLE_ID='gks_vrs'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE_PATH="${SCRIPT_DIR}/../../schemas/vrs_output_2_0_1.schema.json"

# BigQuery Stored Procedures to run in order.
# NOTE: gks_catvar is NOT listed here — it is called via its incremental wrapper
# (gks_catvar_proc_incremental) ahead of this loop in execute_bq_procedures.
BIGQUERY_PROCEDURES=(
  'clinvar_ingest.gks_scv_condition_proc'
  'clinvar_ingest.gks_scv_statement_proc'
  'clinvar_ingest.gks_rcv_proc'
  'clinvar_ingest.gks_rcv_statement_proc'
  'clinvar_ingest.gks_vcv_proc'
  'clinvar_ingest.gks_vcv_statement_proc'
)

# --- END OF CONFIGURATION ---


# --- FUNCTIONS ---

generate_dataset_id() {
  local date=$1
  local date_underscored="${date//-/_}"
  local prefix="clinvar_${date_underscored}_"

  # Find the existing dataset matching this release date
  local match
  match=$(bq ls --project_id="$PROJECT_ID" --max_results=10000 \
    | awk '{$1=$1; print}' \
    | grep "^${prefix}" \
    | head -n 1)

  if [[ -n "$match" ]]; then
    echo "$match"
  else
    echo "ERROR: No dataset found matching '${prefix}*' in project ${PROJECT_ID}" >&2
    return 1
  fi
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

  local staging="${dataset_id}.${TABLE_ID}_changed"

  # Always stage the loaded file first (it may be the changed subset or the whole
  # table, depending on how the extract ran). The mode is then DECIDED from the
  # data, not from a flag, so a full extract + incremental flag (or vice-versa)
  # cannot corrupt gks_vrs.
  echo "  - Loading vi-final into staging ${staging}..."
  if ! bq --project_id="$PROJECT_ID" load --source_format=NEWLINE_DELIMITED_JSON --schema="$SCHEMA_FILE_PATH" --max_bad_records=2 --ignore_unknown_values --replace "$staging" "$gcs_json_path"; then
    echo "❌ staging load failed."; return 1;
  fi

  # Resolve baseline + decide incremental vs full.
  local base_dataset base_has_vrs="false" staging_n changed_n="-1"
  base_dataset=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
    "SELECT schema_name FROM \`clinvar_ingest.schema_on\`((SELECT prev_release_date FROM \`clinvar_ingest.schema_on\`(DATE '${release_date}')))" \
    | tail -n 1 | tr -d '[:space:]')
  if [[ -n "$base_dataset" ]]; then
    base_has_vrs=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
      "SELECT COUNT(*)=1 FROM \`${base_dataset}.INFORMATION_SCHEMA.TABLES\` WHERE table_name='${TABLE_ID}'" \
      | tail -n 1 | tr -d '[:space:]')
  fi
  staging_n=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNT(*) FROM \`${staging}\`" | tail -n 1 | tr -d '[:space:]')
  # changed-set count (only if the incremental extract produced the table)
  if [[ "$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
      "SELECT COUNT(*)=1 FROM \`${dataset_id}.INFORMATION_SCHEMA.TABLES\` WHERE table_name='variation_vrs_changed'" | tail -n 1 | tr -d '[:space:]')" == "true" ]]; then
    changed_n=$(bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --format=csv --quiet \
      "SELECT COUNT(*) FROM \`${dataset_id}.variation_vrs_changed\`" | tail -n 1 | tr -d '[:space:]')
  fi

  # Incremental only when: enabled, a baseline gks_vrs exists, the changed-set
  # table exists, AND staging == changed-set count (i.e. vi-final really is the
  # changed subset). Otherwise a full replace from staging.
  if [[ "$INCREMENTAL" == "true" && -n "$base_dataset" && "$base_has_vrs" == "true" && "$changed_n" != "-1" && "$staging_n" == "$changed_n" ]]; then
    echo "  - Incremental: carry forward ${base_dataset}.${TABLE_ID} + merge ${staging_n} changed rows"
    bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet \
      "CREATE OR REPLACE TABLE \`${dataset_id}.${TABLE_ID}\` CLONE \`${base_dataset}.${TABLE_ID}\`" || { echo "❌ seed CLONE failed."; return 1; }
    if bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet \
      "DELETE FROM \`${dataset_id}.${TABLE_ID}\`
         WHERE \`in\`.variation_id IN (
           SELECT variation_id FROM \`${dataset_id}.variation_vrs_changed\`
           UNION DISTINCT SELECT variation_id FROM \`${dataset_id}.variation_vrs_removed\`);
       INSERT INTO \`${dataset_id}.${TABLE_ID}\` SELECT * FROM \`${staging}\`;
       DROP TABLE \`${staging}\`;"; then
      echo "✅ BigQuery incremental gks_vrs merge succeeded."; return 0;
    else
      echo "❌ BigQuery incremental merge failed."; return 1;
    fi
  fi

  # Full replace: gks_vrs = staging (staging is the whole table, or no usable
  # baseline / mismatch was detected).
  echo "  - Full replace (INCREMENTAL=${INCREMENTAL}, baseline gks_vrs=${base_has_vrs}, staging=${staging_n}, changed=${changed_n})"
  if bq --project_id="$PROJECT_ID" query --use_legacy_sql=false --quiet \
    "CREATE OR REPLACE TABLE \`${dataset_id}.${TABLE_ID}\` CLONE \`${staging}\`; DROP TABLE \`${staging}\`;"; then
    echo "✅ BigQuery full gks_vrs load succeeded."; return 0;
  else
    echo "❌ BigQuery full load failed."; return 1;
  fi
}

execute_bq_procedures() {
  local release_date=$1
  echo "Executing BigQuery stored procedures for date: $release_date"

  # catvar is incremental (Plan 1); its build proc self-guards + falls back to full.
  echo "  - Calling procedure: clinvar_ingest.gks_catvar_proc_incremental..."
  if ! bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false \
      "CALL \`clinvar_ingest.gks_catvar_proc_incremental\`('$release_date', FALSE)" > /dev/null; then
    echo "❌ gks_catvar_proc_incremental FAILED"; return 1;
  fi
  echo "    ✅ Success."

  for proc in "${BIGQUERY_PROCEDURES[@]}"; do
    echo "  - Calling procedure: $proc..."
    if ! bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false "CALL \`${proc}\`('$release_date', FALSE)" > /dev/null; then
      echo "❌ Procedure call FAILED for: $proc"; return 1;
    fi
    echo "    ✅ Success."
  done

  echo "  - Calling procedure: clinvar_ingest.gks_json_proc..."
  if ! bq --project_id="$PROJECT_ID" query --quiet --use_legacy_sql=false "CALL \`clinvar_ingest.gks_json_proc\`('$release_date', 'all')" > /dev/null; then
    echo "❌ Procedure call FAILED for: clinvar_ingest.gks_json_proc"; return 1;
  fi
  echo "    ✅ Success."

  echo "✅ All BigQuery procedures completed successfully."; return 0;
}


# --- MAIN EXECUTION ---

# Arguments: <release_date> [start_step]
date="${1:-}"
START_STEP="${2:-1}"

if [[ -z "$date" ]]; then
  echo "❌ Usage: $0 <YYYY-MM-DD> [start_step]"; exit 1
fi
if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "❌ Error: Invalid release date '$date'. Expected format YYYY-MM-DD."; exit 1
fi
if ! [[ "$START_STEP" =~ ^[1-3]$ ]]; then
  echo "❌ Error: Invalid start step '$START_STEP'. Please provide a number between 1 and 3."; exit 1
fi

echo "Starting ClinVar 3-Step Pipeline for ${date}..."
echo "Project: $PROJECT_ID"
echo ">>> Starting from Step ${START_STEP} <<<"
echo "=================================================="

# --- STEP 1: Execute Cloud Run Job ---
if (( START_STEP <= 1 )); then
  echo "[1/3] Executing Cloud Run job..."
  INPUT_FILE="gs://${BUCKET_NAME}/${date}/dev/vi-normalized-no-liftover.jsonl.gz"
  OUTPUT_FILE="gs://${BUCKET_NAME}/${date}/dev/vi-final.jsonl.gz"
  if ! gcloud run jobs execute "$GCLOUD_JOB_NAME" --project "$PROJECT_ID" --args "$INPUT_FILE" --args "$OUTPUT_FILE" --wait --region "$GCLOUD_JOB_REGION"; then
    echo "❌ [FAIL] Cloud Run job failed for ${date}."; exit 1
  fi
  echo "✅ Cloud Run job completed."
fi

# --- STEP 2: Load Data into BigQuery ---
if (( START_STEP <= 2 )); then
  echo "[2/3] Loading data into BigQuery..."
  if ! load_vrs_data "$date"; then
    echo "❌ [FAIL] BigQuery data load failed for ${date}."; exit 1
  fi
  echo "✅ BigQuery data load completed."
fi

# --- STEP 3: Execute BigQuery Stored Procedures ---
if (( START_STEP <= 3 )); then
  echo "[3/3] Executing downstream BigQuery procedures..."
  if ! execute_bq_procedures "$date"; then
    echo "❌ [FAIL] BigQuery procedure execution failed for ${date}."; exit 1
  fi
  echo "✅ BigQuery procedures completed."
fi

echo; echo "=================================================="
echo "✅ All steps completed successfully for ${date}."
exit 0
