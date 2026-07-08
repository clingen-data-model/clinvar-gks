SELECT * EXCEPT(evidenceItems),
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(evidenceItems) AS el) AS evidence_items
FROM {DATASET}.gks_dict_vcv_evidence_line
