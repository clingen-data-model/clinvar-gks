-------------------------------------------------------------------------------
-- gks_rcv_statement — build the three RCV statement outputs from a release:
--   gks_dict_rcv_evidence_line  (from the 3 rcv agg tables)
--   gks_dict_rcv_proposition    (from the 3 rcv agg tables + condition resolution)
--   gks_dict_rcv                (UNION of the 3 per-layer statement temps)
--
-- Three entry points:
--   gks_rcv_statement_proc(on_date, debug)              -> full rebuild (unchanged behavior)
--   gks_rcv_statement_proc_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   gks_rcv_statement_build(on_date, debug, incremental) -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-08-incremental-gks-
-- downstream-plan-3-rcv-vcv.md, Chunk 3):
--   All three outputs are per-RCV-parent. They are built FROM the three rcv agg tables
--   (gks_rcv_classification_agg / _priority_agg / _aggregate_contribution — each carries
--   rcv_accession) plus a condition-resolution temp (rcv_mapping ⋈ gks_scv_condition_sets).
--   Only the RCV parents impacted by this release are recomputed; the rest are carried
--   forward from the baseline release. The impacted-parent set is the persistent {S}
--   table rcv_impacted_ids produced by gks_rcvvcv_changed (membership-first over
--   scv_changed_ids ∪ scv_removed_ids plus rcv_mapping / rcv_accession diffs), the SAME
--   set that drove the agg tables (Chunk 2) — so the agg rows this proc reads for an
--   unimpacted RCV are byte-identical to baseline, and the deterministic statement
--   transform reproduces the baseline statement rows exactly.
--
--   {PFILTER} restricts each output's read of the agg tables (and the condition temp)
--   to impacted RCVs in incremental mode ('' in full). The per-layer statement temps
--   (which feed ONLY gks_dict_rcv) are filtered too, so gks_dict_rcv's stage is
--   impacted-only. In incremental mode each output is staged to {P}.stg_* and then
--   UNION-CTAS-merged into {S}: carry forward the baseline rows whose parent RCV is NOT
--   impacted AND still present in {S}.rcv_accession (so a removed RCV is not resurrected),
--   UNION ALL the freshly recomputed impacted rows.
--
--   pk-parse (the outputs have NO rcv_accession column — they UNION statement temps that
--   carry only id/type/…): the parent accession is recovered from the pk. Accessions
--   contain no '.' or '-'.
--     gks_dict_rcv_evidence_line: id = '{RCV}.{ver}-…'  -> SPLIT(id, '.')[OFFSET(0)]
--     gks_dict_rcv:               id = '{RCV}.{ver}-…'  -> SPLIT(id, '.')[OFFSET(0)]
--     gks_dict_rcv_proposition:   key = '{RCV}-…'       -> SPLIT(key, '-')[OFFSET(0)]
--
--   Determinism: this proc has NO group-by / ANY_VALUE over the agg rows — the outputs
--   are row-wise projections of the (already-deterministic) agg tables, and the array
--   projections (ARRAY(SELECT … FROM UNNEST(…))) preserve the stored array order. The
--   only representative pick is the condition temp's ROW_NUMBER() … ORDER BY scv_id
--   (deterministic). No determinism fix was needed for carry-forward to hold.
--
--   Pointer vs inline: subjectVariant (#/variation), proposition (#/proposition),
--   evidenceItems (#/scv, #/rcv) and hasEvidenceLines (#/evidenceLine) are all pointers.
--   The proposition's objectCondition is INLINE condition content (condition_concept
--   resolved from the RCV's representative member SCV via gks_scv_condition_sets). This
--   is safe under carry-forward: an unimpacted RCV has no changed/removed member and an
--   unchanged rcv_mapping, so its deterministic representative SCV (min scv_id) and that
--   SCV's condition are unchanged; any member/mapping change makes the RCV impacted and
--   it is recomputed.
--
--   Version-invalidation: the guard falls back to a full rebuild when the baseline is
--   missing/incomplete, the impacted set / required inputs are absent, or the pipeline
--   gate_key mismatches. Call the *_incremental wrapper only when carry-forward is safe.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  DECLARE query_condition_data STRING;
  DECLARE query_classification STRING;
  DECLARE query_priority STRING;
  DECLARE query_agg_contribution STRING;
  DECLARE dict_rcv_evidence_line_query STRING;
  DECLARE dict_rcv_proposition_query STRING;
  DECLARE query_rcv_pre STRING;
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
  DECLARE pf_agg STRING;       -- impacted-RCV filter on `agg.rcv_accession`
  DECLARE pf_cond STRING;      -- impacted-RCV filter on `rsl.rcv_accession` (condition temp)
  DECLARE el_head STRING;      -- gks_dict_rcv_evidence_line target (real table vs stg temp)
  DECLARE prop_head STRING;    -- gks_dict_rcv_proposition target
  DECLARE rcv_head STRING;     -- gks_dict_rcv target

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
    -- impacted-parent set + the agg tables (and the condition-resolution inputs), AND
    -- the pipeline gate_key matches the baseline. Otherwise fall back to full.
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
                WHERE table_name IN ('gks_dict_rcv_evidence_line','gks_dict_rcv_proposition',
                  'gks_dict_rcv')) = 3
      """, baseline_schema) INTO base_ok;

      -- current release must have the impacted-parent set, the three agg tables it reads,
      -- and the condition-resolution + removed-RCV inputs.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('rcv_impacted_ids','gks_rcv_classification_agg',
                  'gks_rcv_priority_agg','gks_rcv_aggregate_contribution','rcv_mapping',
                  'gks_scv_condition_sets','rcv_accession')) = 7
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
    -- writes straight to its {S} table. In incremental mode reads of the agg tables +
    -- condition temp are filtered to impacted RCVs, each output is staged to {P}.stg_*,
    -- and the merge carries forward the unimpacted baseline rows.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET pf_agg  = 'AND agg.rcv_accession IN (SELECT rcv_accession FROM `{S}.rcv_impacted_ids`)';
      SET pf_cond = 'AND rsl.rcv_accession IN (SELECT rcv_accession FROM `{S}.rcv_impacted_ids`)';
      SET el_head   = '{CT} `{P}.stg_gks_dict_rcv_evidence_line`';
      SET prop_head = '{CT} `{P}.stg_gks_dict_rcv_proposition`';
      SET rcv_head  = '{CT} `{P}.stg_gks_dict_rcv`';
    ELSE
      SET pf_agg  = '';
      SET pf_cond = '';
      SET el_head   = 'CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_evidence_line`';
      SET prop_head = 'CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_proposition`';
      SET rcv_head  = 'CREATE OR REPLACE TABLE `{S}.gks_dict_rcv`';
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_rcv_condition_data',
        'temp_rcv_classification_statements', 'temp_rcv_priority_statements',
        'temp_rcv_agg_contribution_statements',
        'stg_gks_dict_rcv_evidence_line', 'stg_gks_dict_rcv_proposition', 'stg_gks_dict_rcv'
      ]);
    END IF;

    -------------------------------------------------------------------------
    -- CONDITION DATA: Resolve condition concept per RCV via rcv_mapping
    -- Picks one representative SCV per RCV (deterministic: min scv_id); produces a single
    -- JSON value representing either the SCV's condition (MappableConcept) or conditionSet
    -- (ConceptSet of conditions). Extensions are excluded. {PFILTER} restricts to impacted
    -- RCVs in incremental mode.
    -------------------------------------------------------------------------
    SET query_condition_data = REPLACE("""
      {CT} `{P}.temp_rcv_condition_data` AS
      WITH rcv_scv_link AS (
        SELECT
          rm.rcv_accession,
          scv_id,
          ROW_NUMBER() OVER (PARTITION BY rm.rcv_accession ORDER BY scv_id) AS rn
        FROM `{S}.rcv_mapping` rm
        CROSS JOIN UNNEST(rm.scv_accessions) AS scv_id
      )
      SELECT
        rsl.rcv_accession,
        COALESCE(
          scs.extensions.value_submitted_condition.condition,
          scs.extensions.value_submitted_condition.conditionSet,
          scs.extensions.value_submitted_condition_set.condition,
          scs.extensions.value_submitted_condition_set.conditionSet
        ) AS condition_concept
      FROM rcv_scv_link rsl
      JOIN `{S}.gks_scv_condition_sets` scs ON scs.scv_id = rsl.scv_id
      WHERE rsl.rn = 1
        {PFILTER}
    """, '{PFILTER}', pf_cond);
    SET query_condition_data = REPLACE(query_condition_data, '{S}', rec.schema_name);
    SET query_condition_data = REPLACE(query_condition_data, '{CT}', temp_create);
    SET query_condition_data = REPLACE(query_condition_data, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_condition_data;

    -------------------------------------------------------------------------
    -- GROUPING LAYER: CLASSIFICATION GROUPING
    -------------------------------------------------------------------------
    SET query_classification = REPLACE("""
      {CT} `{P}.temp_rcv_classification_statements` AS
      SELECT
        agg.id,

        -- Flattened GKS Payload
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

        -- classification: single MappableConcept for all submission levels
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

      FROM `{S}.gks_rcv_classification_agg` agg
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
      {CT} `{P}.temp_rcv_priority_statements` AS
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

      FROM `{S}.gks_rcv_priority_agg` agg
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
      {CT} `{P}.temp_rcv_agg_contribution_statements` AS
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

      FROM `{S}.gks_rcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      WHERE TRUE
        {PFILTER}
    """, '{PFILTER}', pf_agg);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{S}', rec.schema_name);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{CT}', temp_create);
    SET query_agg_contribution = REPLACE(query_agg_contribution, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_agg_contribution;

    -------------------------------------------------------------------------
    -- Dictionary table - RCV evidence lines
    -- Extracts evidence lines from all 3 statement layers into flat rows.
    -- Classification: 1 Contributing evidence line per statement (SCV items)
    -- Priority/Aggregate: Contributing + optional Non-contributing (RCV items)
    -- {EL_HEAD}: real table in full mode, {P}.stg_* in incremental. {PFILTER} restricts
    -- each arm to impacted RCVs (accession carried in agg.rcv_accession).
    -------------------------------------------------------------------------
    SET dict_rcv_evidence_line_query = REPLACE("""
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
      FROM `{S}.gks_rcv_classification_agg` agg
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
          SELECT FORMAT('#/rcv/%s', stmt_id)
          FROM UNNEST(agg.contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_rcv_priority_agg` agg
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
          SELECT FORMAT('#/rcv/%s', stmt_id)
          FROM UNNEST(agg.non_contributing_statement_ids) AS stmt_id
        ) AS evidenceItems
      FROM `{S}.gks_rcv_priority_agg` agg
      WHERE ARRAY_LENGTH(agg.non_contributing_statement_ids) > 0
        {PFILTER}

      UNION ALL

      -- Aggregate layer: Contributing evidence line
      SELECT
        FORMAT('%s.contributing', agg.id) AS id,
        'EvidenceLine' AS type,
        'supports' AS directionOfEvidenceProvided,
        STRUCT('MappableConcept' AS type, 'Strength' AS conceptType, 'Contributing' AS name) AS strengthOfEvidenceProvided,
        [FORMAT('#/rcv/%s', agg.contributing_layer_id)] AS evidenceItems
      FROM `{S}.gks_rcv_aggregate_contribution` agg
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
          SELECT FORMAT('#/rcv/%s', nc.layer_id)
          FROM UNNEST(agg.non_contributing_details) AS nc
        ) AS evidenceItems
      FROM `{S}.gks_rcv_aggregate_contribution` agg
      WHERE agg.non_contributing_details IS NOT NULL AND ARRAY_LENGTH(agg.non_contributing_details) > 0
        {PFILTER}
    """, '{EL_HEAD}', el_head);
    SET dict_rcv_evidence_line_query = REPLACE(dict_rcv_evidence_line_query, '{PFILTER}', pf_agg);
    SET dict_rcv_evidence_line_query = REPLACE(dict_rcv_evidence_line_query, '{S}', rec.schema_name);
    SET dict_rcv_evidence_line_query = REPLACE(dict_rcv_evidence_line_query, '{CT}', temp_create);
    SET dict_rcv_evidence_line_query = REPLACE(dict_rcv_evidence_line_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_rcv_evidence_line_query;

    -------------------------------------------------------------------------
    -- Dictionary table - RCV propositions (keyed by proposition id)
    -- Collects propositions from all 3 layers (classification, priority, agg).
    -- {PROP_HEAD}: real table in full mode, {P}.stg_* in incremental. {PFILTER} restricts
    -- each arm to impacted RCVs; objectCondition is resolved from the impacted-filtered
    -- temp_rcv_condition_data.
    -------------------------------------------------------------------------
    SET dict_rcv_proposition_query = REPLACE("""
      {PROP_HEAD}
      AS
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
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
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_classification_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
      WHERE TRUE
        {PFILTER}
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
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
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_priority_agg` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
      WHERE TRUE
        {PFILTER}
      UNION ALL
      SELECT
        agg.prop_id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(cpt.gks_type LIKE 'Clinvar%', 'CustomProposition', cpt.gks_type) AS type,
          IF(cpt.gks_type LIKE 'Clinvar%', cpt.gks_type, CAST(NULL AS STRING)) AS customPropositionType,
          agg.prop_id AS id,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
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
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same value)
          IF(cpt.gks_type LIKE 'Clinvar%' OR cpt.gks_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), rcd.condition_concept) AS objectCondition,
          IF((NOT (cpt.gks_type LIKE 'Clinvar%')) AND cpt.gks_type = 'VariantOncogenicityProposition', rcd.condition_concept, CAST(NULL AS STRING)) AS objectTumorType,
          IF(cpt.gks_type LIKE 'Clinvar%', rcd.condition_concept, CAST(NULL AS STRING)) AS object
        )), remove_empty => TRUE) as value
      FROM `{S}.gks_rcv_aggregate_contribution` agg
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.prop_type = cpt.code
      LEFT JOIN {P}.temp_rcv_condition_data rcd ON rcd.rcv_accession = agg.rcv_accession
      WHERE TRUE
        {PFILTER}
    """, '{PROP_HEAD}', prop_head);
    SET dict_rcv_proposition_query = REPLACE(dict_rcv_proposition_query, '{PFILTER}', pf_agg);
    SET dict_rcv_proposition_query = REPLACE(dict_rcv_proposition_query, '{S}', rec.schema_name);
    SET dict_rcv_proposition_query = REPLACE(dict_rcv_proposition_query, '{CT}', temp_create);
    SET dict_rcv_proposition_query = REPLACE(dict_rcv_proposition_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_rcv_proposition_query;

    -------------------------------------------------------------------------
    -- FINAL: RCV statement (all statement layers). The three per-layer statement temps
    -- are already impacted-filtered in incremental mode, so this UNION is impacted-only.
    -- {RCV_HEAD}: real table in full mode, {P}.stg_* in incremental.
    -------------------------------------------------------------------------
    SET query_rcv_pre = REPLACE("""
      {RCV_HEAD} AS
      SELECT * FROM `{P}.temp_rcv_agg_contribution_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_rcv_classification_statements`
      UNION ALL
      SELECT * FROM `{P}.temp_rcv_priority_statements`
    """, '{RCV_HEAD}', rcv_head);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{S}', rec.schema_name);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{CT}', temp_create);
    SET query_rcv_pre = REPLACE(query_rcv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_rcv_pre;

    -----------------------------------------------------------------------
    -- Incremental only: UNION-CTAS carry-forward merge for each of the three outputs.
    -- The outputs have NO rcv_accession column, so the parent accession is parsed from
    -- the pk (accessions contain no '.' or '-'). Carry forward the baseline rows whose
    -- parsed accession is NOT impacted (NULL-safe LEFT JOIN anti-join) AND still present
    -- in the current {S}.rcv_accession (so a removed RCV is not resurrected). UNION ALL
    -- the freshly recomputed impacted rows from {P}.stg_*. Explicit column lists so any
    -- schema/column-order drift errors instead of silently corrupting.
    -----------------------------------------------------------------------
    IF eff_incremental THEN

      -- gks_dict_rcv_evidence_line: id = '{RCV}.{ver}-…' -> SPLIT(id,'.')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_evidence_line` AS
        SELECT
          b.id, b.type, b.directionOfEvidenceProvided, b.strengthOfEvidenceProvided, b.evidenceItems
        FROM `{BASE}.gks_dict_rcv_evidence_line` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = SPLIT(b.id, '.')[OFFSET(0)]
        WHERE imp.rcv_accession IS NULL
          AND SPLIT(b.id, '.')[OFFSET(0)] IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          id, type, directionOfEvidenceProvided, strengthOfEvidenceProvided, evidenceItems
        FROM `{P}.stg_gks_dict_rcv_evidence_line`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- gks_dict_rcv_proposition: key = '{RCV}-…' -> SPLIT(key,'-')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_rcv_proposition` AS
        SELECT
          b.key, b.value
        FROM `{BASE}.gks_dict_rcv_proposition` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = SPLIT(b.key, '-')[OFFSET(0)]
        WHERE imp.rcv_accession IS NULL
          AND SPLIT(b.key, '-')[OFFSET(0)] IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          key, value
        FROM `{P}.stg_gks_dict_rcv_proposition`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- gks_dict_rcv: id = '{RCV}.{ver}-…' -> SPLIT(id,'.')[OFFSET(0)]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_rcv` AS
        SELECT
          b.id, b.type, b.direction, b.strength, b.confidence, b.classification,
          b.proposition, b.extensions, b.hasEvidenceLines
        FROM `{BASE}.gks_dict_rcv` b
        LEFT JOIN `{S}.rcv_impacted_ids` imp ON imp.rcv_accession = SPLIT(b.id, '.')[OFFSET(0)]
        WHERE imp.rcv_accession IS NULL
          AND SPLIT(b.id, '.')[OFFSET(0)] IN (SELECT id FROM `{S}.rcv_accession`)
        UNION ALL
        SELECT
          id, type, direction, strength, confidence, classification,
          proposition, extensions, hasEvidenceLines
        FROM `{P}.stg_gks_dict_rcv`
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

    END IF;

    -- Drop temp tables when not in debug mode
    IF NOT debug THEN
      DROP TABLE IF EXISTS _SESSION.temp_rcv_condition_data;
      DROP TABLE IF EXISTS _SESSION.temp_rcv_classification_statements;
      DROP TABLE IF EXISTS _SESSION.temp_rcv_priority_statements;
      DROP TABLE IF EXISTS _SESSION.temp_rcv_agg_contribution_statements;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_rcv_evidence_line;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_rcv_proposition;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_rcv;
      END IF;
    END IF;

  END FOR;
END;


-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_rcv_statement_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/incomplete, the impacted set / required inputs are missing, or the
-- pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_rcv_statement_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_rcv_statement_build`(on_date, debug, TRUE);
END;
