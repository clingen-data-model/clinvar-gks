SELECT * EXCEPT(proposition, hasEvidenceLines),
  REGEXP_REPLACE(proposition, r'^#/[^/]+/', '') AS proposition_id,
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(hasEvidenceLines) AS el) AS has_evidence_lines,
  TO_JSON_STRING((SELECT AS STRUCT t.*)) AS data
FROM {DATASET}.gks_dict_rcv t
