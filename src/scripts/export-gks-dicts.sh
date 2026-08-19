#!/bin/bash
# export-gks-dicts.sh
# Export all GKS dictionary tables to GCS as NDJSON and/or Parquet
#
# Usage: ./export-gks-dicts.sh <dataset> <gcs_bucket> [prefix] [--parquet-only]
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clinvar-gks gks-dicts
# Example: ./export-gks-dicts.sh clinvar_2025_06_08 clinvar-gks gks-dicts --parquet-only

set -euo pipefail

# Parse positional args and flags
DATASET="${1:?Usage: $0 <dataset> <gcs_bucket> [prefix] [--parquet-only]}"
BUCKET="${2:?Usage: $0 <dataset> <gcs_bucket> [prefix] [--parquet-only]}"
PREFIX="${3:-gks-dicts}"
PARQUET_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --parquet-only) PARQUET_ONLY=true ;;
  esac
done

GCS_PATH="gs://${BUCKET}/${PREFIX}"
PARQUET_PREFIX="${PREFIX}-parquet"
GCS_PARQUET_PATH="gs://${BUCKET}/${PARQUET_PREFIX}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_DIR="${SCRIPT_DIR}/parquet-schemas"

echo "Exporting GKS dictionaries from ${DATASET}"

extract() {
  local table="$1"
  local basename="$2"
  # Use wildcard sharding to handle large tables
  # e.g., allele.ndjson.gz -> allele-*.ndjson.gz
  local sharded="${basename%.ndjson.gz}-*.ndjson.gz"
  echo "  Exporting ${table} -> ${sharded}"
  bq extract --destination_format NEWLINE_DELIMITED_JSON --compression GZIP \
    "${DATASET}.${table}" "${GCS_PATH}/${sharded}"
}

extract_parquet() {
  # Raw Parquet export via bq extract — for tables with no FK columns to clean.
  local table="$1"
  local basename="$2"
  local sharded="${basename%.parquet}-*.parquet"
  echo "  Exporting ${table} -> ${sharded} (Parquet)"
  bq extract --destination_format PARQUET --compression SNAPPY \
    "${DATASET}.${table}" "${GCS_PARQUET_PATH}/${sharded}"
}

extract_parquet_typed() {
  # Export via EXPORT DATA using a SQL schema file from parquet-schemas/.
  # Schema files define typed columns, FK cleanup, and data column.
  # The {DATASET} placeholder is substituted with the target dataset.
  local basename="$1"
  local sql_file="$2"
  local sharded="${basename%.parquet}-*.parquet"
  local schema_path="${SCHEMA_DIR}/${sql_file}"
  if [[ ! -f "${schema_path}" ]]; then
    echo "  ERROR: Schema file not found: ${schema_path}" >&2
    return 1
  fi
  local sql
  sql=$(<"${schema_path}")
  sql="${sql//\{DATASET\}/${DATASET}}"
  echo "  Exporting ${sql_file%.sql} -> ${sharded} (Parquet via EXPORT DATA)"
  bq query --use_legacy_sql=false --nouse_cache \
    "EXPORT DATA OPTIONS(
      uri='${GCS_PARQUET_PATH}/${sharded}',
      format='PARQUET',
      compression='SNAPPY',
      overwrite=true
    ) AS
    ${sql}"
}

# Proposition delivery-group split (Phase 2): the 3 per-level proposition dicts are delivered as 4
# datatype-homogeneous sections. Group is keyed on the raw gks type (custom rows carry it in
# customPropositionType, standard rows in type) — the SAME canonical mapping the statement procs use.
# Quoted heredoc so nothing ($., single quotes) expands in bash.
PROP_GROUP_CASE=$(cat <<'SQL'
CASE
  WHEN COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) LIKE 'Clinvar%' THEN 'varcustom'
  WHEN COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) = 'VariantOncogenicityProposition' THEN 'vartumor'
  WHEN COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
  WHEN COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) IN
    ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition','VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
  ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type'))))
END
SQL
)

# Extension value collapse (conformance): the pipeline stores typed extension values as `value_<type>`
# (value_string, value_boolean, value_submitted_condition, ...) so gks_json_proc can nullify-by-type and
# drop them; the va-spec bundle wants a single polymorphic `value`. This recursive JS UDF renames the one
# populated `value_*` key (JSON_STRIP_NULLS already dropped the rest) to `value` in every extension object
# (any object with a `name` sibling), at any nesting depth. The gks_dict_* tables keep `value_*`; only the
# bundle export is collapsed. Prepend ${COLLAPSE_UDF} to any query that uses collapse_ext_values(...).
COLLAPSE_UDF=$(cat <<'SQL'
CREATE TEMP FUNCTION collapse_ext_values(j STRING)
RETURNS STRING
LANGUAGE js AS r"""
  if (j == null) return null;
  function walk(o){
    if (Array.isArray(o)){ for (const x of o) walk(x); return; }
    if (o && typeof o === "object"){
      if ("name" in o){ for (const k of Object.keys(o)){ if (k.indexOf("value_")===0){ o["value"]=o[k]; delete o[k]; } } }
      for (const k of Object.keys(o)) walk(o[k]);
    }
  }
  const p = JSON.parse(j); walk(p); return JSON.stringify(p);
""";
SQL
)

