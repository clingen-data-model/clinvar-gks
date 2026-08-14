#!/bin/bash
# validate-proposition-conformance.sh — structural conformance check for the reshaped
# proposition data (CustomProposition model, va-spec 1.1.0-ballot). Runs BigQuery assertions
# over the SCV+RCV+VCV proposition dicts + the condition conceptType enum for a release.
#
# This is a STRUCTURAL gate (field mutual-exclusivity, discriminator correctness, no residual
# arrays, valid conceptType enum). A full JSON-Schema validation against schema/clinvar-gks/json/*
# is a recommended follow-on (resolves clinvar + va-spec $refs; e.g. check-jsonschema over a sample).
#
# Usage: ./validate-proposition-conformance.sh <release_date> <dataset_version>   (project clingen-dev)
set -euo pipefail
DATE="${1:?release date YYYY-MM-DD}"; VER="${2:?dataset version e.g. v2_5_0}"
PROJECT="${CLOUDSDK_CORE_PROJECT:-clingen-dev}"
DS="clinvar_${DATE//-/_}_${VER}"

echo "=== proposition conformance: ${DS} ==="
bq query --project_id="$PROJECT" --use_legacy_sql=false --format=pretty --quiet "
WITH allp AS (
  SELECT value FROM \`${DS}.gks_dict_proposition\`
  UNION ALL SELECT value FROM \`${DS}.gks_dict_rcv_proposition\`
  UNION ALL SELECT value FROM \`${DS}.gks_dict_vcv_proposition\`
)
SELECT
  COUNTIF(JSON_VALUE(value,'\$.subjectVariant') IS NOT NULL AND JSON_VALUE(value,'\$.subject') IS NOT NULL) AS both_subject_BAD,
  COUNTIF( IF(JSON_VALUE(value,'\$.objectCondition') IS NOT NULL,1,0)
         + IF(JSON_VALUE(value,'\$.object') IS NOT NULL,1,0)
         + IF(JSON_VALUE(value,'\$.objectTumorType') IS NOT NULL,1,0) > 1) AS multi_object_BAD,
  COUNTIF(JSON_VALUE(value,'\$.type')='CustomProposition' AND JSON_VALUE(value,'\$.customPropositionType') IS NULL) AS custom_missing_cpt_BAD,
  COUNTIF(JSON_VALUE(value,'\$.type')!='CustomProposition' AND JSON_VALUE(value,'\$.customPropositionType') IS NOT NULL) AS std_has_cpt_BAD,
  COUNTIF(JSON_TYPE(JSON_QUERY(value,'\$.object'))='array' OR JSON_TYPE(JSON_QUERY(value,'\$.objectCondition'))='array' OR JSON_TYPE(JSON_QUERY(value,'\$.objectTumorType'))='array') AS object_array_BAD,
  COUNTIF(JSON_VALUE(value,'\$.type') LIKE 'Clinvar%') AS leftover_clinvar_type_BAD,
  COUNT(*) AS total
FROM allp"

echo "=== condition conceptType enum (must be only Condition/Phenotype/Disease/Trait/Absent) ==="
bq query --project_id="$PROJECT" --use_legacy_sql=false --format=pretty --quiet "
SELECT COUNTIF(conceptType NOT IN ('Condition','Phenotype','Disease','Trait','Absent')) AS invalid_conceptType_BAD,
       COUNT(*) AS total
FROM \`${DS}.gks_dict_condition\`"

echo "All *_BAD columns must be 0."
