SELECT * EXCEPT(proposition),
  REGEXP_REPLACE(proposition, r'^#/[^/]+/', '') AS proposition_id,
  TO_JSON_STRING((SELECT AS STRUCT t.*)) AS data
FROM {DATASET}.gks_dict_evidence_line t
