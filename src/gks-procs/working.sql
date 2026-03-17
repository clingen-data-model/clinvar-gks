SELECT
  ss.id,
  ss.submitter_id,
  ss.last_evaluated,
  ss.submission_date,
  ss.variation_id,
  ss.statement_type,
  ss.original_proposition_type,
  ss.rank,
  ss.significance,
  ss.classif_type,
  cct.label AS classif_label,
  cct.original_description_order
FROM `%s.scv_summary` AS ss
LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` AS cct
ON
  cct.code = ss.classif_type
  AND
  cct.original_proposition_type = ss.original_proposition_type