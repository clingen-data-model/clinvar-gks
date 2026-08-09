#!/bin/bash
# oracle-scv-statement.sh — full-vs-incremental oracle for gks_scv_statement.
# Builds gks_scv_statement FULL and INCREMENTAL for the same compare release from the
# same baseline, into two scratch datasets, and asserts 0 canonical diffs on all 4 outputs.
#
# USAGE: ./src/scripts/oracle-scv-statement.sh <COMPARE_DATE> [PROJECT_ID]
#   Requires: gks_scv_condition_sets + diff_* already built for COMPARE_DATE, the shared
#   changed-set (gks_scv_changed) run, and a same-gate baseline release present with the
#   four statement outputs (built by the CURRENT proc — the baseline gks_dict_scv /
#   gks_dict_evidence_line / gks_dict_proposition schema must match, or the merge errors).
# NOTE: the ${SCHEMA}_oracle_full / _oracle_incr scratch datasets are left behind for
#   inspection.
set -o errexit -o nounset -o pipefail
DATE="${1:?compare date YYYY-MM-DD}"
PROJECT_ID="${2:-clingen-dev}"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

SCHEMA=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
  "SELECT schema_name FROM \`clinvar_ingest.schema_on\`(DATE '${DATE}')" | tail -1 | tr -d '[:space:]')
if [[ -z "$SCHEMA" || "$SCHEMA" == "schema_name" ]]; then
  echo "❌ no ClinVar release found for ${DATE}" >&2; exit 1
fi
FULL_DS="${SCHEMA}_oracle_full"
INCR_DS="${SCHEMA}_oracle_incr"

# The four statement outputs.
TABLES=(
  "gks_dict_submitter"
  "gks_dict_proposition"
  "gks_dict_evidence_line"
  "gks_dict_scv"
)

# gks_scv_statement writes into {S}; to compare two builds we run full, snapshot the 4
# tables aside via CLONE, then run incremental (which overwrites {S}) and snapshot again.
# We compare the two snapshots. The FINAL state of {S} is the incremental build — the
# intended production output.
echo ">>> full build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_scv_statement_proc\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${FULL_DS}" 2>/dev/null || true
for n in "${TABLES[@]}"; do
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${FULL_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> incremental build"
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
  "CALL \`clinvar_ingest.gks_scv_statement_proc_incremental\`(DATE '${DATE}', FALSE)"
bq mk --project_id="$PROJECT_ID" --dataset --force "${INCR_DS}" 2>/dev/null || true
for n in "${TABLES[@]}"; do
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
    "CREATE OR REPLACE TABLE \`${INCR_DS}.${n}\` CLONE \`${SCHEMA}.${n}\`"
done

echo ">>> compare"
FAIL=0
for n in "${TABLES[@]}"; do
  OUT=$(bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "CALL \`clinvar_ingest.gks_oracle_compare\`('${FULL_DS}','${INCR_DS}','${n}')" | tail -1)
  echo "  ${OUT}"
  echo "${OUT}" | awk -F, '{ if ($2+$3+$4 != 0) exit 1 }' || FAIL=1
done
if (( FAIL )); then echo "❌ ORACLE FAILED"; exit 1; fi
echo "✅ ORACLE PASSED (0 diffs on all scv_statement tables)"
