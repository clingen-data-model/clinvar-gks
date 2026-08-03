SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.digest') AS digest,
  JSON_VALUE(value, '$.copyChange') AS copy_change,
  REGEXP_REPLACE(JSON_VALUE(value, '$.location'), r'^#/[^/]+/', '') AS location_id,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_copy_number_change
