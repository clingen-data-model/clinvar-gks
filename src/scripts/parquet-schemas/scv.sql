SELECT * EXCEPT(proposition, hasEvidenceLines, contributions),
  REGEXP_REPLACE(proposition, r'^#/[^/]+/', '') AS proposition_id,
  ARRAY(
    SELECT AS STRUCT c.type, REGEXP_REPLACE(c.contributor, r'^#/[^/]+/', '') AS contributor, c.date, c.activityType
    FROM UNNEST(contributions) AS c
  ) AS contributions,
  ARRAY(SELECT REGEXP_REPLACE(el, r'^#/[^/]+/', '') FROM UNNEST(hasEvidenceLines) AS el) AS has_evidence_lines,
  TO_JSON_STRING((SELECT AS STRUCT t.*)) AS data
FROM {DATASET}.gks_dict_scv t
