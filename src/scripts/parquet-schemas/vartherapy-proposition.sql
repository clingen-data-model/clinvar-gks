-- G3 variant×therapy standard propositions: VariantTherapeuticResponse (SCV somatic target props only).
-- Unions the SCV/RCV/VCV proposition dicts, filtered to the vartherapy delivery group. subjectVariant →
-- objectTherapy (a Therapy or TherapyGroup), with a conditionQualifier.
SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(JSON_VALUE(value, '$.subjectVariant'), r'^#/[^/]+/', '') AS subject_variant_id,
  REGEXP_REPLACE(JSON_VALUE(value, '$.conditionQualifier'), r'^#/[^/]+/', '') AS condition_qualifier_id,
  TO_JSON_STRING(JSON_QUERY(value, '$.objectTherapy')) AS object_therapy,
  JSON_VALUE(value, '$.geneContextQualifier.name') AS gene_context_name,
  TO_JSON_STRING(value) AS data
FROM (
  SELECT key, value FROM `{DATASET}.gks_dict_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_rcv_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_vcv_proposition`
)
WHERE COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) = 'VariantTherapeuticResponseProposition'
