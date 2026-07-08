SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.digest') AS digest,
  CAST(JSON_VALUE(value, '$.copies') AS INT64) AS copies,
  REGEXP_REPLACE(JSON_VALUE(value, '$.location'), r'^#/[^/]+/', '') AS location_id,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_copy_number_count
