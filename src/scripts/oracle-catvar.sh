#!/bin/bash
# oracle-catvar.sh — full-vs-incremental oracle for gks_catvar.
# Builds gks_catvar FULL and INCREMENTAL for the same compare release from the same
# baseline, into two scratch datasets, and asserts 0 canonical diffs on all 7 outputs.
#
# USAGE: ./src/scripts/oracle-catvar.sh <COMPARE_DATE> [PROJECT_ID]
#   Requires: gks_vrs + variation_* + diff_* already built for COMPARE_DATE, and a
#   same-gate baseline release present. Run after Chunk 3 is deployed.
set -o errexit -o nounset -o pipefail
DATE="${1:?compare date YYYY-MM-DD}"
PROJECT_ID="${2:-clingen-dev}"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

SCHEMA=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '${DATE}')" | tail -1 | tr -d '[:space:]')
FULL_DS="${SCHEMA}_oracle_full"
INCR_DS="${SCHEMA}_oracle_incr"

# The seven catvar outputs and their primary keys.
TABLES=(
  "gks_dict_variation:id"
  "gks_dict_sequence_reference:key"
  "gks_dict_location:key"
  "gks_dict_allele:key"
  "gks_dict_copy_number_count:key"
  "gks_dict_copy_number_change:key"
  "gks_dict_gene:key"
)

# gks_catvar writes into {S}; to compare two builds we run full, snapshot the 7 tables
# aside via CLONE, then run incremental (which overwrites {S}) and snapshot again. We
# compare the two snapshots. The FINAL state of {S} is the incremental build — the
# intended production output.
echo ">>> full build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_catvar_proc\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${FULL_DS}" 2>/dev/null || true
for t in "${TABLES[@]}"; do n="${t%%:*}"
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${FULL_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> incremental build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_catvar_proc_incremental\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${INCR_DS}" 2>/dev/null || true
for t in "${TABLES[@]}"; do n="${t%%:*}"
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${INCR_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> compare"
FAIL=0
for t in "${TABLES[@]}"; do n="${t%%:*}"; pk="${t##*:}"
  OUT=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "CALL \`clinvar_ingest.gks_oracle_compare\`('${FULL_DS}','${INCR_DS}','${n}','${pk}')" | tail -1)
  echo "  ${OUT}"
  echo "${OUT}" | awk -F, '{ if ($2+$3+$4 != 0) exit 1 }' || FAIL=1
done
if (( FAIL )); then echo "❌ ORACLE FAILED"; exit 1; fi
echo "✅ ORACLE PASSED (0 diffs on all catvar tables)"
