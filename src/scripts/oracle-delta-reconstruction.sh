#!/bin/bash
# oracle-delta-reconstruction.sh — prove the published delta reconstructs the full set.
# For each tracked dict: recon = (baseline WHERE pk NOT IN deletes AND pk NOT IN delta-keys)
#                                UNION ALL delta_<T>;  compare recon vs compare-release full.
# Requires gks_change_log + gks_delta_build to have run for COMPARE.
# Usage: ./oracle-delta-reconstruction.sh <baseline_date> <compare_date> <version>
set -euo pipefail
BASE="${1:?baseline date}"; COMP="${2:?compare date}"; VER="${3:?version}"
PROJECT="${CLOUDSDK_CORE_PROJECT:-clingen-dev}"
BDS="clinvar_${BASE//-/_}_${VER}"
CDS="clinvar_${COMP//-/_}_${VER}"
RECON="clinvar_${COMP//-/_}_${VER}_recon"

# Drop the scratch recon dataset on ANY exit (including a mid-loop bq failure), not just the
# happy path — otherwise set -e would abort before cleanup and leak the dataset.
trap 'bq --project_id="$PROJECT" rm -r -f -d "$RECON" >/dev/null 2>&1 || true' EXIT

bq --project_id="$PROJECT" mk -f --dataset "$RECON" >/dev/null 2>&1 || true

# base dict table + pk expr (as "table pk" pairs — indexed array works on bash 3.2/macOS;
# associative arrays do not). Merged sections listed per underlying table.
# gks_scv_condition_sets is tracked+delta'd but NOT a published bundle section -> excluded.
PAIRS=(
  "gks_dict_sequence_reference key" "gks_dict_location key" "gks_dict_allele key"
  "gks_dict_copy_number_count key" "gks_dict_copy_number_change key" "gks_dict_gene key"
  "gks_dict_submitter key" "gks_dict_proposition key" "gks_dict_vcv_proposition key"
  "gks_dict_rcv_proposition key"
  "gks_dict_variation id" "gks_dict_condition id" "gks_dict_condition_set id"
  "gks_dict_evidence_line id" "gks_dict_vcv_evidence_line id" "gks_dict_rcv_evidence_line id"
  "gks_dict_scv id" "gks_dict_vcv id" "gks_dict_rcv id"
)

FAIL=0
for pair in "${PAIRS[@]}"; do
  T="${pair%% *}"; K="${pair##* }"
  # reconstruct into RECON.<T>: carry forward baseline rows that are neither deleted nor in
  # the delta (the delta supplies A and the NEW content of U), then UNION the delta payload.
  bq --project_id="$PROJECT" query --quiet --use_legacy_sql=false "
    CREATE OR REPLACE TABLE \`${RECON}.${T}\` AS
    SELECT * FROM \`${BDS}.${T}\` b
    WHERE CAST(b.${K} AS STRING) NOT IN (
            SELECT pk FROM \`${CDS}.gks_change_log\` WHERE table_name='${T}' AND change_type='D')
      AND CAST(b.${K} AS STRING) NOT IN (
            SELECT CAST(${K} AS STRING) FROM \`${CDS}.delta_${T}\`)
    UNION ALL
    SELECT * FROM \`${CDS}.delta_${T}\`
  " >/dev/null
  # compare recon vs compare full via the 3-arg canonical multiset oracle (PROCEDURE -> CALL).
  # --format=csv last line = data row: table_name,a_only,b_only,canonical_diffs.
  OUT=$(bq --project_id="$PROJECT" query --quiet --use_legacy_sql=false --format=csv \
    "CALL \`clinvar_ingest.gks_oracle_compare\`('${RECON}','${CDS}','${T}')" | tail -1)
  echo "  ${OUT}"
  echo "${OUT}" | awk -F, '{ if ($2+$3+$4 != 0) exit 1 }' || { echo "  MISMATCH on ${T}"; FAIL=1; }
done

if (( FAIL )); then echo "FAILED delta reconstruction oracle"; exit 1; fi
echo "PASSED delta reconstruction oracle: all sections 0,0,0"
