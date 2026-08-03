SELECT * EXCEPT(concepts),
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(concepts) AS el) AS concepts,
  TO_JSON_STRING((SELECT AS STRUCT t.*)) AS data
FROM {DATASET}.gks_dict_condition_set t
