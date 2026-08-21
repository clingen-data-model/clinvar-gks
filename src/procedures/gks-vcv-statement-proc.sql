-------------------------------------------------------------------------------
-- gks_vcv_statement — build the three VCV statement outputs from a release:
--   gks_dict_vcv_evidence_line  (from the 3 vcv agg tables)
--   gks_dict_vcv_proposition    (from the 3 vcv agg tables; objectCondition inline)
--   gks_dict_vcv                (UNION of the 3 per-layer statement temps)
--
-- Three entry points:
--   gks_vcv_statement_proc(on_date, debug)              -> full rebuild (unchanged behavior)
--   gks_vcv_statement_proc_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   gks_vcv_statement_build(on_date, debug, incremental) -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-08-incremental-gks-
-- downstream-plan-3-rcv-vcv.md, Chunk 5 — the VCV mirror of Chunk 3):
--   All three outputs are per-VCV-parent. They are built FROM the three vcv agg tables
--   (gks_vcv_classification_agg / _priority_agg / _aggregate_contribution — each carries
--   vcv_accession). Only the VCV parents impacted by this release are recomputed; the rest
--   are carried forward from the baseline release. The impacted-parent set is the persistent
--   {S} table vcv_impacted_ids produced by gks_rcvvcv_changed, the SAME set that drove the
--   agg tables (Chunk 4) — so the agg rows this proc reads for an unimpacted VCV are
--   byte-identical to baseline, and the deterministic statement transform reproduces the
--   baseline statement rows exactly.
--
--   {PFILTER} restricts each output's read of the agg tables to impacted VCVs in incremental
--   mode ('' in full). The per-layer statement temps (which feed ONLY gks_dict_vcv) are
--   filtered too, so gks_dict_vcv's stage is impacted-only. In incremental mode each output
--   is staged to {P}.stg_* and then UNION-CTAS-merged into {S}: carry forward the baseline
--   rows whose parent VCV is NOT impacted AND still present in {S}.variation_archive (so a
--   removed VCV is not resurrected), UNION ALL the freshly recomputed impacted rows.
--
--   pk-parse (the outputs have NO vcv_accession column — they UNION statement temps that
--   carry only id/type/…): the parent accession is recovered from the pk. VCV accessions
--   contain no '.' or '-'.
--     gks_dict_vcv_evidence_line: id = '{VCV}.{ver}-…'  -> SPLIT(id, '.')[OFFSET(0)]
--     gks_dict_vcv:               id = '{VCV}.{ver}-…'  -> SPLIT(id, '.')[OFFSET(0)]
--     gks_dict_vcv_proposition:   key = '{VCV}-…'       -> SPLIT(key, '-')[OFFSET(0)]
--
--   Determinism: this proc has NO group-by / ANY_VALUE over the agg rows — the outputs are
--   row-wise projections of the (already-deterministic) agg tables, and the array
--   projections (ARRAY(SELECT … FROM UNNEST(…))) preserve the stored array order. No
--   determinism fix was needed for carry-forward to hold.
--
--   Pointer vs inline: subjectVariant (#/variation), proposition (#/proposition),
--   evidenceItems (#/scv, #/vcv) and hasEvidenceLines (#/evidenceLine) are all pointers.
--   The proposition's objectCondition is the INLINE agg.unique_conditions array (already
--   materialized deterministically in the agg table). This is safe under carry-forward: an
--   unimpacted VCV reads byte-identical agg rows.
--
--   Version-invalidation: the guard falls back to a full rebuild when the baseline is
--   missing/incomplete, the impacted set / required inputs are absent, or the pipeline
--   gate_key mismatches. Call the *_incremental wrapper only when carry-forward is safe.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  DECLARE query_classification STRING;
  DECLARE query_priority STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE dict_vcv_evidence_line_query STRING;
  DECLARE dict_vcv_proposition_query STRING;
  DECLARE query_vcv_synthetic_condsets STRING;
  DECLARE query_vcv_pre STRING;
  DECLARE query_merge STRING;
  DECLARE temp_create STRING;

  -- incremental control / fallback guard
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;
  DECLARE gate_ok BOOL DEFAULT FALSE;
  DECLARE stamps_exist BOOL DEFAULT FALSE;

  -- mode-dependent fragments ('' / real-table targets in full mode)
  DECLARE pf_agg STRING;       -- impacted-VCV filter on `agg.vcv_accession`
  DECLARE el_head STRING;      -- gks_dict_vcv_evidence_line target (real table vs stg temp)
  DECLARE prop_head STRING;    -- gks_dict_vcv_proposition target
  DECLARE vcv_head STRING;     -- gks_dict_vcv target

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (SELECT s.schema_name, s.prev_release_date FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO

    -----------------------------------------------------------------------
    -- Resolve baseline + fallback guard: incremental is only safe when the prior
    -- release exists with all three statement outputs, the current release has the
    -- impacted-parent set + the agg tables (and variation_archive for removed-parent
    -- exclusion), AND the pipeline gate_key matches the baseline. Otherwise fall back to full.
    -----------------------------------------------------------------------
    SET eff_incremental = FALSE;
    SET baseline_schema = NULL;
    SET base_ok = FALSE;
    SET diff_ok = FALSE;
    SET gate_ok = FALSE;
    SET stamps_exist = FALSE;

    IF incremental AND rec.prev_release_date IS NOT NULL THEN
      SET baseline_schema = (
        SELECT s2.schema_name FROM `clinvar_ingest.schema_on`(rec.prev_release_date) AS s2 LIMIT 1
      );
    END IF;

    IF baseline_schema IS NOT NULL THEN
      -- baseline must have all 3 statement outputs
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('gks_dict_vcv_evidence_line','gks_dict_vcv_proposition',
                  'gks_dict_vcv')) = 3
      """, baseline_schema) INTO base_ok;

      -- current release must have the impacted-parent set, the three agg tables it reads,
      -- and variation_archive (removed-VCV exclusion in the merge).
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('vcv_impacted_ids','gks_vcv_classification_agg',
                  'gks_vcv_priority_agg','gks_vcv_aggregate_contribution','variation_archive')) = 5
      """, rec.schema_name) INTO diff_ok;

      -- version gate — TWO statements. BigQuery resolves table refs at analysis time and
      -- does NOT short-circuit that resolution, so a single combined statement referencing
      -- {base}.gks_pipeline_version would ERROR (not return FALSE) when a pre-feature
      -- baseline lacks the stamp. First confirm both stamps exist; only then compare gate_key.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT
          (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
          AND
          (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES` WHERE table_name='gks_pipeline_version')=1
      """, baseline_schema, rec.schema_name) INTO stamps_exist;
      IF stamps_exist THEN
        EXECUTE IMMEDIATE FORMAT("""
          SELECT (SELECT gate_key FROM `%s.gks_pipeline_version`)
               = (SELECT gate_key FROM `%s.gks_pipeline_version`)
        """, baseline_schema, rec.schema_name) INTO gate_ok;
        -- an empty stamp table yields NULL; NULL-strict so the guard falls back to full
        SET gate_ok = IFNULL(gate_ok, FALSE);
      END IF;

      SET eff_incremental = base_ok AND diff_ok AND gate_ok;
    END IF;

    -----------------------------------------------------------------------
    -- Mode-dependent fragments. In full mode all filters are empty and each output
    -- writes straight to its {S} table. In incremental mode reads of the agg tables are
    -- filtered to impacted VCVs, each output is staged to {P}.stg_*, and the merge carries
    -- forward the unimpacted baseline rows.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET pf_agg   = 'AND agg.vcv_accession IN (SELECT vcv_accession FROM `{S}.vcv_impacted_ids`)';
      SET el_head   = '{CT} `{P}.stg_gks_dict_vcv_evidence_line`';
      SET prop_head = '{CT} `{P}.stg_gks_dict_vcv_proposition`';
      SET vcv_head  = '{CT} `{P}.stg_gks_dict_vcv`';
    ELSE
      SET pf_agg   = '';
      SET el_head   = 'CREATE OR REPLACE TABLE `{S}.gks_dict_vcv_evidence_line`';
      SET prop_head = 'CREATE OR REPLACE TABLE `{S}.gks_dict_vcv_proposition`';
      SET vcv_head  = 'CREATE OR REPLACE TABLE `{S}.gks_dict_vcv`';
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_vcv_classification_statements', 'temp_vcv_priority_statements',
        'temp_vcv_agg_contribution_statements',
        'stg_gks_dict_vcv_evidence_line', 'stg_gks_dict_vcv_proposition', 'stg_gks_dict_vcv'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: CLASSIFICATION GROUPING
    -- All submission levels use classification (no PGEP
    -- per-SCV expansion). {PFILTER} restricts to impacted VCVs in incremental mode.
    -------------------------------------------------------------------------
    SET query_classification = REPLACE("""
      {CT} `{P}.temp_vcv_classification_statements` AS
      SELECT
        agg.id,

        'Statement' AS type,

        IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
          agg.scv_direction,
          CASE
            WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
            WHEN agg.actual_agg_classif_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
            WHEN agg.actual_agg_classif_label = 'Uncertain significance' THEN 'neutral'
            WHEN agg.actual_agg_classif_label LIKE 'Conflicting%%' THEN 'neutral'
            ELSE 'supports'
          END
        ) AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          IF(ARRAY_LENGTH(agg.full_scv_ids) = 1,
            agg.scv_strength_name,
            CASE
              WHEN agg.actual_agg_classif_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
              WHEN agg.actual_agg_classif_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
              WHEN agg.actual_agg_classif_label LIKE 'Tier I%' THEN 'Strong'
              WHEN agg.actual_agg_classif_label LIKE 'Tier II%' THEN 'Potential'
              WHEN agg.actual_agg_classif_label LIKE 'Tier IV%' THEN 'Likely'
              ELSE CAST(NULL AS STRING)
            END
          ) AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, sl.label AS name) AS confidence,

        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.actual_agg_classif_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        [FORMAT('#/evidenceLine/%s.contributing', agg.id)] AS hasEvidenceLines

      FROM `{S}.gks_vcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      WHERE TRUE
        {PFILTER}
    """, '{PFILTER}', pf_agg);
    SET query_classification = REPLACE(query_classification, '{S}', rec.schema_name);
    SET query_classification = REPLACE(query_classification, '{CT}', temp_create);
    SET query_classification = REPLACE(query_classification, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_classification;


    -------------------------------------------------------------------------
    -- GROUPING LAYER: PRIORITY GROUPING (Somatic only)
    -------------------------------------------------------------------------
    SET query_priority = REPLACE("""
      {CT} `{P}.temp_vcv_priority_statements` AS
      SELECT
        agg.id,

        'Statement' AS type,

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
          WHEN agg.agg_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
          WHEN agg.agg_label = 'Uncertain significance' THEN 'neutral'
          WHEN agg.agg_label LIKE 'Conflicting%%' THEN 'neutral'
          ELSE 'supports'
        END AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          CASE
            WHEN agg.agg_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
            WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
            WHEN agg.agg_label LIKE 'Tier I%' THEN 'Strong'
            WHEN agg.agg_label LIKE 'Tier II%' THEN 'Potential'
            WHEN agg.agg_label LIKE 'Tier IV%' THEN 'Likely'
            ELSE CAST(NULL AS STRING)
          END AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, sl.label AS name) AS confidence,

        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        ARRAY_CONCAT(
          [FORMAT('#/evidenceLine/%s.contributing', agg.id)],
          IF(ARRAY_LENGTH(agg.non_contributing_statement_ids) > 0,
            [FORMAT('#/evidenceLine/%s.non-contributing', agg.id)],
            []
          )
        ) AS hasEvidenceLines

      FROM `{S}.gks_vcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      WHERE TRUE
        {PFILTER}
    """, '{PFILTER}', pf_agg);
    SET query_priority = REPLACE(query_priority, '{S}', rec.schema_name);
    SET query_priority = REPLACE(query_priority, '{CT}', temp_create);
    SET query_priority = REPLACE(query_priority, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_priority;

    -------------------------------------------------------------------------
    -- AGGREGATE CONTRIBUTION LAYER
    -------------------------------------------------------------------------
    SET query_agg_contribution = REPLACE("""
      {CT} `{P}.temp_vcv_agg_contribution_statements` AS
      SELECT
        agg.id,

        'Statement' AS type,

        CASE
          WHEN agg.agg_label IN ('Pathogenic', 'Likely pathogenic', 'Pathogenic/Likely pathogenic') THEN 'supports'
          WHEN agg.agg_label IN ('Benign', 'Likely benign', 'Benign/Likely benign') THEN 'disputes'
          WHEN agg.agg_label = 'Uncertain significance' THEN 'neutral'
          WHEN agg.agg_label LIKE 'Conflicting%%' THEN 'neutral'
          ELSE 'supports'
        END AS direction,

        STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          CASE
            WHEN agg.agg_label IN ('Pathogenic', 'Benign', 'Oncogenic') THEN 'Definitive'
            WHEN agg.agg_label IN ('Likely pathogenic', 'Likely benign', 'Likely Oncogenic') THEN 'Likely'
            WHEN agg.agg_label LIKE 'Tier I%' THEN 'Strong'
            WHEN agg.agg_label LIKE 'Tier II%' THEN 'Potential'
            WHEN agg.agg_label LIKE 'Tier IV%' THEN 'Likely'
            ELSE CAST(NULL AS STRING)
          END AS name
        ) AS strength,

        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, agg.contributing_submission_level_label AS name) AS confidence,

        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          agg.agg_label AS name,
          IF(
            agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
            [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
            CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
          ) AS extensions
        ) AS classification,

        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN cpt.gks_type LIKE 'Clinvar%' THEN 'varcustom'
            WHEN cpt.gks_type = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN cpt.gks_type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN cpt.gks_type IN ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
                                  'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', cpt.gks_type))
          END,
          agg.prop_id) AS proposition,

        IF(
          agg.aggregate_review_status IS NOT NULL,
          [STRUCT('clinvarReviewStatus' AS name, agg.aggregate_review_status AS value)],
          CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
        ) AS extensions,

        ARRAY_CONCAT(
          [FORMAT('#/evidenceLine/%s.contributing', agg.id)],
          IF(agg.non_contributing_details IS NOT NULL AND ARRAY_LENGTH(agg.non_contributing_details) > 0,
            [FORMAT('#/evidenceLine/%s.non-contributing', agg.id)],
            []
          )
        ) AS hasEvidenceLines

      FROM `{S}.gks_vcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      WHERE TRUE
        {PFILTER}
    """, '{PFILTER}', pf_agg);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -------------------------------------------------------------------------
    -- Dictionary table - VCV evidence lines
    -- Extracts evidence lines from all 3 statement layers into flat rows.
    -- Classification: 1 Contributing evidence line per statement (SCV items)
    -- Priority/Aggregate: Contributing + optional Non-contributing (VCV items)
    -- {EL_HEAD}: real table in full mode, {P}.stg_* in incremental. {PFILTER} restricts
    -- each arm to impacted VCVs (accession carried in agg.vcv_accession).
    -------------------------------------------------------------------------
    SET dict_vcv_evidence_line_query = REPLACE("""
      {EL_HEAD}
      AS
      -- Classification layer: always 1 Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/scv/clinvar.submission:%s', scv_id)
          FROM UNNEST(agg.full_scv_ids) AS scv_id
        ) AS evidenceItems
      FROM `{S}.gks_vcv_classification_agg` agg
      WHERE TRUE
        {PFILTER}

      UNION ALL

      -- Priority layer: Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/vcv/%s', stmt_id)
          FROM UNNEST(agg.contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_vcv_priority_agg` agg
      WHERE TRUE
        {PFILTER}

      UNION ALL

      -- Priority layer: Non-contributing evidence line (only when items exist)
      SELECT
        FORMAT('%s.non-contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'neutral' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Non-contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/vcv/%s', stmt_id)
          FROM UNNEST(agg.non_contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_vcv_priority_agg` agg
      WHERE ARRAY_LENGTH(agg.non_contributing_statement_ids) > 0
        {PFILTER}

      UNION ALL

      -- Aggregate layer: Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        [FORMAT('#/vcv/%s', agg.contributing_layer_id)] AS evidenceItems
      FROM `{S}.gks_vcv_aggregate_contribution` agg
      WHERE TRUE
        {PFILTER}

      UNION ALL

      -- Aggregate layer: Non-contributing evidence line (only when items exist)
      SELECT
        FORMAT('%s.non-contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'neutral' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Non-contributing' AS name) AS strengthOfEvidenceProvided,
        ARRAY(
          SELECT FORMAT('#/vcv/%s', nc.layer_id)
          FROM UNNEST(agg.non_contributing_details) AS nc
        ) AS evidenceItems
      FROM `{S}.gks_vcv_aggregate_contribution` agg
      WHERE agg.non_contributing_details IS NOT NULL AND ARRAY_LENGTH(agg.non_contributing_details) > 0
        {PFILTER}
    """, '{EL_HEAD}', el_head);
    SET dict_vcv_evidence_line_query = REPLACE(dict_vcv_evidence_line_query, '{PFILTER}', pf_agg);
    SET dict_vcv_evidence_line_query = REPLACE(dict_vcv_evidence_line_query, '{S}', rec.schema_name);
    SET dict_vcv_evidence_line_query = REPLACE(dict_vcv_evidence_line_query, '{CT}', temp_create);
    SET dict_vcv_evidence_line_query = REPLACE(dict_vcv_evidence_line_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_vcv_evidence_line_query;

    -------------------------------------------------------------------------
    -- Dictionary table - VCV propositions (global, keyed by proposition id)
    -- Collects propositions from all 3 layers (classification, priority, agg).
    -- {PROP_HEAD}: real table in full mode, {P}.stg_* in incremental. {PFILTER} restricts
    -- each arm to impacted VCVs; objectCondition is the inline agg.unique_conditions array.
    -------------------------------------------------------------------------
    SET dict_vcv_proposition_query = REPLACE("""
      {PROP_HEAD}
      AS
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), agg.obj_ref) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', agg.obj_ref, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', agg.obj_ref, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM (
        SELECT a.*,
          IF(ARRAY_LENGTH(a.unique_conditions) = 0, CAST(NULL AS STRING),
            IF(ARRAY_LENGTH(a.unique_conditions) = 1, a.unique_conditions[OFFSET(0)],
              CONCAT('#/conditionSet/clinvar.conditionset:vcv-', TO_HEX(MD5(ARRAY_TO_STRING(ARRAY(SELECT c FROM UNNEST(a.unique_conditions) c WHERE c IS NOT NULL ORDER BY c), '|')))))) AS obj_ref
        FROM `{S}.gks_vcv_classification_agg` a
      ) agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      WHERE TRUE
        {PFILTER}
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), agg.obj_ref) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', agg.obj_ref, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', agg.obj_ref, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM (
        SELECT a.*,
          IF(ARRAY_LENGTH(a.unique_conditions) = 0, CAST(NULL AS STRING),
            IF(ARRAY_LENGTH(a.unique_conditions) = 1, a.unique_conditions[OFFSET(0)],
              CONCAT('#/conditionSet/clinvar.conditionset:vcv-', TO_HEX(MD5(ARRAY_TO_STRING(ARRAY(SELECT c FROM UNNEST(a.unique_conditions) c WHERE c IS NOT NULL ORDER BY c), '|')))))) AS obj_ref
        FROM `{S}.gks_vcv_priority_agg` a
      ) agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      WHERE TRUE
        {PFILTER}
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          IF(cpt.gks_type LIKE 'Clinvar%', CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', agg.variation_id)) AS subjectVariant,
          IF(cpt.gks_type LIKE 'Clinvar%', FORMAT('#/variation/clinvar:%s', agg.variation_id), CAST(NULL AS STRING)) AS subject,
          CASE cpt.gks_type
            WHEN 'VariantPathogenicityProposition' THEN 'isCausalFor'
            WHEN 'VariantOncogenicityProposition' THEN 'isOncogenicFor'
            WHEN 'VariantClinicalSignificanceProposition' THEN 'hasClinicalSignificanceFor'
            WHEN 'ClinvarAffectsProposition' THEN 'hasAffectFor'
            WHEN 'ClinvarAssociationProposition' THEN 'isAssociatedWith'
            WHEN 'ClinvarConfersSensitivityProposition' THEN 'confersSensitivityFor'
            WHEN 'ClinvarConflictingDataFromSubmitterProposition' THEN 'isConflictingDataFromSubmittersFor'
            WHEN 'ClinvarDrugResponseProposition' THEN 'hasDrugResponseFor'
            WHEN 'ClinvarNotProvidedProposition' THEN 'hasNoProvidedClassificationFor'
            WHEN 'ClinvarOtherProposition' THEN 'isClinvarOtherAssociationFor'
            WHEN 'ClinvarProtectiveProposition' THEN 'isProtectiveFor'
            WHEN 'ClinvarRiskFactorProposition' THEN 'isRiskFactorFor'
            ELSE 'isClinvarUndefinedAssociationFor'
          END AS predicate,
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), agg.obj_ref) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', agg.obj_ref, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', agg.obj_ref, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM (
        SELECT a.*,
          IF(ARRAY_LENGTH(a.unique_conditions) = 0, CAST(NULL AS STRING),
            IF(ARRAY_LENGTH(a.unique_conditions) = 1, a.unique_conditions[OFFSET(0)],
              CONCAT('#/conditionSet/clinvar.conditionset:vcv-', TO_HEX(MD5(ARRAY_TO_STRING(ARRAY(SELECT c FROM UNNEST(a.unique_conditions) c WHERE c IS NOT NULL ORDER BY c), '|')))))) AS obj_ref
        FROM `{S}.gks_vcv_aggregate_contribution` a
      ) agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      WHERE TRUE
        {PFILTER}
    """, '{PROP_HEAD}', prop_head);
    SET dict_vcv_proposition_query = REPLACE(dict_vcv_proposition_query, '{PFILTER}', pf_agg);
    SET dict_vcv_proposition_query = REPLACE(dict_vcv_proposition_query, '{S}', rec.schema_name);
    SET dict_vcv_proposition_query = REPLACE(dict_vcv_proposition_query, '{CT}', temp_create);
    SET dict_vcv_proposition_query = REPLACE(dict_vcv_proposition_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_vcv_proposition_query;

    -------------------------------------------------------------------------
    -- Synthetic ConditionSets for multi-condition VCV aggregates.
    -- A VCV aggregates SCVs that may assert different conditions; the schema
    -- object/objectCondition is a SINGLE Condition|ConditionSet|iriReference, so a
    -- multi-condition VCV references ONE content-keyed ConditionSet (membershipOperator
    -- 'OR'; concepts may themselves be #/conditionSet/ pointers — nesting is allowed).
    -- The id digest here MUST match the obj_ref computed in the proposition build above.
    -- Rebuild the dict as (trait-set rows) UNION (synthetic vcv- rows) so it is idempotent
    -- across re-runs. NOTE: reads the three gks_vcv_*_agg tables — in incremental mode those
    -- are carried-forward GLOBAL (impacted recomputed ∪ unimpacted carried forward), so this
    -- producer emits ALL synthetic ConditionSets and carried-forward VCV propositions' refs
    -- stay present. (Verify via the full-vs-incremental oracle on gks_dict_condition_set.)
    -------------------------------------------------------------------------
    SET query_vcv_synthetic_condsets = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_condition_set` AS
      SELECT * FROM `{S}.gks_dict_condition_set`
      WHERE id NOT LIKE 'clinvar.conditionset:vcv-%'
      UNION ALL
      SELECT
        CONCAT('clinvar.conditionset:vcv-', id_digest) AS id,
        CAST(NULL AS STRING) AS conceptSetType,
        ANY_VALUE(sc) AS concepts,
        'OR' AS membershipOperator
      FROM (
        SELECT
          ARRAY(SELECT c FROM UNNEST(unique_conditions) c WHERE c IS NOT NULL ORDER BY c) AS sc,
          TO_HEX(MD5(ARRAY_TO_STRING(ARRAY(SELECT c FROM UNNEST(unique_conditions) c WHERE c IS NOT NULL ORDER BY c), '|'))) AS id_digest
        FROM (
          SELECT unique_conditions FROM `{S}.gks_vcv_classification_agg`
          UNION ALL SELECT unique_conditions FROM `{S}.gks_vcv_priority_agg`
          UNION ALL SELECT unique_conditions FROM `{S}.gks_vcv_aggregate_contribution`
        )
        WHERE ARRAY_LENGTH(unique_conditions) > 1
      )
      GROUP BY id_digest
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_vcv_synthetic_condsets;

    -------------------------------------------------------------------------
    -- FINAL: VCV statement (all statement layers). The three per-layer statement temps
    -- are already impacted-filtered in incremental mode, so this UNION is impacted-only.
    -- {VCV_HEAD}: real table in full mode, {P}.stg_* in incremental.
    -------------------------------------------------------------------------
    SET query_vcv_pre = REPLACE("""
      {VCV_HEAD} AS
      SELECT * FROM `{P}.temp_vcv_agg_contribution_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_vcv_classification_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_vcv_priority_statements`
    """, '{VCV_HEAD}', vcv_head);
    SET query_vcv_pre = REPLACE(query_vcv_pre, '{S}', rec.schema_name);
    SET query_vcv_pre = REPLACE(query_vcv_pre, '{CT}', temp_create);
    SET query_vcv_pre = REPLACE(query_vcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_vcv_pre;

    -----------------------------------------------------------------------
    -- Incremental only: UNION-CTAS carry-forward merge for each of the three outputs.
    -- The outputs have NO vcv_accession column, so the parent accession is parsed from
    -- the pk (VCV accessions contain no '.' or '-'). Carry forward the baseline rows whose
    -- parsed accession is NOT impacted (NULL-safe LEFT JOIN anti-join) AND still present
    -- in the current {S}.variation_archive (so a removed VCV is not resurrected). UNION ALL
    -- the freshly recomputed impacted rows from {P}.stg_*. Explicit column lists so any
    -- schema/column-order drift errors instead of silently corrupting.
    -----------------------------------------------------------------------
    IF eff_incremental THEN

      -- gks_dict_vcv_evidence_line: id = '{VCV}.{ver}-…' -> SPLIT(id,'.')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_vcv_evidence_line` AS
        SELECT
          b.id, b.type, b.directionOfEvidenceProvided, b.strengthOfEvidenceProvided, b.evidenceItems
        FROM `{BASE}.gks_dict_vcv_evidence_line` b
        LEFT JOIN `{S}.vcv_impacted_ids` imp ON imp.vcv_accession = SPLIT(b.id, '.')[OFFSET(0)]
        WHERE imp.vcv_accession IS NULL
          AND SPLIT(b.id, '.')[OFFSET(0)] IN (SELECT id FROM `{S}.variation_archive`)
        UNION ALL
        SELECT
          id, type, directionOfEvidenceProvided, strengthOfEvidenceProvided, evidenceItems
        FROM `{P}.stg_gks_dict_vcv_evidence_line`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- gks_dict_vcv_proposition: key = '{VCV}-…' -> SPLIT(key,'-')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_vcv_proposition` AS
        SELECT
          b.key, b.value
        FROM `{BASE}.gks_dict_vcv_proposition` b
        LEFT JOIN `{S}.vcv_impacted_ids` imp ON imp.vcv_accession = SPLIT(b.key, '-')[OFFSET(0)]
        WHERE imp.vcv_accession IS NULL
          AND SPLIT(b.key, '-')[OFFSET(0)] IN (SELECT id FROM `{S}.variation_archive`)
        UNION ALL
        SELECT
          key, value
        FROM `{P}.stg_gks_dict_vcv_proposition`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- gks_dict_vcv: id = '{VCV}.{ver}-…' -> SPLIT(id,'.')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_vcv` AS
        SELECT
          b.id, b.type, b.direction, b.strength, b.confidence, b.classification,
          b.proposition, b.extensions, b.hasEvidenceLines
        FROM `{BASE}.gks_dict_vcv` b
        LEFT JOIN `{S}.vcv_impacted_ids` imp ON imp.vcv_accession = SPLIT(b.id, '.')[OFFSET(0)]
        WHERE imp.vcv_accession IS NULL
          AND SPLIT(b.id, '.')[OFFSET(0)] IN (SELECT id FROM `{S}.variation_archive`)
        UNION ALL
        SELECT
          id, type, direction, strength, confidence, classification,
          proposition, extensions, hasEvidenceLines
        FROM `{P}.stg_gks_dict_vcv`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

    END IF;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE IF EXISTS _SESSION.temp_vcv_classification_statements;
      DROP TABLE IF EXISTS _SESSION.temp_vcv_priority_statements;
      DROP TABLE IF EXISTS _SESSION.temp_vcv_agg_contribution_statements;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_vcv_evidence_line;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_vcv_proposition;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_vcv;
      END IF;
    END IF;

  END FOR;
END;


-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_vcv_statement_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/incomplete, the impacted set / required inputs are missing, or the
-- pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_vcv_statement_build`(on_date, debug, TRUE);
END;
