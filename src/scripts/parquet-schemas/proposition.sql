-- SCV propositions: objectCondition is a single #/condition/ or #/conditionSet/ pointer string.
SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(JSON_VALUE(value, '$.subjectVariant'), r'^#/[^/]+/', '') AS subject_variant_id,
  REGEXP_REPLACE(JSON_VALUE(value, '$.objectCondition'), r'^#/[^/]+/', '') AS object_condition,
  JSON_VALUE(value, '$.geneContextQualifier.name') AS gene_context_name,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_proposition
