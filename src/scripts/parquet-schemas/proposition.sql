-- SCV propositions. type is "CustomProposition" for the 10 custom types (the specific type is in
-- customPropositionType); standard types keep their specific type. subject/object (custom) and
-- subjectVariant/objectCondition|objectTumorType (standard) are unified into the columns below.
SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.customPropositionType') AS custom_proposition_type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(COALESCE(JSON_VALUE(value, '$.subjectVariant'), JSON_VALUE(value, '$.subject')), r'^#/[^/]+/', '') AS subject_variant_id,
  REGEXP_REPLACE(COALESCE(JSON_VALUE(value, '$.objectCondition'), JSON_VALUE(value, '$.object'), JSON_VALUE(value, '$.objectTumorType')), r'^#/[^/]+/', '') AS object_condition_id,
  COALESCE(
    JSON_VALUE(value, '$.geneContextQualifier.name'),
    (SELECT JSON_VALUE(q, '$.value.name') FROM UNNEST(JSON_QUERY_ARRAY(value, '$.qualifiers')) q WHERE JSON_VALUE(q, '$.name') = 'geneContext')
  ) AS gene_context_name,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_proposition
