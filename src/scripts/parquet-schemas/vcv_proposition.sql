-- VCV propositions: objectCondition is an array of #/condition/ and #/conditionSet/ pointer strings.
SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(JSON_VALUE(value, '$.subjectVariant'), r'^#/[^/]+/', '') AS subject_variant_id,
  ARRAY(
    SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '')
    FROM UNNEST(JSON_VALUE_ARRAY(value, '$.objectCondition')) AS el
  ) AS object_conditions,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_vcv_proposition
