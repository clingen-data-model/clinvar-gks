SELECT
  key AS id,
  JSON_VALUE(value, '$.conceptType') AS concept_type,
  JSON_VALUE(value, '$.name') AS name,
  TO_JSON_STRING(value) AS data
FROM {DATASET}.gks_dict_gene
