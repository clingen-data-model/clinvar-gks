SELECT * EXCEPT(evidenceItems),
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(evidenceItems) AS el) AS evidence_items
FROM {DATASET}.gks_dict_rcv_evidence_line
