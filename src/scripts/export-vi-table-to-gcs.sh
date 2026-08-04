#!/bin/bash
#
# Export a release's variation_identity to gs://clinvar-gks/<date>/dev/vi.jsonl.gz
# for vrs-python normalization (clinvar-gk-python `misc/clinvar-vrsification`).
#
# Default is INCREMENTAL: only the variations whose variation_identity changed
# since the prior release are exported, so vrs-python processes the delta (~0.3%
# of variations for a weekly release) instead of the whole ~4.5M snapshot. The
# unchanged variations' VRS results are carried forward when gks_vrs is loaded
# (see vrs-to-bq-table.sh). Pass --full to export the entire table (first release,
# or after a vrs-python / variation_identity transform version change).
#
# USAGE:
#   ./export-vi-table-to-gcs.sh YYYY-MM-DD [--full]
#
set -o errexit
set -o nounset
set -o pipefail

PROJECT_ID='clingen-dev'
BUCKET_NAME='clinvar-gks'

DATE="${1:?Usage: $0 YYYY-MM-DD [--full]}"
MODE="${2:-}"

# Resolve the dataset for this release date (e.g. clinvar_2026_07_20_v2_5_0).
DATASET_ID=$(bq ls --project_id="$PROJECT_ID" --max_results=10000 \
  | awk '{$1=$1; print}' | grep "^clinvar_${DATE//-/_}_" | head -n 1)
if [[ -z "$DATASET_ID" ]]; then
  echo "ERROR: no dataset found matching 'clinvar_${DATE//-/_}_*' in ${PROJECT_ID}" >&2
  exit 1
fi

OUT="gs://${BUCKET_NAME}/${DATE}/dev/vi.jsonl.gz"

if [[ "$MODE" == "--full" ]]; then
  echo "FULL extract: ${DATASET_ID}.variation_identity -> ${OUT}"
  # Wildcard destination in case the whole table exceeds the single-file limit;
  # vrs-python's downloader handles the composed/sharded input.
  bq extract --project_id="$PROJECT_ID" \
    --destination_format NEWLINE_DELIMITED_JSON --compression GZIP \
    "${DATASET_ID}.variation_identity" \
    "gs://${BUCKET_NAME}/${DATE}/dev/vi-*.jsonl.gz"
  exit 0
fi

echo "INCREMENTAL extract for ${DATE} (dataset ${DATASET_ID})"

# 1. Compute the changed / removed variation sets vs the prior release.
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet \
  "CALL \`clinvar_ingest.variation_vrs_changed\`(DATE '${DATE}')"

# 2. Materialize only the changed variations' variation_identity rows.
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet \
  "CREATE OR REPLACE TABLE \`${DATASET_ID}.vi_extract\` AS
   SELECT vi.*
   FROM \`${DATASET_ID}.variation_identity\` vi
   JOIN \`${DATASET_ID}.variation_vrs_changed\` c USING(variation_id)"

CHANGED=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv \
  "SELECT COUNT(*) FROM \`${DATASET_ID}.vi_extract\`" | tail -n 1 | tr -d '[:space:]')
echo "  changed variations to vrsify: ${CHANGED}"

# 3. Extract the (small) changed set as a single file.
bq extract --project_id="$PROJECT_ID" \
  --destination_format NEWLINE_DELIMITED_JSON --compression GZIP \
  "${DATASET_ID}.vi_extract" "${OUT}"
echo "Wrote ${CHANGED} changed variation_identity rows to ${OUT}"
