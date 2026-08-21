SELECT * EXCEPT(proposition),
  REGEXP_REPLACE(proposition, r'^#/[^/]+/', '') AS proposition_id,
  collapse_ext_values(TO_JSON_STRING(JSON_STRIP_NULLS(TO_JSON((SELECT AS STRUCT t.*)), remove_empty => TRUE))) AS data
FROM {DATASET}.gks_dict_evidence_line t
