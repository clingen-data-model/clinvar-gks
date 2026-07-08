SELECT * EXCEPT(proposition),
  REGEXP_REPLACE(proposition, r'^#/[^/]+/', '') AS proposition_id
FROM {DATASET}.gks_dict_evidence_line
