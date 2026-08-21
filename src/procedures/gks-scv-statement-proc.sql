-------------------------------------------------------------------------------
-- gks_scv_statement — build the SCV statement dictionaries (submitter, proposition,
-- evidence line, statement) from a release.
--
-- Three entry points:
--   gks_scv_statement_proc(on_date, debug)              -> full rebuild (unchanged behavior)
--   gks_scv_statement_proc_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   gks_scv_statement_build(on_date, debug, incremental) -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-07-incremental-gks-
-- downstream-plan-2-scv.md, Chunk 3):
--   TWO outputs are recomputed GLOBALLY every release (never carried forward):
--     * gks_dict_submitter — a GLOBAL dedup dictionary (GROUP BY submitter over the
--       shared source temp temp_gks_scv). temp_gks_scv MUST therefore stay GLOBAL
--       (unfiltered); filtering it would starve the submitter dict of submitters that
--       only appear on unchanged SCVs.
--     * gks_dict_proposition — although keyed per-SCV, its value embeds
--       geneContextQualifier, a variation/gene-derived struct (single_gene_variation +
--       gene) that changes independently of the SCV's own clinical_assertion or trait.
--       That driver is NOT modeled by scv_changed_ids (which covers only the
--       clinical_assertion + trait cascades), so per-SCV carry-forward would leave
--       stale gene context on unmodified SCVs whose variation changed. It is therefore
--       recomputed globally, like gks_dict_submitter. Its feeding temps
--       (temp_gks_scv_proposition, temp_gks_scv_target_proposition) stay GLOBAL.
--   TWO outputs are per-SCV carry-forward (they use #/proposition pointers and do NOT
--   embed gene context — only the SCV's own record + the trait-covered submitted-
--   condition struct):
--     * gks_dict_evidence_line, gks_dict_scv — in incremental mode the final writes
--       (and temp_scv_condition_names, which feeds ONLY gks_dict_scv) are filtered to
--       the changed set, staged, and merged with the carried-forward baseline rows via
--       UNION-CTAS. temp_scv_citations / temp_scv_method feed ONLY gks_dict_scv and are
--       LEFT-JOINed by scv id into that already-filtered final, so they are safely
--       over-computed globally. (The gene-context / MOI / penetrance qualifier temps,
--       Steps 2-4, feed ONLY the global temp_gks_scv_proposition / _target_proposition
--       — i.e. gks_dict_proposition — never the per-SCV finals.)
--   A built-in coverage validation runs unconditionally (both modes) after the writes:
--   gks_dict_scv must be exactly 1:1 with scv_summary(id, version) and every
--   gks_dict_evidence_line scv-id must exist in scv_summary — RAISE otherwise (catches
--   a silent drop/dup/orphan the single-window oracle cannot prove).
--   The changed / removed SCV sets are the persistent {S} tables scv_changed_ids /
--   scv_removed_ids produced by gks_scv_changed (driver-complete for the
--   clinical_assertion + trait cascades; a trait/traitset edit re-derives the affected
--   SCV statement rows — gks_dict_scv / gks_dict_evidence_line embed the trait-derived
--   submitted-condition struct from gks_scv_condition_sets).
--   The merge recovers the scv id from each per-SCV output's pk BY PARSING (the stored
--   value dropped scv_id):
--     gks_dict_scv / gks_dict_evidence_line: id = clinvar.submission:{scv}.{ver}
--       -> SPLIT(SPLIT(id, ':')[OFFSET(1)], '.')[OFFSET(0)]
--   Version-invalidation: the guard falls back to a full rebuild when the baseline is
--   missing/incomplete, the diff drivers / changed sets are absent, or the pipeline
--   gate_key mismatches. Call the *_incremental wrapper only when carry-forward is safe.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_statement_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN

  DECLARE query_scv_records STRING;
  DECLARE query_gene_context_qualifiers STRING;
  DECLARE query_moi_qualifiers STRING;
  DECLARE query_penetrance_qualifiers STRING;
  DECLARE query_scv_proposition STRING;
  DECLARE query_scv_target_proposition STRING;
  DECLARE query_scv_condition_names STRING;
  DECLARE query_scv_citations STRING;
  DECLARE query_scv_method STRING;
  DECLARE dict_submitter_query STRING;
  DECLARE dict_proposition_query STRING;
  DECLARE dict_evidence_line_query STRING;
  DECLARE query_statement_scv_pre STRING;
  DECLARE temp_create STRING;

  -- coverage-validation results (both modes)
  DECLARE scv_cov_mismatch INT64 DEFAULT 0;
  DECLARE el_orphan_count INT64 DEFAULT 0;

  -- incremental control / fallback guard
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;
  DECLARE gate_ok BOOL DEFAULT FALSE;
  DECLARE stamps_exist BOOL DEFAULT FALSE;

  -- per-query changed-set filter fragments ('' in full mode). scv_changed_ids is a
  -- PERSISTENT {S} table (written by gks_scv_changed); the fragments are resolved with
  -- rec.schema_name so they can be REPLACE-inserted after the body's {S} is resolved.
  -- Only gks_dict_evidence_line + gks_dict_scv are per-SCV carry-forward, so only the
  -- alias `scv.id` filter (evidence_line, gks_dict_scv) and the condition_names filter
  -- are used. gks_dict_proposition is globally recomputed (see header), so its temps
  -- (temp_gks_scv_proposition / temp_gks_scv_target_proposition) stay unfiltered.
  DECLARE vf_scv_where STRING;   -- WHERE on alias `scv.id` (evidence_line, gks_dict_scv)
  DECLARE vf_cn_where STRING;    -- WHERE on bare `scv_id` (temp_scv_condition_names)
  -- per-output head fragments (real table in full; stg temp for the merge in incremental)
  DECLARE del_head STRING;
  DECLARE dscv_head STRING;
  DECLARE query_merge STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (select s.schema_name, s.prev_release_date FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -----------------------------------------------------------------------
    -- Resolve baseline + fallback guard: incremental is only safe when the prior
    -- release exists with all four statement outputs, the current release has the diff
    -- driver tables + the precomputed changed/removed SCV sets, AND the pipeline
    -- gate_key matches the baseline. Otherwise fall back to full.
    -- diff_trait / diff_trait_set are required here (not just diff_clinical_assertion):
    -- gks_dict_scv / gks_dict_evidence_line embed the trait-derived submitted-condition
    -- struct, so statement correctness depends on scv_changed_ids being trait-complete,
    -- which required those drivers when gks_scv_changed ran.
    -----------------------------------------------------------------------
    SET eff_incremental = FALSE;
    SET baseline_schema = NULL;
    SET base_ok = FALSE;
    SET diff_ok = FALSE;
    SET gate_ok = FALSE;
    SET stamps_exist = FALSE;

    IF incremental AND rec.prev_release_date IS NOT NULL THEN
      SET baseline_schema = (
        SELECT s2.schema_name FROM clinvar_ingest.schema_on(rec.prev_release_date) AS s2 LIMIT 1
      );
    END IF;

    IF baseline_schema IS NOT NULL THEN
      -- baseline must have all 4 statement outputs
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('gks_dict_submitter','gks_dict_proposition',
                  'gks_dict_evidence_line','gks_dict_scv')) = 4
      """, baseline_schema) INTO base_ok;

      -- current release must have the diff drivers (SCV diff + the trait cascade)
      -- AND the precomputed changed / removed SCV sets from gks_scv_changed.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('diff_clinical_assertion','diff_trait','diff_trait_set',
                  'scv_changed_ids','scv_removed_ids')) = 5
      """, rec.schema_name) INTO diff_ok;

      -- version gate — TWO statements (BigQuery resolves table refs at analysis time
      -- and does not short-circuit, so a single combined statement would ERROR when a
      -- pre-feature baseline lacks the stamp). Confirm both stamps exist, then compare.
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
        SET gate_ok = IFNULL(gate_ok, FALSE);
      END IF;

      SET eff_incremental = base_ok AND diff_ok AND gate_ok;
    END IF;

    -----------------------------------------------------------------------
    -- Mode-dependent fragments. In full mode all filters are empty and the three
    -- per-SCV finals write straight to their {S} tables. In incremental mode the
    -- exclusive per-SCV temps + finals are filtered to scv_changed_ids and the finals
    -- are staged for the merge. gks_dict_submitter and the shared temp_gks_scv are
    -- NEVER filtered.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET vf_scv_where = 'WHERE scv.id IN (SELECT scv_id FROM `' || rec.schema_name || '.scv_changed_ids`)';
      SET vf_cn_where  = 'WHERE scv_id IN (SELECT scv_id FROM `' || rec.schema_name || '.scv_changed_ids`)';
      SET del_head  = '{CT} {P}.stg_gks_dict_evidence_line';
      SET dscv_head = '{CT} {P}.stg_gks_dict_scv';
    ELSE
      SET vf_scv_where = '';
      SET vf_cn_where  = '';
      SET del_head  = 'CREATE OR REPLACE TABLE `' || rec.schema_name || '.gks_dict_evidence_line`';
      SET dscv_head = 'CREATE OR REPLACE TABLE `' || rec.schema_name || '.gks_dict_scv`';
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_gks_scv', 'temp_gene_context_qualifiers', 'temp_moi_qualifiers',
        'temp_penetrance_qualifiers', 'temp_gks_scv_proposition', 'temp_gks_scv_target_proposition',
        'temp_scv_condition_names', 'temp_scv_citations', 'temp_scv_method',
        'stg_gks_dict_evidence_line', 'stg_gks_dict_scv'
      ]);
    END IF;

    ---------------------------------------------------------------------------
    -- Step 1: Create GKS SCV table (temp) — GLOBAL (shared source; feeds the global
    -- gks_dict_submitter, so it must NOT be filtered)
    ---------------------------------------------------------------------------
    SET query_scv_records = REPLACE("""
      {CT} {P}.temp_gks_scv
      AS
        SELECT
          scv.id,
          scv.version,
          IF(
            cpt.gks_type IS NOT NULL,
            -- VariantClinicalSignificance predicate is always 'hasClinicalSignificanceFor' (va-spec const);
            -- override the upstream clinvar_clinsig_types.final_predicate for that type to stay conformant
            -- and consistent with the RCV/VCV statement procs.
            STRUCT(
              cpt.gks_type as type,
              IF(cpt.gks_type = 'VariantClinicalSignificanceProposition',
                 'hasClinicalSignificanceFor', cct.final_predicate) as pred),
            STRUCT('ClinvarUndefinedProposition' as type, 'isClinvarUndefinedAssociationFor' as pred)
          ) as proposition,

          CASE scv.clinical_impact_assertion_type
            WHEN 'prognostic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'better outcome' THEN
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithBetterOutcomeFor' as pred)
                WHEN 'poor outcome' THEN
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithWorseOutcomeFor' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantPrognosticProposition' as type, 'associatedWithUndefinedOutcomeFor' as pred)
              END
            WHEN 'diagnostic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'supports diagnosis' THEN
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticInclusionCriterionFor' as pred)
                WHEN 'excludes diagnosis' THEN
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticExclusionCriterionFor' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantDiagnosticProposition' as type, 'isDiagnosticUndefinedCriterionFor' as pred)
              END
            WHEN 'therapeutic' THEN
              CASE scv.clinical_impact_clinical_significance
                WHEN 'sensitivity/response' THEN
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsSensitivityTo' as pred)
                WHEN 'resistance' THEN
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsResistanceTo' as pred)
                WHEN 'reduced sensitivity' THEN
                  -- va-spec has no 'reduced sensitivity' predicate; bundle these into the sensitivity propositions
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsSensitivityTo' as pred)
                ELSE
                  -- should never occur
                  STRUCT('VariantTherapeuticResponseProposition' as type, 'predictsUndefinedResponseTo' as pred)
              END
          END as evidence_line_target_proposition,

          cpt.code as proposition_type_code,
          scv.date_created,
          scv.date_last_updated,
          scv.local_key,
          scv.last_evaluated,
          cct.direction,
          scv.variation_id,
          scv.review_status,
          scv.submitted_classification,
          cct.label as classification_name,
          cct.classification_code,
          cct.strength_label as strength_name,
          cct.strength_code,
          cct.code_system as classif_and_strength_code_system,
          scv.method_type,
          scv.origin,
          scv.classif_type,
          scv.statement_type,
          scv.clinical_impact_assertion_type,
          scv.clinical_impact_clinical_significance,
          scv.classification_comment,
          -- -- ideally we'd move the drugTherapy extraction to the scv_summary table - future improvement.
          SPLIT(
            JSON_EXTRACT_SCALAR(
              ca.content,
              "$.Classification.SomaticClinicalImpact['@DrugForTherapeuticAssertion']"
            ),
            ';'
          ) as drugTherapy,
          `clinvar_ingest.parseAttributeSet`(ca.content) as attribs,
          (
            SELECT ARRAY_AGG(s)
            FROM (
              SELECT DISTINCT s
              FROM UNNEST(
                ARRAY_CONCAT(
                  `clinvar_ingest.parseCitations`(JSON_EXTRACT(ca.content,'$')),
                  `clinvar_ingest.parseCitations`(JSON_EXTRACT(ca.content,'$.Classification'))
                )
              ) AS s
            )
          ) as scvCitations,
          STRUCT (
            FORMAT('clinvar.submitter:%s',scv.submitter_id) as id,
            'Agent' as type,
            scv.submitter_name as name
          ) as submitter,
          sl.code AS submission_level,
          sl.label AS submission_level_label

        FROM `{S}.clinical_assertion` ca
        JOIN `{S}.scv_summary` scv
        ON
          scv.id = ca.id
        LEFT JOIN (
          `clinvar_ingest.clinvar_clinsig_types` cct
          JOIN `clinvar_ingest.clinvar_proposition_types` cpt
            ON cpt.code = cct.proposition_type
        ) ON
            cct.code = scv.classif_type
            AND
            cpt.statement_type_code = scv.statement_type
        LEFT JOIN `clinvar_ingest.submission_level` sl
          ON
            sl.rank = scv.rank
    """, '{S}', rec.schema_name);
    SET query_scv_records = REPLACE(query_scv_records, '{CT}', temp_create);
    SET query_scv_records = REPLACE(query_scv_records, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_records;

    ---------------------------------------------------------------------------
    -- Step 2: Create temp gene context qualifiers — GLOBAL (over-computed). Feeds ONLY
    -- the global temp_gks_scv_proposition / temp_gks_scv_target_proposition (Steps 5-6
    -- -> gks_dict_proposition), never the per-SCV finals, so it stays unfiltered.
    ---------------------------------------------------------------------------
    SET query_gene_context_qualifiers = REPLACE("""
      {CT} {P}.temp_gene_context_qualifiers
      AS
        WITH normalized_single_gene_variation AS (
          SELECT DISTINCT
            sgv.gene_id,
            'MappableConcept' AS type, 'gene' as conceptType,
            g.symbol as name,
            STRUCT(
              g.id as code,
              g.symbol as name,
              'https://www.ncbi.nlm.nih.gov/gene/' as system,
              [
                  FORMAT('https://identifiers.org/ncbigene:%s',g.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/gene/%s', g.id)
              ] as iris
            ) as primaryCoding,
            [
              STRUCT(
                STRUCT(
                  REGEXP_EXTRACT(g.hgnc_id, r'\\d+') as code,
                  'https://www.genenames.org' as system,
                  [
                      FORMAT('https://identifiers.org/hgnc:%s',REGEXP_EXTRACT(g.hgnc_id, r'\\d+')),
                      FORMAT(
                        'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%s',
                        REGEXP_EXTRACT(g.hgnc_id, r'\\d+')
                      )
                  ] as iris
                ) as coding,
                'exactMatch' as relation
              )
            ] as mappings
          from `{S}.single_gene_variation` sgv
          join `{S}.gene` g
          on
            g.id = sgv.gene_id
        ),
        scv_submitted_genes AS (
          SELECT
            cav.clinical_assertion_id,
            ARRAY_AGG(DISTINCT gene_symbol) as submitted_gene_symbols
          FROM `{S}.clinical_assertion_variation` cav
          CROSS JOIN UNNEST(clinvar_ingest.parseGeneLists(cav.content)) as g
          CROSS JOIN UNNEST(SPLIT(g.symbol)) as gene_symbol
          GROUP BY
            cav.clinical_assertion_id
        )
        SELECT
          scv.id as scv_id,
          nsgv.type,
          nsgv.conceptType,
          nsgv.name,
          nsgv.primaryCoding,
          nsgv.mappings,
          IF(
            ssg.submitted_gene_symbols is null OR ARRAY_LENGTH(ssg.submitted_gene_symbols) = 0,
            null,
            [
              STRUCT(
                'submittedGeneSymbols' as name,
                ssg.submitted_gene_symbols as value_string,
                null as value_object
              )
            ]
          ) as extensions
        from {P}.temp_gks_scv scv
        join `{S}.single_gene_variation` sgv
        on
          sgv.variation_id = scv.variation_id
        join normalized_single_gene_variation nsgv
        on
          nsgv.gene_id = sgv.gene_id
        left join scv_submitted_genes ssg
        on
          ssg.clinical_assertion_id = scv.id
        UNION ALL
        SELECT
          scv.id as scv_id,
          'MappableConcept' AS type, 'gene' as conceptType,
          'submitted genes were not normalized' as name,
          null as primaryCoding,
          null as mappings,
          [
            STRUCT(
              'submittedGeneSymbols' as name,
              ssg.submitted_gene_symbols as value_string,
              null as value_object
            )
          ]  as extensions
        from {P}.temp_gks_scv scv
        join scv_submitted_genes ssg
        on
          ssg.clinical_assertion_id = scv.id
        left join `{S}.single_gene_variation` sgv
        on
          sgv.variation_id = scv.variation_id
        left join normalized_single_gene_variation nsgv
        on
          nsgv.gene_id = sgv.gene_id
        where
          nsgv.gene_id is null
    """, '{S}', rec.schema_name);
    SET query_gene_context_qualifiers = REPLACE(query_gene_context_qualifiers, '{CT}', temp_create);
    SET query_gene_context_qualifiers = REPLACE(query_gene_context_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_gene_context_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 3: Create temp mode of inheritance qualifiers — GLOBAL (over-computed)
    ---------------------------------------------------------------------------
    SET query_moi_qualifiers = REPLACE("""
      {CT} {P}.temp_moi_qualifiers
      AS
        SELECT
          scv.id as scv_id,
          'MappableConcept' AS type, 'modeOfInheritance' as conceptType,
          a.attribute.value as name,
          IF(
            hpo.id is null,
            null,
            STRUCT(
              hpo.id as code,
              hpo.lbl as name,
              'https://hpo.jax.org/' as system,
              [
                  FORMAT('https://identifiers.org/%s',hpo.id),
                  FORMAT('https://hpo.jax.org/browse/term/%s', hpo.id)
              ] as iris
            )
          ) as primaryCoding,
          [
            STRUCT(
              'submittedModeOfInheritance' as name,
              a.attribute.value as value_string,
              null as value_object
            )
          ] as extensions
        from {P}.temp_gks_scv scv
        CROSS JOIN UNNEST(scv.attribs) as a
        LEFT JOIN `clinvar_ingest.hpo_terms` hpo
        ON
          LOWER(hpo.lbl) = LOWER(a.attribute.value)
        WHERE
          a.attribute.type = 'ModeOfInheritance'
    """, '{S}', rec.schema_name);
    SET query_moi_qualifiers = REPLACE(query_moi_qualifiers, '{CT}', temp_create);
    SET query_moi_qualifiers = REPLACE(query_moi_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_moi_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 4: Create temp penetrance qualifiers — GLOBAL (over-computed)
    ---------------------------------------------------------------------------
    SET query_penetrance_qualifiers = REPLACE("""
      {CT} {P}.temp_penetrance_qualifiers
      AS
        SELECT
          scv.id as scv_id,
          'MappableConcept' AS type, 'penetrance' as conceptType,
          IF(scv.classif_type IN ('p-lp','lp-lp'), 'low', 'risk') as name,
          [
            STRUCT(
              'submittedClassification' as name,
              scv.submitted_classification as value_string,
              null as value_object
            )
          ] as extensions
        FROM {P}.temp_gks_scv scv
        WHERE
          scv.classif_type in ('p-lp', 'lp-lp', 'era', 'lra','ura')
    """, '{S}', rec.schema_name);
    SET query_penetrance_qualifiers = REPLACE(query_penetrance_qualifiers, '{CT}', temp_create);
    SET query_penetrance_qualifiers = REPLACE(query_penetrance_qualifiers, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_penetrance_qualifiers;

    ---------------------------------------------------------------------------
    -- Step 5: Create SCV proposition table (temp) — GLOBAL. Feeds the globally
    -- recomputed gks_dict_proposition (embeds geneContextQualifier, a variation/gene-
    -- driven struct outside the SCV changed-set contract) AND the per-SCV gks_dict_scv
    -- (which filters on scv.id itself), so this temp stays UNFILTERED.
    ---------------------------------------------------------------------------
    SET query_scv_proposition = REPLACE("""
      {CT} {P}.temp_gks_scv_proposition
      AS
        WITH base AS (
          SELECT
            scv.id as scv_id,
            scv.proposition_type_code,
            scv.variation_id,
            -- proposition.type is never null (Step 1 fallback sets 'ClinvarUndefinedProposition')
            scv.proposition.type as p_type,
            (scv.proposition.type LIKE 'Clinvar%') as is_custom,
            scv.proposition.pred as predicate,
            -- obj_ref = the 4-source objectCondition COALESCE, computed once (a Condition/ConditionSet pointer)
            COALESCE(
              scs.extensions.value_submitted_condition.condition,
              scs.extensions.value_submitted_condition.conditionSet,
              scs.extensions.value_submitted_condition_set.condition,
              scs.extensions.value_submitted_condition_set.conditionSet
            ) as obj_ref,
            (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as gene_ctx,
            (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as moi_ctx,
            (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetrance_ctx,
            (sgq.scv_id IS NOT NULL) as has_gene,
            (smq.scv_id IS NOT NULL) as has_moi,
            (spq.scv_id IS NOT NULL) as has_penetrance
          FROM {P}.temp_gks_scv scv
          LEFT JOIN {P}.temp_gene_context_qualifiers sgq
          ON
            sgq.scv_id = scv.id
          LEFT JOIN {P}.temp_moi_qualifiers smq
          ON
            smq.scv_id = scv.id
          LEFT JOIN {P}.temp_penetrance_qualifiers spq
          ON
            spq.scv_id = scv.id
          LEFT JOIN `{S}.gks_scv_condition_sets` scs
          ON
            scs.scv_id = scv.id
        )
        SELECT
          scv_id,
          FORMAT('%s-%s', scv_id, UPPER(IFNULL(proposition_type_code, 'UNDEF'))) as id,
          -- custom types collapse to CustomProposition + customPropositionType; standard keep their specific type
          IF(is_custom, 'CustomProposition', p_type) as type,
          IF(is_custom, p_type, CAST(NULL AS STRING)) as customPropositionType,
          -- standard uses subjectVariant; custom uses subject (same variation pointer)
          IF(is_custom, CAST(NULL AS STRING), FORMAT('#/variation/clinvar:%s', variation_id)) as subjectVariant,
          IF(is_custom, FORMAT('#/variation/clinvar:%s', variation_id), CAST(NULL AS STRING)) as subject,
          predicate,
          -- object field is 3-way: custom->object, standard Oncogenicity->objectTumorType, other standard->objectCondition (same obj_ref value)
          IF(is_custom OR p_type = 'VariantOncogenicityProposition', CAST(NULL AS STRING), obj_ref) as objectCondition,
          IF((NOT is_custom) AND p_type = 'VariantOncogenicityProposition', obj_ref, CAST(NULL AS STRING)) as objectTumorType,
          IF(is_custom, obj_ref, CAST(NULL AS STRING)) as object,
          -- standard keeps typed qualifiers; custom nulls them (NULL typed by the struct branch)
          IF(is_custom, NULL, gene_ctx) as geneContextQualifier,
          IF(is_custom, NULL, moi_ctx) as modeOfInheritanceQualifier,
          IF(is_custom, NULL, penetrance_ctx) as penetranceQualifier,
          -- custom: generic qualifiers[] name/value (value carried as JSON to tolerate differing struct schemas)
          IF(is_custom,
            ARRAY_CONCAT(
              IF(has_gene, [STRUCT('geneContext' AS name, TO_JSON(gene_ctx) AS value)], []),
              IF(has_moi, [STRUCT('modeOfInheritance' AS name, TO_JSON(moi_ctx) AS value)], []),
              IF(has_penetrance, [STRUCT('penetrance' AS name, TO_JSON(penetrance_ctx) AS value)], [])
            ),
            CAST(NULL AS ARRAY<STRUCT<name STRING, value JSON>>)) as qualifiers
        FROM base
    """, '{S}', rec.schema_name);
    SET query_scv_proposition = REPLACE(query_scv_proposition, '{CT}', temp_create);
    SET query_scv_proposition = REPLACE(query_scv_proposition, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_proposition;

    ---------------------------------------------------------------------------
    -- Step 6: Create SCV target proposition table (temp) — GLOBAL. Feeds the globally
    -- recomputed gks_dict_proposition (embeds geneContextQualifier) plus the per-SCV
    -- gks_dict_evidence_line / gks_dict_scv (which filter on scv.id themselves), so
    -- this temp stays UNFILTERED.
    ---------------------------------------------------------------------------
    SET query_scv_target_proposition = REPLACE("""
      {CT} {P}.temp_gks_scv_target_proposition
      AS
        WITH scv_drugs AS (
          SELECT
            scv_id,
            ARRAY_AGG(STRUCT(drug.name, 'MappableConcept' AS type, 'Drug' as conceptType)) as therapies,
            STRUCT(CAST(null as string) as name, CAST(null as string) as type, CAST(null as string) as conceptType) as therapy
          FROM (
            SELECT
              scv.id as scv_id,
              drug as name
            FROM {P}.temp_gks_scv scv
            CROSS JOIN UNNEST(scv.drugTherapy) as drug
          ) drug
          GROUP BY
            scv_id
          HAVING COUNT(*) > 1
          UNION ALL
          SELECT
            scv.id as scv_id,
            [STRUCT(CAST(null as string) as name, CAST(null as string) as type, CAST(null as string) as conceptType)] as therapies,
            STRUCT(
              ARRAY_AGG(drug)[SAFE_OFFSET(0)] as name,
              'MappableConcept' AS type, 'Drug' as conceptType
            ) as therapy
          FROM {P}.temp_gks_scv scv
          CROSS JOIN UNNEST(scv.drugTherapy) as drug
          GROUP BY
            scv.id
          HAVING COUNT(*) = 1
        )
        SELECT
          scv.id as scv_id,
          FORMAT('%s-%s', scv.id, UPPER(tp.code)) as id,
          scv.evidence_line_target_proposition.type as type,
          FORMAT('#/variation/clinvar:%s', scv.variation_id) as subjectVariant,
          scv.evidence_line_target_proposition.pred as predicate,
          IF(
            scv.clinical_impact_assertion_type IS DISTINCT FROM 'therapeutic',
            COALESCE(
              scs.extensions.value_submitted_condition.condition,
              scs.extensions.value_submitted_condition.conditionSet,
              scs.extensions.value_submitted_condition_set.condition,
              scs.extensions.value_submitted_condition_set.conditionSet
            ),
            null
          ) as objectCondition,
          -- Single va-spec objectTherapy: a Therapy (MappableConcept) when one drug, else a TherapyGroup.
          -- TherapyGroup is a ConceptSet: type='ConceptSet', membershipOperator, and concepts[] (>=2 Therapy).
          IF(
            ARRAY_LENGTH(sd.therapies) > 1,
            TO_JSON(STRUCT('ConceptSet' AS type, sd.therapies AS concepts, 'AND' AS membershipOperator)),
            TO_JSON(sd.therapy)
          ) as objectTherapy,
          IF(
            scv.clinical_impact_assertion_type IS NOT DISTINCT FROM 'therapeutic',
            COALESCE(
              scs.extensions.value_submitted_condition.condition,
              scs.extensions.value_submitted_condition.conditionSet,
              scs.extensions.value_submitted_condition_set.condition,
              scs.extensions.value_submitted_condition_set.conditionSet
            ),
            null
          ) as conditionQualifier,
          (SELECT AS STRUCT sgq.* EXCEPT(scv_id)) as geneContextQualifier,
          (SELECT AS STRUCT smq.* EXCEPT(scv_id)) as modeOfInheritanceQualifier,
          (SELECT AS STRUCT spq.* EXCEPT(scv_id)) as penetranceQualifier
        FROM {P}.temp_gks_scv scv
        LEFT JOIN {P}.temp_gene_context_qualifiers sgq
        ON
          sgq.scv_id = scv.id
        LEFT JOIN {P}.temp_moi_qualifiers smq
        ON
          smq.scv_id = scv.id
        LEFT JOIN {P}.temp_penetrance_qualifiers spq
        ON
          spq.scv_id = scv.id
        LEFT JOIN `{S}.gks_scv_condition_sets` scs
        ON
          scs.scv_id = scv.id
        LEFT JOIN scv_drugs sd
        ON
          sd.scv_id = scv.id
        LEFT JOIN `clinvar_ingest.clinvar_proposition_types` tp
        ON
          tp.gks_type = scv.evidence_line_target_proposition.type
        WHERE
          scv.evidence_line_target_proposition IS NOT NULL
    """, '{S}', rec.schema_name);
    SET query_scv_target_proposition = REPLACE(query_scv_target_proposition, '{CT}', temp_create);
    SET query_scv_target_proposition = REPLACE(query_scv_target_proposition, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_target_proposition;

    ---------------------------------------------------------------------------
    -- Step 7a: Materialize condition names (lightweight lookup) — per-SCV ({VF_CN};
    -- feeds ONLY gks_dict_scv)
    ---------------------------------------------------------------------------
    SET query_scv_condition_names = REPLACE("""
      {CT} {P}.temp_scv_condition_names AS
      SELECT
        scv_id,
        CASE
          WHEN extensions.value_submitted_condition.name IS NOT NULL
            THEN extensions.value_submitted_condition.name
          WHEN ARRAY_LENGTH(extensions.value_submitted_condition_set.concepts) >= 2
            THEN FORMAT('%d conditions', ARRAY_LENGTH(extensions.value_submitted_condition_set.concepts))
          ELSE 'unspecified condition'
        END AS condition_name
      FROM `{S}.gks_scv_condition_sets`
      {VF_CN}
    """, '{S}', rec.schema_name);
    SET query_scv_condition_names = REPLACE(query_scv_condition_names, '{VF_CN}', vf_cn_where);
    SET query_scv_condition_names = REPLACE(query_scv_condition_names, '{CT}', temp_create);
    SET query_scv_condition_names = REPLACE(query_scv_condition_names, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_condition_names;

    ---------------------------------------------------------------------------
    -- Step 7b: Materialize citations — GLOBAL (over-computed; LEFT-JOINed by scv id
    -- into the already-filtered gks_dict_scv)
    ---------------------------------------------------------------------------
    SET query_scv_citations = REPLACE("""
      {CT} {P}.temp_scv_citations AS
      WITH scv_citation AS (
        SELECT
          scv.id,
          STRUCT(
            'Document' as type,
            IF(lower(cid.source) = 'pubmed', cid.id, null) as pmid,
            IF(lower(cid.source) = 'doi', cid.id, null) as doi,
            [CASE
            WHEN c.url IS NOT NULL THEN
              c.url
            WHEN LOWER(cid.source) = 'pubmed' THEN
              FORMAT('https://pubmed.ncbi.nlm.nih.gov/%s',cid.id)
            WHEN LOWER(cid.source) = 'pmc' THEN
              FORMAT('https://europepmc.org/article/PMC/%s',cid.id)
            WHEN LOWER(cid.source) = 'doi' THEN
              FORMAT('https://doi.org/%s',cid.id)
            WHEN LOWER(cid.source) = 'bookshelf' THEN
              FORMAT('https://www.ncbi.nlm.nih.gov/books/%s',cid.id)
            ELSE
              cid.curie
            END] as urls
          ) as doc
        FROM {P}.temp_gks_scv scv
        CROSS JOIN UNNEST(scv.scvCitations) as c
        CROSS JOIN UNNEST(c.id) as cid
        WHERE
          cid.source IS NOT NULL
          OR c.url IS NOT NULL
      )
      SELECT
        id,
        ARRAY_AGG(doc) as reportedIn
      FROM scv_citation
      GROUP BY id
    """, '{S}', rec.schema_name);
    SET query_scv_citations = REPLACE(query_scv_citations, '{CT}', temp_create);
    SET query_scv_citations = REPLACE(query_scv_citations, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_citations;

    ---------------------------------------------------------------------------
    -- Step 7c: Materialize assertion method — GLOBAL (over-computed; LEFT-JOINed by
    -- scv id into the already-filtered gks_dict_scv)
    ---------------------------------------------------------------------------
    SET query_scv_method = REPLACE("""
      {CT} {P}.temp_scv_method AS
      -- there are less than 10 assertion method attributes that contain multiple citations
      --   these are likely mis-submitted info since they should be in the interp citations
      --   not the assertion method citations which should almost exclusively be 1 item
      --   for now we comprimise by grouping any multi- citation id values together as a string
      --   and hoping that the citation source and url will aggregate to the same single record.
      --   this hacky policy works around the bad data as of 2024-04-07
      SELECT
        scv.id,
        STRUCT (
          'Method' as type,
          scv.method_type as methodType,
          a.attribute.value as name,
          IF(
            (cid.source is not null OR c.url is not null),
            STRUCT(
              'Document' as type,
              IF(LOWER(cid.source) = 'pubmed', STRING_AGG(cid.id), null) as pmid,
              IF(LOWER(cid.source) = 'doi', STRING_AGG(cid.id), null) as doi,
              [
                CASE
                WHEN c.url IS NOT NULL THEN
                  c.url
                WHEN LOWER(cid.source) = 'pubmed' THEN
                  FORMAT('https://pubmed.ncbi.nlm.nih.gov/%s',STRING_AGG(cid.id))
                WHEN LOWER(cid.source) = 'pmc' THEN
                  FORMAT('https://europepmc.org/article/PMC/%s',STRING_AGG(cid.id))
                WHEN LOWER(cid.source) = 'doi' THEN
                  FORMAT('https://doi.org/%s',STRING_AGG(cid.id))
                WHEN LOWER(cid.source) = 'bookshelf' THEN
                  FORMAT('https://www.ncbi.nlm.nih.gov/books/%s',STRING_AGG(cid.id))
                ELSE
                  FORMAT('%s:%s', cid.source, STRING_AGG(cid.id))
                END
              ] as urls
            ),
            null
          ) as reportedIn
        ) as specifiedBy
      FROM {P}.temp_gks_scv scv
      CROSS JOIN UNNEST(scv.attribs) as a
      LEFT JOIN UNNEST(a.citation) as c
      LEFT JOIN UNNEST(c.id) as cid
      WHERE
        a.attribute.type = 'AssertionMethod'
      GROUP BY
        scv.id,
        a.attribute.value,
        cid.source,
        c.url,
        scv.method_type
    """, '{S}', rec.schema_name);
    SET query_scv_method = REPLACE(query_scv_method, '{CT}', temp_create);
    SET query_scv_method = REPLACE(query_scv_method, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_scv_method;

    ---------------------------------------------------------------------------
    -- Step 7d: Dictionary table - submitters — GLOBAL dedup (keyed by
    -- clinvar.submitter:{id}). ALWAYS globally recomputed from the unfiltered
    -- temp_gks_scv so no submitter is lost when only unchanged SCVs reference it.
    ---------------------------------------------------------------------------
    SET dict_submitter_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_submitter`
      AS
      SELECT
        scv.submitter.id as key,
        ANY_VALUE(JSON_STRIP_NULLS(TO_JSON(scv.submitter), remove_empty => TRUE)) as value
      FROM {P}.temp_gks_scv scv
      WHERE scv.submitter.id IS NOT NULL
      GROUP BY scv.submitter.id
    """, '{S}', rec.schema_name);
    SET dict_submitter_query = REPLACE(dict_submitter_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_submitter_query;

    ---------------------------------------------------------------------------
    -- Step 7e: Dictionary table - propositions — GLOBAL recompute (like
    -- gks_dict_submitter). Although keyed per-SCV, the proposition value embeds
    -- geneContextQualifier, a variation/gene-derived struct (single_gene_variation +
    -- gene) that changes independently of the SCV's own clinical_assertion or trait —
    -- a driver NOT modeled by scv_changed_ids. Carrying it forward per-SCV would
    -- leave stale gene context on SCVs whose variation changed while unmodified
    -- (verified: change_type='exact_match' SCVs whose variation is diff_variation
    -- 'modified' gaining a single_gene_variation mapping). Recomputing globally is the
    -- safe fix (a partial variation-only cascade would still miss diff_gene attribute
    -- edits). See header + the report for the recommended systemic fix in
    -- gks_scv_changed (a variation/gene cascade) that would let this go per-SCV.
    ---------------------------------------------------------------------------
    SET dict_proposition_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_proposition`
      AS
      SELECT
        sp.id as key,
        JSON_STRIP_NULLS(TO_JSON(
          (SELECT AS STRUCT sp.* EXCEPT(scv_id))
        ), remove_empty => TRUE) as value
      FROM {P}.temp_gks_scv_proposition sp
      UNION ALL
      SELECT
        stp.id as key,
        JSON_STRIP_NULLS(TO_JSON(
          (SELECT AS STRUCT stp.* EXCEPT(scv_id))
        ), remove_empty => TRUE) as value
      FROM {P}.temp_gks_scv_target_proposition stp
    """, '{S}', rec.schema_name);
    SET dict_proposition_query = REPLACE(dict_proposition_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_proposition_query;

    ---------------------------------------------------------------------------
    -- Step 7f: Dictionary table - evidence lines — per-SCV ({DEL_HEAD} target;
    -- {VF_SCV} on the temp_gks_scv alias). Trait-dependent (embeds the submitted-
    -- condition struct from gks_scv_condition_sets); the trait cascade in
    -- scv_changed_ids re-derives affected SCVs.
    ---------------------------------------------------------------------------
    SET dict_evidence_line_query = REPLACE("""
      {DEL_HEAD}
      AS
      WITH null_templates AS (
        SELECT
          STRUCT(
            CAST(null as STRING) as conditionSet,
            CAST(null as STRING) as condition,
            CAST(null as STRING) as multiple_condition_explanation,
            [STRUCT(
              CAST(null as STRING) AS id,
              CAST(null as STRING) AS name,
              CAST(null as STRING) AS type,
              CAST(null as STRING) AS medgen_id,
              [STRUCT(CAST(null as STRING) AS code, CAST(null as STRING) AS system)] AS xrefs,
              STRUCT(CAST(null as STRING) AS id, CAST(null as STRING) AS name) AS original_medgen_match,
              CAST(null as STRING) AS direct_match,
              CAST(null as STRING) AS normalized_match,
              CAST(null as STRING) AS normalized_resolution,
              STRUCT(CAST(null as STRING) AS type, CAST(null as STRING) AS ref, CAST(null as STRING) AS value) AS mapping
            )] as concepts
          ) AS null_cs,
          STRUCT(
            CAST(null as STRING) AS conditionSet,
            CAST(null as STRING) AS condition,
            CAST(null as STRING) AS id,
            CAST(null as STRING) AS name,
            CAST(null as STRING) AS type,
            CAST(null as STRING) AS medgen_id,
            [STRUCT(CAST(null as STRING) AS code, CAST(null as STRING) AS system)] AS xrefs,
            STRUCT(CAST(null as STRING) AS id, CAST(null as STRING) AS name) AS original_medgen_match,
            CAST(null as STRING) AS direct_match,
            CAST(null as STRING) AS normalized_match,
            CAST(null as STRING) AS normalized_resolution,
            STRUCT(CAST(null as STRING) AS type, CAST(null as STRING) AS ref, CAST(null as STRING) AS value) AS mapping
          ) AS null_c
      )
      SELECT
        FORMAT('clinvar.submission:%s.%i', scv.id, scv.version) as id,
        'EvidenceLine' as type,
        -- Delivery-group-qualified target-proposition reference (Phase 2). Target props are always
        -- standard: Diagnostic/Prognostic -> varcond, TherapeuticResponse -> vartherapy.
        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN stp.type = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN stp.type IN ('VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped target proposition type: %t', stp.type))
          END,
          stp.id) as proposition,
        'supports' as directionOfEvidenceProvided,
        CASE scv.classification_code
          WHEN 'tier 1' THEN
            STRUCT('MappableConcept' AS type, 'Outcome' as conceptType, 'Level A/B' as name)
          WHEN 'tier 2' THEN
            STRUCT('MappableConcept' AS type, 'Outcome' as conceptType, 'Level C/D' as name)
          ELSE
            STRUCT('MappableConcept' AS type, 'Outcome' as conceptType, scv.classification_code as name)
        END as evidenceOutcome,
        IF(
          spc.extensions.value_submitted_condition_set IS NOT NULL,
          [STRUCT('submittedConditionSet' as name, spc.extensions.value_submitted_condition_set, nt.null_c as value_submitted_condition)],
          IF(spc.extensions.value_submitted_condition IS NOT NULL,
            [STRUCT('submittedCondition' as name, nt.null_cs as value_submitted_condition_set, spc.extensions.value_submitted_condition as value_submitted_condition)],
            []
          )
        ) as extensions
      FROM {P}.temp_gks_scv scv
      CROSS JOIN null_templates nt
      JOIN `{S}.gks_scv_condition_sets` spc
      ON spc.scv_id = scv.id
      JOIN {P}.temp_gks_scv_target_proposition stp
      ON stp.scv_id = scv.id
      {VF_SCV}
    """, '{S}', rec.schema_name);
    SET dict_evidence_line_query = REPLACE(dict_evidence_line_query, '{DEL_HEAD}', del_head);
    SET dict_evidence_line_query = REPLACE(dict_evidence_line_query, '{VF_SCV}', vf_scv_where);
    SET dict_evidence_line_query = REPLACE(dict_evidence_line_query, '{CT}', temp_create);
    SET dict_evidence_line_query = REPLACE(dict_evidence_line_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_evidence_line_query;

    ---------------------------------------------------------------------------
    -- Step 8: Create statement SCV table — per-SCV ({DSCV_HEAD} target; {VF_SCV} on
    -- the temp_gks_scv alias). Trait-dependent (embeds the submitted-condition struct
    -- from gks_scv_condition_sets).
    ---------------------------------------------------------------------------
    SET query_statement_scv_pre = REPLACE("""
      {DSCV_HEAD}
      as
      WITH null_templates AS (
        SELECT
          STRUCT(
            CAST(null as STRING) as conditionSet,
            CAST(null as STRING) as condition,
            CAST(null as STRING) as multiple_condition_explanation,
            [STRUCT(
              CAST(null as STRING) AS id,
              CAST(null as STRING) AS name,
              CAST(null as STRING) AS type,
              CAST(null as STRING) AS medgen_id,
              [STRUCT(CAST(null as STRING) AS code, CAST(null as STRING) AS system)] AS xrefs,
              STRUCT(CAST(null as STRING) AS id, CAST(null as STRING) AS name) AS original_medgen_match,
              CAST(null as STRING) AS direct_match,
              CAST(null as STRING) AS normalized_match,
              CAST(null as STRING) AS normalized_resolution,
              STRUCT(CAST(null as STRING) AS type, CAST(null as STRING) AS ref, CAST(null as STRING) AS value) AS mapping
            )] as concepts
          ) AS null_cs,
          STRUCT(
            CAST(null as STRING) AS conditionSet,
            CAST(null as STRING) AS condition,
            CAST(null as STRING) AS id,
            CAST(null as STRING) AS name,
            CAST(null as STRING) AS type,
            CAST(null as STRING) AS medgen_id,
            [STRUCT(CAST(null as STRING) AS code, CAST(null as STRING) AS system)] AS xrefs,
            STRUCT(CAST(null as STRING) AS id, CAST(null as STRING) AS name) AS original_medgen_match,
            CAST(null as STRING) AS direct_match,
            CAST(null as STRING) AS normalized_match,
            CAST(null as STRING) AS normalized_resolution,
            STRUCT(CAST(null as STRING) AS type, CAST(null as STRING) AS ref, CAST(null as STRING) AS value) AS mapping
          ) AS null_c
      )
      SELECT
        FORMAT('clinvar.submission:%s.%i', scv.id, scv.version) as id,
        'Statement' as type,
        -- Delivery-group-qualified proposition reference (Phase 2). Canonical group mapping keyed on the
        -- raw gks type (custom rows carry it in customPropositionType, standard rows in type).
        FORMAT('#/%s-proposition/%s',
          CASE
            WHEN COALESCE(sp.customPropositionType, sp.type) LIKE 'Clinvar%' THEN 'varcustom'
            WHEN COALESCE(sp.customPropositionType, sp.type) = 'VariantOncogenicityProposition' THEN 'vartumor'
            WHEN COALESCE(sp.customPropositionType, sp.type) = 'VariantTherapeuticResponseProposition' THEN 'vartherapy'
            WHEN COALESCE(sp.customPropositionType, sp.type) IN (
              'VariantPathogenicityProposition','VariantClinicalSignificanceProposition',
              'VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond'
            ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', COALESCE(sp.customPropositionType, sp.type)))
          END,
          sp.id) as proposition,
        STRUCT(
          'MappableConcept' AS type, 'Classification' AS conceptType,
          scv.submitted_classification as name,
          IF(
            scv.classification_code IS NOT NULL,
            STRUCT(scv.classification_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding,
          [STRUCT(
            'description' AS name,
            CONCAT(
              'for ', COALESCE(scn.condition_name, 'unspecified condition'), '\\n',
              'Classification is based on the ', COALESCE(scv.submission_level_label, 'unknown'), ' submission', '\\n',
              COALESCE(FORMAT_DATE('%b %Y', scv.last_evaluated), '(-)'), ' by ', scv.submitter.name
            ) AS value_string
          )] AS extensions
        ) as classification,
         STRUCT(
          'MappableConcept' AS type, 'Strength' AS conceptType,
          scv.strength_name as name,
          IF(
            scv.strength_code IS NOT NULL,
            STRUCT(scv.strength_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding
        ) as strength,
        scv.direction,
        STRUCT('MappableConcept' AS type, 'Confidence' AS conceptType, scv.submission_level_label AS name) as confidence,
        scv.classification_comment as description,
        [
          STRUCT(
            'Contribution' as type,
            FORMAT('#/submitter/%s', scv.submitter.id) as contributor,
            scv.date_last_updated as date,
            'submitted' as activityType
          ),
          STRUCT(
            'Contribution' as type,
            FORMAT('#/submitter/%s', scv.submitter.id) as contributor,
            scv.date_created as date,
            'created' as activityType
          ),
          STRUCT(
            'Contribution' as type,
            FORMAT('#/submitter/%s', scv.submitter.id) as contributor,
            scv.last_evaluated as date,
            'evaluated' as activityType
          )
        ] as contributions,
        sm.specifiedBy,
        sm.specifiedBy.methodType as methodType,
        sm.specifiedBy.name as methodName,
        scit.reportedIn,
        ARRAY_CONCAT(
          [
            STRUCT('clinvarScvId' as name, scv.id as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition),
            STRUCT('clinvarScvVersion' as name, CAST(scv.version AS STRING) as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition)
          ],
          IF(
            spc.extensions.value_submitted_condition_set IS NOT NULL,
            [STRUCT('submittedConditionSet' as name, CAST(NULL as STRING) as value_string, spc.extensions.value_submitted_condition_set, nt.null_c as value_submitted_condition)],
            IF(spc.extensions.value_submitted_condition IS NOT NULL,
              [STRUCT('submittedCondition' as name, CAST(NULL as STRING) as value_string, nt.null_cs as value_submitted_condition_set, spc.extensions.value_submitted_condition as value_submitted_condition)],
              []
            )
          ),
          IF(
            scv.review_status IS NULL, [],
            [STRUCT('clinvarScvReviewStatus' as name, scv.review_status as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition)]
          ),
          IF(
            scv.submitted_classification IS NOT DISTINCT FROM scv.classification_name, [],
            [STRUCT('submittedScvClassification' as name, scv.submitted_classification as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition)]
          ),
          IF(
            scv.local_key IS NULL, [],
            [STRUCT('submittedScvLocalKey' as name, scv.local_key as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition)]
          ),
          IF(
            scv.submission_level IS NULL, [],
            [STRUCT('submissionLevel' as name, scv.submission_level as value_string, nt.null_cs as value_submitted_condition_set, nt.null_c as value_submitted_condition)]
          )
        ) as extensions,
        IF (
          stp.id is not null,
          [FORMAT('#/evidenceLine/clinvar.submission:%s.%i', scv.id, scv.version)],
          []
        ) as hasEvidenceLines
      FROM {P}.temp_gks_scv scv
      CROSS JOIN null_templates nt
      JOIN {P}.temp_gks_scv_proposition sp
      ON
        sp.scv_id = scv.id
      JOIN `{S}.gks_scv_condition_sets` spc
      ON
        spc.scv_id = scv.id
      LEFT JOIN {P}.temp_gks_scv_target_proposition stp
      ON
        stp.scv_id = scv.id
      LEFT JOIN {P}.temp_scv_method sm
      ON
        sm.id = scv.id
      LEFT JOIN {P}.temp_scv_citations scit
      ON
        scit.id = scv.id
      LEFT JOIN {P}.temp_scv_condition_names scn
      ON
        scn.scv_id = scv.id
      {VF_SCV}
    """, '{S}', rec.schema_name);
    SET query_statement_scv_pre = REPLACE(query_statement_scv_pre, '{DSCV_HEAD}', dscv_head);
    SET query_statement_scv_pre = REPLACE(query_statement_scv_pre, '{VF_SCV}', vf_scv_where);
    SET query_statement_scv_pre = REPLACE(query_statement_scv_pre, '{CT}', temp_create);
    SET query_statement_scv_pre = REPLACE(query_statement_scv_pre, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_statement_scv_pre;

    -----------------------------------------------------------------------
    -- Step 9 (incremental only): UNION-CTAS merge the two per-SCV outputs — carry
    -- forward the unchanged baseline rows (scv NOT in changed∪removed) and union in
    -- the freshly staged changed rows. The scv id is recovered from each output's pk
    -- by PARSING (the stored value dropped scv_id). Explicit column lists so any
    -- schema/column-order drift errors (the version-invalidation signal) instead of
    -- silently corrupting. NULL-safe anti-join (LEFT JOIN … IS NULL) rather than
    -- NOT IN so a NULL scv_id cannot empty the carry-forward. gks_dict_proposition is
    -- NOT merged here — it is globally recomputed (Step 7e).
    -----------------------------------------------------------------------
    IF eff_incremental THEN

      -- gks_dict_evidence_line: id = clinvar.submission:{scv}.{ver};
      --   scv = SPLIT(SPLIT(id,':')[1], '.')[0]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_evidence_line` AS
        SELECT
          b.id, b.type, b.proposition, b.directionOfEvidenceProvided,
          b.evidenceOutcome, b.extensions
        FROM `{BASE}.gks_dict_evidence_line` b
        LEFT JOIN (
          SELECT scv_id FROM `{S}.scv_changed_ids`
          UNION DISTINCT
          SELECT scv_id FROM `{S}.scv_removed_ids`
        ) x ON x.scv_id = SPLIT(SPLIT(b.id, ':')[OFFSET(1)], '.')[OFFSET(0)]
        WHERE x.scv_id IS NULL
        UNION ALL
        SELECT
          id, type, proposition, directionOfEvidenceProvided,
          evidenceOutcome, extensions
        FROM {P}.stg_gks_dict_evidence_line
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- gks_dict_scv: id = clinvar.submission:{scv}.{ver};
      --   scv = SPLIT(SPLIT(id,':')[1], '.')[0]
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_scv` AS
        SELECT
          b.id, b.type, b.proposition, b.classification, b.strength, b.direction,
          b.confidence, b.description, b.contributions, b.specifiedBy, b.methodType,
          b.methodName, b.reportedIn, b.extensions, b.hasEvidenceLines
        FROM `{BASE}.gks_dict_scv` b
        LEFT JOIN (
          SELECT scv_id FROM `{S}.scv_changed_ids`
          UNION DISTINCT
          SELECT scv_id FROM `{S}.scv_removed_ids`
        ) x ON x.scv_id = SPLIT(SPLIT(b.id, ':')[OFFSET(1)], '.')[OFFSET(0)]
        WHERE x.scv_id IS NULL
        UNION ALL
        SELECT
          id, type, proposition, classification, strength, direction,
          confidence, description, contributions, specifiedBy, methodType,
          methodName, reportedIn, extensions, hasEvidenceLines
        FROM {P}.stg_gks_dict_scv
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

    END IF;

    -------------------------------------------------------------------------
    -- Coverage validation (BOTH modes; in incremental mode it also proves the merge
    -- is complete — no carry-forward gap, no double-count).
    -- gks_dict_scv is strictly 1:1 with scv_summary(id, version): its id is
    -- 'clinvar.submission:{scv}.{ver}', so SPLIT(id,':')[OFFSET(1)] = '{scv}.{ver}',
    -- which must equal CONCAT(scv_summary.id, '.', version). A nonzero delta =
    -- missing / extra / duplicate statement record. The count-equality term catches a
    -- duplicate (scv,ver) that the set-EXCEPT terms would dedup away. (Verified 1:1 on
    -- 2026-07-20: 6,397,248 rows both sides, 0 dups, 0 orphans either way.)
    -------------------------------------------------------------------------
    EXECUTE IMMEDIATE FORMAT("""
      SELECT
        ABS((SELECT COUNT(*) FROM `%s.scv_summary`) - (SELECT COUNT(*) FROM `%s.gks_dict_scv`))
        + (SELECT COUNT(*) FROM (
             SELECT CONCAT(id, '.', CAST(version AS STRING)) FROM `%s.scv_summary`
             EXCEPT DISTINCT
             SELECT SPLIT(id, ':')[OFFSET(1)] FROM `%s.gks_dict_scv`))
        + (SELECT COUNT(*) FROM (
             SELECT SPLIT(id, ':')[OFFSET(1)] FROM `%s.gks_dict_scv`
             EXCEPT DISTINCT
             SELECT CONCAT(id, '.', CAST(version AS STRING)) FROM `%s.scv_summary`))
    """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name,
         rec.schema_name, rec.schema_name)
    INTO scv_cov_mismatch;

    IF scv_cov_mismatch != 0 THEN
      RAISE USING MESSAGE = FORMAT(
        'gks_scv_statement validation FAILED for %s: gks_dict_scv is not 1:1 with scv_summary(id,version) (count/set delta = %t) — missing, extra, or duplicate statement record',
        rec.schema_name, scv_cov_mismatch);
    END IF;

    -- gks_dict_evidence_line is NOT 1:1 (only clinical-impact SCVs get one). Weak
    -- invariant: every evidence_line scv-id must exist in scv_summary (no orphans).
    EXECUTE IMMEDIATE FORMAT("""
      SELECT COUNT(*) FROM (
        SELECT DISTINCT SPLIT(SPLIT(id, ':')[OFFSET(1)], '.')[OFFSET(0)] AS scv
        FROM `%s.gks_dict_evidence_line`
      ) el
      LEFT JOIN `%s.scv_summary` s ON s.id = el.scv
      WHERE s.id IS NULL
    """, rec.schema_name, rec.schema_name)
    INTO el_orphan_count;

    IF el_orphan_count != 0 THEN
      RAISE USING MESSAGE = FORMAT(
        'gks_scv_statement validation FAILED for %s: %t gks_dict_evidence_line scv-id(s) have no matching scv_summary row (orphan evidence line)',
        rec.schema_name, el_orphan_count);
    END IF;

    IF NOT debug THEN
      DROP TABLE IF EXISTS _SESSION.temp_gks_scv;
      DROP TABLE IF EXISTS _SESSION.temp_gene_context_qualifiers;
      DROP TABLE IF EXISTS _SESSION.temp_moi_qualifiers;
      DROP TABLE IF EXISTS _SESSION.temp_penetrance_qualifiers;
      DROP TABLE IF EXISTS _SESSION.temp_gks_scv_proposition;
      DROP TABLE IF EXISTS _SESSION.temp_gks_scv_target_proposition;
      DROP TABLE IF EXISTS _SESSION.temp_scv_condition_names;
      DROP TABLE IF EXISTS _SESSION.temp_scv_citations;
      DROP TABLE IF EXISTS _SESSION.temp_scv_method;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_evidence_line;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_scv;
      END IF;
    END IF;

  END FOR;
END;


-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_statement_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_scv_statement_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/incomplete, the diff drivers / changed sets are missing, or the
-- pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_statement_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_scv_statement_build`(on_date, debug, TRUE);
END;