export_proposition_group_ndjson() {
  local group="$1"
  local sharded="${group}-proposition-*.ndjson.gz"
  echo "  Exporting proposition group ${group} -> ${sharded} (NDJSON via EXPORT DATA)"
  bq query --use_legacy_sql=false --nouse_cache \
    "${COLLAPSE_UDF}
    EXPORT DATA OPTIONS(
      uri='${GCS_PATH}/${sharded}',
      format='JSON',
      compression='GZIP',
      overwrite=true
    ) AS
    SELECT key, SAFE.PARSE_JSON(collapse_ext_values(TO_JSON_STRING(value))) AS value FROM (
      SELECT key, value, ${PROP_GROUP_CASE} AS _grp FROM (
        SELECT key, value FROM \`${DATASET}.gks_dict_proposition\`
        UNION ALL SELECT key, value FROM \`${DATASET}.gks_dict_rcv_proposition\`
        UNION ALL SELECT key, value FROM \`${DATASET}.gks_dict_vcv_proposition\`
      )
    ) WHERE _grp = '${group}'"
}

# NDJSON export of a passthrough dict table with its `extensions` column value-collapsed for the bundle.
export_ndjson_ext_collapse() {
  local table="$1"
  local basename="$2"
  local sharded="${basename%.ndjson.gz}-*.ndjson.gz"
  echo "  Exporting ${table} -> ${sharded} (NDJSON via EXPORT DATA, extensions collapsed)"
  bq query --use_legacy_sql=false --nouse_cache \
    "${COLLAPSE_UDF}
    EXPORT DATA OPTIONS(
      uri='${GCS_PATH}/${sharded}',
      format='JSON',
      compression='GZIP',
      overwrite=true
    ) AS
    SELECT * REPLACE(
      SAFE.PARSE_JSON(collapse_ext_values(
        TO_JSON_STRING(JSON_STRIP_NULLS(TO_JSON(extensions), remove_empty => TRUE)))) AS extensions)
    FROM \`${DATASET}.${table}\`"
}

if ! $PARQUET_ONLY; then
  echo "Exporting NDJSON files to ${GCS_PATH}"

  # Cat-VRS dictionaries (from gks_catvar_proc)
  extract gks_dict_sequence_reference sequenceReference.ndjson.gz
  extract gks_dict_location location.ndjson.gz
  extract gks_dict_allele allele.ndjson.gz
  extract gks_dict_copy_number_count copyNumberCount.ndjson.gz
  extract gks_dict_copy_number_change copyNumberChange.ndjson.gz
  extract gks_dict_gene gene.ndjson.gz
  extract gks_dict_variation variation.ndjson.gz

  # Condition dictionaries (from gks_scv_condition_proc)
  extract gks_dict_condition condition.ndjson.gz
  extract gks_dict_condition_set conditionSet.ndjson.gz

  # SCV dictionaries (from gks_scv_statement_proc)
  extract gks_dict_submitter submitter.ndjson.gz
  export_ndjson_ext_collapse gks_dict_evidence_line evidenceLine.ndjson.gz

  # Proposition delivery groups (Phase 2): the 3 per-level proposition dicts are split into 4
  # datatype-homogeneous sections by the canonical group mapping.
  export_proposition_group_ndjson varcond
  export_proposition_group_ndjson vartumor
  export_proposition_group_ndjson vartherapy
  export_proposition_group_ndjson varcustom

  # VCV/RCV evidence line dictionaries (propositions handled by the group split above)
  extract gks_dict_vcv_evidence_line vcv_evidenceLine.ndjson.gz
  extract gks_dict_rcv_evidence_line rcv_evidenceLine.ndjson.gz

  # Statement outputs
  export_ndjson_ext_collapse gks_dict_scv scv.ndjson.gz
  extract gks_dict_vcv vcv.ndjson.gz
  extract gks_dict_rcv rcv.ndjson.gz
fi

echo ""
echo "Exporting Parquet files to ${GCS_PARQUET_PATH}"

# Cat-VRS (typed columns extracted from KV JSON values)
extract_parquet_typed sequenceReference.parquet sequenceReference.sql
extract_parquet_typed location.parquet location.sql
extract_parquet_typed allele.parquet allele.sql
extract_parquet_typed copyNumberCount.parquet copyNumberCount.sql
extract_parquet_typed copyNumberChange.parquet copyNumberChange.sql
extract_parquet_typed gene.parquet gene.sql
extract_parquet_typed variation.parquet variation.sql

# Conditions
extract_parquet gks_dict_condition condition.parquet
extract_parquet_typed conditionSet.parquet conditionSet.sql

# SCV
extract_parquet_typed submitter.parquet submitter.sql
extract_parquet_typed evidenceLine.parquet evidenceLine.sql

# Proposition delivery groups (Phase 2): 4 typed group tables replace the 3 per-level tables.
extract_parquet_typed varcond-proposition.parquet varcond-proposition.sql
extract_parquet_typed vartumor-proposition.parquet vartumor-proposition.sql
extract_parquet_typed vartherapy-proposition.parquet vartherapy-proposition.sql
extract_parquet_typed varcustom-proposition.parquet varcustom-proposition.sql

# VCV/RCV evidence lines
extract_parquet_typed vcv_evidenceLine.parquet vcv_evidenceLine.sql
extract_parquet_typed rcv_evidenceLine.parquet rcv_evidenceLine.sql

# Statements
extract_parquet_typed scv.parquet scv.sql
extract_parquet_typed vcv.parquet vcv.sql
extract_parquet_typed rcv.parquet rcv.sql

echo "Done."
if ! $PARQUET_ONLY; then
  echo "  NDJSON:  ${GCS_PATH}/"
fi
echo "  Parquet: ${GCS_PARQUET_PATH}/"
