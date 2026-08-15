-- G4 variant×condition custom propositions: the 10 Clinvar* CustomProposition types (specific type in
-- customPropositionType). Unions the SCV/RCV/VCV proposition dicts, filtered to the varcustom delivery
-- group. subject → object; generic qualifiers[] name/value array (SCV only — null for RCV/VCV rows).
SELECT
  key AS id,
  JSON_VALUE(value, '$.customPropositionType') AS custom_proposition_type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(JSON_VALUE(value, '$.subject'), r'^#/[^/]+/', '') AS subject_id,
  REGEXP_REPLACE(JSON_VALUE(value, '$.object'), r'^#/[^/]+/', '') AS object_id,
  (SELECT JSON_VALUE(q, '$.value.name') FROM UNNEST(JSON_QUERY_ARRAY(value, '$.qualifiers')) q
    WHERE JSON_VALUE(q, '$.name') = 'geneContext') AS gene_context_name,
  TO_JSON_STRING(JSON_QUERY(value, '$.qualifiers')) AS qualifiers,
  TO_JSON_STRING(value) AS data
FROM (
  SELECT key, value FROM `{DATASET}.gks_dict_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_rcv_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_vcv_proposition`
)
WHERE COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) LIKE 'Clinvar%'
