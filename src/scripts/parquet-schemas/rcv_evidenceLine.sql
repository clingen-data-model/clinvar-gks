SELECT * EXCEPT(evidenceItems),
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(evidenceItems) AS el) AS evidence_items,
  TO_JSON_STRING((SELECT AS STRUCT t.*)) AS data
FROM {DATASET}.gks_dict_rcv_evidence_line t
