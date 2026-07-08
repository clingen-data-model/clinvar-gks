SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.digest') AS digest,
  CAST(JSON_VALUE(value, '$.start') AS INT64) AS start,
  CAST(JSON_VALUE(value, '$.end') AS INT64) AS end,
  REGEXP_REPLACE(JSON_VALUE(value, '$.sequenceReference'), r'^#/[^/]+/', '') AS sequence_reference_id,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_location
