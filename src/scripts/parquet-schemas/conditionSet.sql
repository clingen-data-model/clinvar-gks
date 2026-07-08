SELECT * EXCEPT(concepts),
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(concepts) AS el) AS concepts
FROM {DATASET}.gks_dict_condition_set
