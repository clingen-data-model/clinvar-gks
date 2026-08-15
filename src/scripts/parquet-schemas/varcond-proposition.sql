-- G1 variant×condition standard propositions: VariantPathogenicity, VariantClinicalSignificance,
-- VariantDiagnostic, VariantPrognostic. Unions the SCV/RCV/VCV proposition dicts, filtered to the
-- varcond delivery group. subjectVariant → objectCondition; typed germline qualifiers (SCV only —
-- null for RCV/VCV rows).
SELECT
  key AS id,
  JSON_VALUE(value, '$.type') AS type,
  JSON_VALUE(value, '$.predicate') AS predicate,
  REGEXP_REPLACE(JSON_VALUE(value, '$.subjectVariant'), r'^#/[^/]+/', '') AS subject_variant_id,
  REGEXP_REPLACE(JSON_VALUE(value, '$.objectCondition'), r'^#/[^/]+/', '') AS object_condition_id,
  JSON_VALUE(value, '$.geneContextQualifier.name') AS gene_context_name,
  JSON_VALUE(value, '$.modeOfInheritanceQualifier.name') AS mode_of_inheritance,
  JSON_VALUE(value, '$.penetranceQualifier.name') AS penetrance,
  TO_JSON_STRING(value) AS data
FROM (
  SELECT key, value FROM `{DATASET}.gks_dict_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_rcv_proposition`
  UNION ALL SELECT key, value FROM `{DATASET}.gks_dict_vcv_proposition`
)
WHERE COALESCE(JSON_VALUE(value, '$.customPropositionType'), JSON_VALUE(value, '$.type')) IN (
  'VariantPathogenicityProposition', 'VariantClinicalSignificanceProposition',
  'VariantDiagnosticProposition', 'VariantPrognosticProposition')
