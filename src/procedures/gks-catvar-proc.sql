-------------------------------------------------------------------------------
-- gks_catvar — build the categorical-variant dictionary tables from a release
--
-- Three entry points:
--   gks_catvar_proc(on_date, debug)              -> full rebuild (unchanged behavior)
--   gks_catvar_proc_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   gks_catvar_build(on_date, debug, incremental) -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-06-incremental-gks-
-- downstream-plan-1-catvar-and-foundations.md):
--   The six global dedup dictionaries (sequence_reference, location, allele,
--   copy_number_count, copy_number_change, gene) are ALWAYS globally recomputed —
--   their content is a whole-snapshot dedup, so filtering would corrupt them.
--   Only gks_dict_variation is per-variation: in incremental mode the per-variation
--   temps (temp_ctxvar / temp_catvar_extension / temp_catvar_mappings) and the final
--   assembly are filtered to the changed set, staged, and merged with the carried-
--   forward baseline rows via UNION-CTAS.
--   Version-invalidation: the guard falls back to a full rebuild when the baseline
--   is missing/incomplete, the diff drivers are absent, or the pipeline gate_key
--   mismatches. Call the *_incremental wrapper only when carry-forward is safe.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  DECLARE temp_seqref_query STRING;
  DECLARE temp_seqloc_query STRING;
  DECLARE dict_seqref_query STRING;
  DECLARE dict_location_query STRING;
  DECLARE dict_allele_query STRING;
  DECLARE dict_copy_number_count_query STRING;
  DECLARE dict_copy_number_change_query STRING;
  DECLARE temp_ctxvar_expr_query STRING;
  DECLARE temp_ctxvar_query STRING;
  DECLARE temp_catvar_ext_query STRING;
  DECLARE dict_gene_query STRING;
  DECLARE temp_catvar_map_query STRING;
  DECLARE dict_variation_query STRING;
  DECLARE query_changed_set STRING;
  DECLARE query_merge STRING;
  DECLARE catvar_id_mismatch INT64;

  DECLARE temp_create STRING;
  DECLARE temp_prefix STRING;

  -- incremental control / fallback guard
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;
  DECLARE gate_ok BOOL DEFAULT FALSE;
  DECLARE stamps_exist BOOL DEFAULT FALSE;

  -- per-query changed-set filter fragments ('' in full mode). Distinct variables
  -- because each consuming query filters on a different alias for variation_id.
  DECLARE vfilter_ctx STRING;   -- Step 3 temp_ctxvar   (ctxvar CTE, no WHERE -> full WHERE on vrs.in.variation_id)
  DECLARE vfilter_ext STRING;   -- Step 4 temp_catvar_extension (final select, no WHERE -> full WHERE on x.variation_id)
  DECLARE vfilter_map STRING;   -- Step 5 temp_catvar_mappings  (final select, no WHERE -> full WHERE on m.variation_id)
  DECLARE vfilter_dv STRING;    -- Step 6 catvar CTE (already has WHERE ... is not null -> AND on ctx.variation_id)
  DECLARE dv_head STRING;       -- gks_dict_variation target (real table vs stg temp)

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (select s.schema_name, s.prev_release_date FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -----------------------------------------------------------------------
    -- Resolve baseline + fallback guard: incremental is only safe when the
    -- prior release exists with all seven catvar outputs, the current release
    -- has the four diff driver tables, AND the pipeline gate_key matches the
    -- baseline (build logic unchanged). Otherwise fall back to a full rebuild.
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
      -- baseline must have all 7 catvar outputs
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('gks_dict_variation','gks_dict_sequence_reference','gks_dict_location',
                  'gks_dict_allele','gks_dict_copy_number_count','gks_dict_copy_number_change','gks_dict_gene')) = 7
      """, baseline_schema) INTO base_ok;

      -- current release must have the diff drivers: the three variation_identity uses
      -- (content + copy-number cascade) PLUS diff_gene_association for the gene path.
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('diff_variation','diff_clinical_assertion',
                  'diff_clinical_assertion_variation','diff_gene_association')) = 4
      """, rec.schema_name) INTO diff_ok;

      -- version gate — TWO statements. BigQuery resolves table refs at analysis time
      -- and does NOT short-circuit that resolution, so a single combined statement
      -- referencing {base}.gks_pipeline_version would ERROR (not return FALSE) when a
      -- pre-feature baseline lacks the stamp — defeating the fail-safe. First confirm
      -- both stamps exist; only then compare gate_key.
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
      END IF;

      SET eff_incremental = base_ok AND diff_ok AND gate_ok;
    END IF;

    -----------------------------------------------------------------------
    -- Mode-dependent fragments. In full mode all filters are empty and the
    -- final assembly writes straight to {S}.gks_dict_variation. In incremental
    -- mode the per-variation temps + assembly are filtered to the changed set
    -- and the assembly is staged to {P}.stg_gks_dict_variation for the merge.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET vfilter_ctx = 'WHERE vrs.in.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';
      SET vfilter_ext = 'WHERE x.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';
      SET vfilter_map = 'WHERE m.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';
      SET vfilter_dv  = 'AND ctx.variation_id IN (SELECT variation_id FROM {P}.catvar_changed_ids)';
      SET dv_head = '{CT} {P}.stg_gks_dict_variation';
    ELSE
      SET vfilter_ctx = '';
      SET vfilter_ext = '';
      SET vfilter_map = '';
      SET vfilter_dv = '';
      SET dv_head = 'CREATE OR REPLACE TABLE `{S}.gks_dict_variation`';
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_seqref', 'temp_seqloc', 'temp_ctxvar_expression',
        'temp_ctxvar', 'temp_catvar_extension', 'temp_catvar_mappings',
        'catvar_changed_ids', 'catvar_removed_ids', 'stg_gks_dict_variation'
      ]);
    END IF;

    -----------------------------------------------------------------------
    -- Step 0 (incremental only): build the changed / removed variation sets.
    --   removed = diff_variation(removed).
    --   changed = diff_variation(new|modified) ∪ copy-number cascade
    --             ∪ diff_gene_association changes, minus removed.
    -- The cn-cascade covers variations whose `variation` row is byte-identical
    -- but whose CopyNumber-bearing SCV data changed, resolved over BOTH the
    -- compare {S} and baseline {base} snapshots. gene_association changes are
    -- added because temp_catvar_extension's clinvarGeneList reads gene_association
    -- directly (a variation whose only change is a gene link would otherwise carry
    -- forward stale). NOT keyed off variation_vrs_changed (which is a diff of the
    -- variation_identity row only and misses hgvs/loc-derived extension changes).
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET query_changed_set = REPLACE("""
        {CT} {P}.catvar_removed_ids AS
        SELECT id AS variation_id FROM `{S}.diff_variation` WHERE change_type = 'removed'
      """, '{BASE}', baseline_schema);
      SET query_changed_set = REPLACE(query_changed_set, '{CT}', temp_create);
      SET query_changed_set = REPLACE(query_changed_set, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_changed_set = REPLACE(query_changed_set, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_changed_set;

      SET query_changed_set = REPLACE("""
        {CT} {P}.catvar_changed_ids AS
        WITH changed_cav AS (
          SELECT id FROM `{S}.diff_clinical_assertion_variation`
          WHERE change_type IN ('new','modified','removed')
        ),
        changed_ca AS (
          SELECT id FROM `{S}.diff_clinical_assertion`
          WHERE change_type IN ('new','modified','removed')
        ),
        cn_cascade AS (
          SELECT DISTINCT ca.variation_id AS variation_id
          FROM `{S}.clinical_assertion_variation` cav
          JOIN `{S}.clinical_assertion` ca
            ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
          WHERE cav.content LIKE '%CopyNumber%'
            AND (
              cav.id IN (SELECT id FROM changed_cav)
              OR cav.clinical_assertion_id IN (SELECT id FROM changed_ca)
            )
          UNION DISTINCT
          SELECT DISTINCT ca.variation_id AS variation_id
          FROM `{BASE}.clinical_assertion_variation` cav
          JOIN `{BASE}.clinical_assertion` ca
            ON ca.id = cav.clinical_assertion_id AND ca.statement_type IS NOT NULL
          WHERE cav.content LIKE '%CopyNumber%'
            AND (
              cav.id IN (SELECT id FROM changed_cav)
              OR cav.clinical_assertion_id IN (SELECT id FROM changed_ca)
            )
        )
        SELECT variation_id FROM (
          SELECT id AS variation_id FROM `{S}.diff_variation` WHERE change_type IN ('new','modified')
          UNION DISTINCT
          SELECT variation_id FROM cn_cascade
          UNION DISTINCT
          SELECT DISTINCT variation_id FROM `{S}.diff_gene_association` WHERE change_type IN ('new','modified','removed')
        )
        WHERE variation_id NOT IN (SELECT variation_id FROM {P}.catvar_removed_ids)
      """, '{BASE}', baseline_schema);
      SET query_changed_set = REPLACE(query_changed_set, '{CT}', temp_create);
      SET query_changed_set = REPLACE(query_changed_set, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_changed_set = REPLACE(query_changed_set, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_changed_set;
    END IF;

    -------------------------------------------------------------------------
    -- Step 1a: Enriched sequence references (small lookup table) — GLOBAL
    -------------------------------------------------------------------------
    SET temp_seqref_query = REPLACE("""
      {CT} {P}.temp_seqref
      AS
      SELECT DISTINCT
        vrs.in.accession as name,
        vrs.out.location.sequenceReference.*,
        CASE
        WHEN LEFT(vrs.in.accession,3) IN ('AC_','NC_','NG_','NT_','NW_','NZ_') THEN 'genomic'
        WHEN LEFT(vrs.in.accession,3) IN ('NM_','XM_') THEN 'mRNA'
        WHEN LEFT(vrs.in.accession,3) IN ('NR_','XR_') THEN 'RNA'
        WHEN LEFT(vrs.in.accession,3) IN ('AP_','NP_','YP_','XP_','WP_') THEN 'protein'
        ELSE null
        END as moleculeType,
        IF(LEFT(vrs.in.accession,3) IN ('AP_','NP_','YP_','XP_','WP_'),'aa','na') as residueAlphabet,
        CASE vrs.in.assembly_version
        WHEN 38 THEN [STRUCT("assembly" as name,"GRCh38" as value)]
        WHEN 37 THEN [STRUCT("assembly" as name,"GRCh37" as value)]
        WHEN 36 THEN [STRUCT("assembly" as name,"NCBI36" as value)]
        ELSE NULL
        END as extensions
      FROM `{S}.gks_vrs` vrs
      WHERE
        vrs.out.location.sequenceReference.refgetAccession is not null
      -- One sequence-reference row per refgetAccession — a refget IS one physical
      -- sequence. Some sequences legitimately carry more than one assembly label across
      -- variants (the mitochondrion NC_012920.1 is shared by GRCh37 and GRCh38), which
      -- would otherwise duplicate the sequenceReference and fan out the catvar location
      -- join into duplicate variation rows. Keep the highest assembly (GRCh38 for shared
      -- sequences); NULLS LAST so an unresolved-assembly variant never wins over a real one.
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY vrs.out.location.sequenceReference.refgetAccession
        ORDER BY vrs.in.assembly_version DESC NULLS LAST
      ) = 1
    """, '{S}', rec.schema_name);
    SET temp_seqref_query = REPLACE(temp_seqref_query, '{CT}', temp_create);
    SET temp_seqref_query = REPLACE(temp_seqref_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_seqref_query;

    -------------------------------------------------------------------------
    -- Step 1b: Sequence locations with sequence reference join — GLOBAL
    -------------------------------------------------------------------------
    SET temp_seqloc_query = REPLACE("""
      {CT} {P}.temp_seqloc
      AS
      WITH x AS (
        SELECT DISTINCT
          vrs.out.location.*
        FROM `{S}.gks_vrs` vrs
        WHERE
          vrs.out.location.id is not null
      )
      SELECT
        x.id,
        x.digest,
        x.type,
        x.start,
        x.end,
        IF(
          x.start_outer IS NULL AND x.start_inner IS NULL,
          null,
          [
            IFNULL(x.start_outer,'null'),
            IFNULL(x.start_inner,'null')
          ]
        ) as start_range,
        IF(
          x.end_outer IS NULL AND x.end_inner IS NULL,
          null,
          [
            IFNULL(x.end_inner, 'null'),
            IFNULL(x.end_outer, 'null')
          ]
        ) as end_range,
        (SELECT AS STRUCT sq.*) AS sequenceReference
      FROM x
      JOIN {P}.temp_seqref sq
      ON
        sq.refgetAccession = x.sequenceReference.refgetAccession
    """, '{S}', rec.schema_name);
    SET temp_seqloc_query = REPLACE(temp_seqloc_query, '{CT}', temp_create);
    SET temp_seqloc_query = REPLACE(temp_seqloc_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_seqloc_query;

    -------------------------------------------------------------------------
    -- Step 1c: Dictionary table - sequence references (global, keyed by refgetAccession)
    -------------------------------------------------------------------------
    SET dict_seqref_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_sequence_reference`
      AS
      SELECT
        sq.refgetAccession as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          'SequenceReference' as type,
          sq.refgetAccession,
          sq.name,
          sq.moleculeType,
          sq.residueAlphabet,
          sq.extensions
        )), remove_empty => TRUE) as value
      FROM {P}.temp_seqref sq
    """, '{S}', rec.schema_name);
    SET dict_seqref_query = REPLACE(dict_seqref_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_seqref_query;

    -------------------------------------------------------------------------
    -- Step 1d: Dictionary table - locations (global, keyed by location id)
    -------------------------------------------------------------------------
    SET dict_location_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_location`
      AS
      SELECT
        sl.id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          sl.id,
          sl.type,
          sl.digest,
          sl.start,
          sl.end,
          sl.start_range,
          sl.end_range,
          FORMAT('#/sequenceReference/%s', sl.sequenceReference.refgetAccession) as sequenceReference
        )), remove_empty => TRUE) as value
      FROM {P}.temp_seqloc sl
    """, '{S}', rec.schema_name);
    SET dict_location_query = REPLACE(dict_location_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_location_query;

    -------------------------------------------------------------------------
    -- Step 2: Contextual variant expressions with precedence-ranked naming — GLOBAL
    -- MUST stay unfiltered: feeds BOTH gks_dict_allele (global, needs all alleles)
    -- and temp_ctxvar (per-variation). Filtering it would corrupt gks_dict_allele.
    -------------------------------------------------------------------------
    SET temp_ctxvar_expr_query = REPLACE("""
      {CT} {P}.temp_ctxvar_expression
      AS
      WITH exp_item AS (
        SELECT
          vrs.in.variation_id,
          vrs.in.accession,
          vrs.in.fmt as syntax,
          vrs.in.source as value,
          CAST(null as STRING) as hgvs_type,
          CAST(null as STRING) as issue,
          1 as precedence,
          vrs.in.assembly_version
        FROM `{S}.gks_vrs` vrs
        WHERE
          vrs.in.fmt = 'spdi'
          AND
          vrs.out.id is not null
        UNION ALL
        -- select DISTINCT to eliminate the dupe MT occurences across builds
        SELECT DISTINCT
          vl.variation_id,
          IFNULL(
            vl.accession,
            FORMAT('%i-chr%s', vl.assembly_version, vl.chr)
          ) as accession,
          'gnomad' as syntax,
          vl.gnomad_source as value,
          CAST(null as STRING) as hgvs_type,
          CAST(null as STRING) as issue,
          3 as precedence,
          vl.assembly_version
        FROM `{S}.variation_loc` vl
        JOIN `{S}.gks_vrs` vrs
        ON
          vl.variation_id = vrs.in.variation_id
          AND
          vl.accession = vrs.in.accession
          AND
          vl.assembly_version is not distinct from vrs.in.assembly_version
        WHERE
            vl.gnomad_source is not null
            AND
            vrs.out.id is not null
        UNION ALL
        SELECT
          vh.variation_id,
          vh.accession,
          format('hgvs.%s', IFNULL(REGEXP_EXTRACT(e.nucleotide, r':([gmcnrp])\\.'), LEFT(vh.type, 1))) as syntax,
          e.nucleotide as value,
          vh.type as hgvs_type,
          vh.issue,
          2 as precedence,
          vh.assembly_version
        FROM `{S}.variation_hgvs` vh
        CROSS JOIN unnest(expr) as e
        JOIN `{S}.gks_vrs` vrs
        ON
          vh.variation_id = vrs.in.variation_id
          AND
          vh.accession = vrs.in.accession
          AND
          vh.assembly_version is not distinct from vrs.in.assembly_version
        WHERE
          e.nucleotide is not null
          AND
          vrs.out.id is not null
        UNION ALL
        SELECT DISTINCT
          vl.variation_id,
          vl.accession,
          'hgvs.g' as syntax,
          vl.loc_hgvs_source as value,
          'genomic' as hgvs_type,
          vl.loc_hgvs_issue as issue,
          4 as precedence,
          vl.assembly_version
        FROM `{S}.variation_loc` vl
        JOIN `{S}.gks_vrs` vrs
        ON
          vl.variation_id = vrs.in.variation_id
          AND
          vl.accession = vrs.in.accession
          AND
          vl.assembly_version is not distinct from vrs.in.assembly_version
        LEFT JOIN `{S}.variation_hgvs` vh
        ON
          vh.variation_id = vl.variation_id
          AND
          vh.accession = vl.accession
          AND
          vh.assembly_version is not distinct from vl.assembly_version
        WHERE
          vl.gnomad_source is null
          AND
          vl.loc_hgvs_source is not null
          AND
          vh.variation_id is null
          AND
          vrs.out.id is not null
      )
      SELECT
        exp_item.variation_id,
        exp_item.accession,
        exp_item.assembly_version,
        ARRAY_AGG(exp_item.value ORDER BY exp_item.hgvs_type DESC, exp_item.precedence)[0] as name,
        (CASE exp_item.assembly_version WHEN 38 THEN 'GRCh38' WHEN 37 THEN 'GRCh37' WHEN 36 THEN 'NCBI36' ELSE null END) as assembly,
        ARRAY_AGG(STRUCT(exp_item.syntax, exp_item.value) ORDER BY exp_item.precedence) as expressions,
        ARRAY_AGG(DISTINCT exp_item.hgvs_type IGNORE NULLS ORDER BY exp_item.hgvs_type DESC) as types,
        ARRAY_AGG(DISTINCT exp_item.issue IGNORE NULLS) as issues
      FROM exp_item
      GROUP BY
        exp_item.variation_id,
        exp_item.accession,
        exp_item.assembly_version
    """, '{S}', rec.schema_name);
    SET temp_ctxvar_expr_query = REPLACE(temp_ctxvar_expr_query, '{CT}', temp_create);
    SET temp_ctxvar_expr_query = REPLACE(temp_ctxvar_expr_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_ctxvar_expr_query;

    -------------------------------------------------------------------------
    -- Step 2b: Dictionary table - alleles (Allele type only) — GLOBAL
    -- Uses temp_ctxvar_expression for full expression set (spdi + hgvs + gnomad)
    -------------------------------------------------------------------------
    SET dict_allele_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_allele`
      AS
      WITH allele_to_variation AS (
        SELECT DISTINCT
          vrs.out.id as allele_id,
          vrs.in.variation_id
        FROM `{S}.gks_vrs` vrs
        WHERE vrs.out.id IS NOT NULL
          AND vrs.out.type = 'Allele'
      )
      SELECT
        vrs.id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          vrs.id,
          vrs.type,
          vrs.digest,
          exp.name,
          vrs.state,
          exp.expressions,
          FORMAT('#/location/%s', vrs.location.id) as location
        )), remove_empty => TRUE) as value
      FROM (
        SELECT DISTINCT out.*
        FROM `{S}.gks_vrs`
        WHERE out.id IS NOT NULL
          AND out.type = 'Allele'
      ) vrs
      LEFT JOIN allele_to_variation atv ON atv.allele_id = vrs.id
      LEFT JOIN {P}.temp_ctxvar_expression exp ON exp.variation_id = atv.variation_id
    """, '{S}', rec.schema_name);
    SET dict_allele_query = REPLACE(dict_allele_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE dict_allele_query;

    -------------------------------------------------------------------------
    -- Step 2c: Dictionary table - copy number counts (CopyNumberCount type only) — GLOBAL
    -------------------------------------------------------------------------
    SET dict_copy_number_count_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_copy_number_count`
      AS
      SELECT
        vrs.id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          vrs.id,
          vrs.type,
          vrs.digest,
          vrs.copies,
          FORMAT('#/location/%s', vrs.location.id) as location
        )), remove_empty => TRUE) as value
      FROM (
        SELECT DISTINCT out.*
        FROM `{S}.gks_vrs`
        WHERE out.id IS NOT NULL
          AND out.type = 'CopyNumberCount'
      ) vrs
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE dict_copy_number_count_query;

    -------------------------------------------------------------------------
    -- Step 2d: Dictionary table - copy number changes (CopyNumberChange type only) — GLOBAL
    -------------------------------------------------------------------------
    SET dict_copy_number_change_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_copy_number_change`
      AS
      SELECT
        vrs.id as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          vrs.id,
          vrs.type,
          vrs.digest,
          vrs.copyChange,
          FORMAT('#/location/%s', vrs.location.id) as location
        )), remove_empty => TRUE) as value
      FROM (
        SELECT DISTINCT out.*
        FROM `{S}.gks_vrs`
        WHERE out.id IS NOT NULL
          AND out.type = 'CopyNumberChange'
      ) vrs
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE dict_copy_number_change_query;

    -------------------------------------------------------------------------
    -- Step 3: Contextual variants with VRS type mapping — per-variation ({VFILTER})
    -------------------------------------------------------------------------
    SET temp_ctxvar_query = REPLACE("""
      {CT} {P}.temp_ctxvar
      AS
      WITH ctxvar AS (
        SELECT
          vrs.in.variation_id,
          vrs.in.vrs_class,
          vrs.in.issue,
          CASE vrs.`out`.type
          WHEN 'Allele' THEN 'CanonicalAllele'
          WHEN 'CopyNumberChange' THEN 'CategoricalCnvChange'
          WHEN 'CopyNumberCount' THEN 'CategoricalCnvCount'
          ELSE 'Undefined'
          END as catvar_type,
          vrs.in.name,
          vrs.out.*
        FROM `{S}.gks_vrs` vrs
        {VFILTER}
      )
      SELECT DISTINCT
        ctxvar.variation_id,
        ctxvar.vrs_class,
        IFNULL(ctxvar.issue, IF(ARRAY_LENGTH(exp.issues) = 0, null, ARRAY_TO_STRING(exp.issues, '\\n'))) as vrs_issue,
        ctxvar.catvar_type,
        ctxvar.name as catvar_name,
        exp.name,
        ctxvar.id,
        ctxvar.digest,
        ctxvar.type,
        (SELECT AS STRUCT sl.*) AS location,
        ctxvar.state,
        ctxvar.copies,
        ctxvar.copyChange,
        exp.expressions
      FROM ctxvar
      LEFT JOIN {P}.temp_ctxvar_expression exp
      ON
        exp.variation_id = ctxvar.variation_id
      LEFT JOIN {P}.temp_seqloc sl
      ON
        sl.id = ctxvar.location.id
    """, '{S}', rec.schema_name);
    SET temp_ctxvar_query = REPLACE(temp_ctxvar_query, '{VFILTER}', vfilter_ctx);
    SET temp_ctxvar_query = REPLACE(temp_ctxvar_query, '{CT}', temp_create);
    SET temp_ctxvar_query = REPLACE(temp_ctxvar_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_ctxvar_query;

    -------------------------------------------------------------------------
    -- Step 4: Categorical variant extensions (HGVS list, gene lists, type metadata)
    --         per-variation ({VFILTER} on the final select)
    -------------------------------------------------------------------------
    SET temp_catvar_ext_query = REPLACE("""
      {CT} {P}.temp_catvar_extension
      AS
      WITH so_lookup AS (
        SELECT
          so_item.*
        FROM
        (
          -- TODO convert the hardcoding below to a table that is loaded from SO.
          SELECT
            [
              STRUCT('SO:0001583' as code, 'missense_variant' as label),
              STRUCT('SO:0001627' as code, 'intron_variant' as label),
              STRUCT('SO:0001820' as code, 'inframe_indel' as label),
              STRUCT('SO:0001822' as code, 'inframe_deletion' as label),
              STRUCT('SO:0002073' as code, 'no_sequence_alteration' as label),
              STRUCT('SO:0001821' as code, 'inframe_insertion' as label),
              STRUCT('SO:0001587' as code, 'stop_gained' as label),
              STRUCT('SO:0001623' as code, '5_prime_UTR_variant' as label),
              STRUCT('SO:0001578' as code, 'stop_lost' as label),
              STRUCT('SO:0002153' as code, 'genic_upstream_transcript_variant' as label),
              STRUCT('SO:0001574' as code, 'splice_acceptor_variant' as label),
              STRUCT('SO:0001619' as code, 'non_coding_transcript_variant' as label),
              STRUCT('SO:0002152' as code, 'genic_downstream_transcript_variant' as label),
              STRUCT('SO:0001575' as code, 'splice_donor_variant' as label),
              STRUCT('SO:0001624' as code, '3_prime_UTR_variant' as label),
              STRUCT('SO:0001819' as code, 'synonymous_variant' as label),
              STRUCT('SO:0001589' as code, 'frameshift_variant' as label),
              STRUCT('SO:0001582' as code, 'initiator_codon_variant' as label)
            ] AS so_items
          ) as so_list
          CROSS JOIN UNNEST(so_list.so_items) as so_item
      ),
      hgvs_items AS (
        -- clinvar hgvs list structure nucleotide, protein, molecular consequence, mane select, mane plus
        SELECT
          vh.variation_id,
          vh.accession,
          format('hgvs.%s', IFNULL(REGEXP_EXTRACT(exp.nucleotide, r':([gmcnrp])\\.'), '?')) as nucleotide_syntax,
          exp.nucleotide as nucleotide_value,
          format('hgvs.%s', IFNULL(REGEXP_EXTRACT(exp.protein, r':([gmcnrp])\\.'), '?')) as protein_syntax,
          exp.protein as protein_value,
          SPLIT(vh.consq_id) as consq_ids,
          vh.hgvs_source,
          vh.mane_plus,
          vh.mane_select,
          vh.type
        FROM `{S}.variation_hgvs` vh
        LEFT JOIN UNNEST(vh.expr) as exp
      ),
      hgvs_consq AS (
        SELECT
          hgvs.variation_id,
          hgvs.nucleotide_value,
          c_id,
          sl.code as consq_code,
          sl.label as consq_label
        FROM hgvs_items hgvs
        CROSS JOIN UNNEST(hgvs.consq_ids) c_id
        LEFT JOIN so_lookup sl
        ON
          sl.code = c_id
      ),
      hgvs_item_consq AS (
        SELECT
          hgvs.variation_id,
          hgvs.nucleotide_value,
          ARRAY_AGG(
            STRUCT(
              hcsq.consq_code as code,
              'http://www.sequenceontology.org/' as system,
              hcsq.consq_label as name,
              [format('https://identifiers.org/%s',hcsq.consq_code)] as iris
            )
          ) as molecularConsequence
        FROM hgvs_items hgvs
        JOIN hgvs_consq hcsq
        ON
          hcsq.variation_id = hgvs.variation_id
          AND
          hcsq.nucleotide_value = hgvs.nucleotide_value
        GROUP BY
          hgvs.variation_id,
          hgvs.nucleotide_value
      ),
      var_ext_hgvs_list as (
        SELECT
          hgvs.variation_id,
          ARRAY_AGG(
            STRUCT(
              STRUCT(
                hgvs.nucleotide_syntax as syntax,
                hgvs.nucleotide_value as value
              ) as nucleotideExpression,
              hgvs.type as nucleotideType,
              hgvs.mane_select as maneSelect,
              hgvs.mane_plus as manePlus,
              IF(
                hgvs.protein_value is not null,
                STRUCT(
                  hgvs.protein_syntax as syntax,
                  hgvs.protein_value as value
                ),
                null
              ) as proteinExpression,
              hcsq.molecularConsequence
            )
          ) value
        FROM hgvs_items hgvs
        LEFT JOIN hgvs_item_consq hcsq
        ON
          hcsq.variation_id = hgvs.variation_id
          AND
          hcsq.nucleotide_value = hgvs.nucleotide_value
        GROUP BY
          hgvs.variation_id
      ),
      var_ext_gene_list as (
        SELECT
          ga.variation_id,
          ARRAY_AGG(
            STRUCT(
              FORMAT('#/gene/ncbigene:%s', ga.gene_id) as gene,
              ga.relationship_type,
              ga.source
            )
          ) as genes
        FROM `{S}.gene_association` ga
        GROUP BY
          ga.variation_id
      ),
      cat_ext_item AS (
        SELECT
          ctx.variation_id,
          'categoricalVariationType' as name,
          ctx.catvar_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM {P}.temp_ctxvar ctx
        UNION ALL
        SELECT
          ctx.variation_id,
          'definingVrsVariationType' as name,
          ctx.vrs_class as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM {P}.temp_ctxvar ctx
        UNION ALL
        SELECT
          ctx.variation_id,
          'vrsPreProcessingIssue' as name,
          ctx.vrs_issue as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM {P}.temp_ctxvar ctx
        WHERE
          ctx.vrs_issue is not null
        UNION ALL
        SELECT
          variation_id,
          'clinvarVariationType' as name,
          vi.variation_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `{S}.variation_identity` vi
        WHERE
          vi.variation_type is not null
        UNION ALL
        SELECT
          variation_id,
          'clinvarSubclassType' as name,
          vi.subclass_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `{S}.variation_identity` vi
        WHERE
          vi.subclass_type is not null
        UNION ALL
        SELECT
          variation_id,
          'clinvarCytogeneticLocation' as name,
          vi.cytogenetic as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `{S}.variation_identity` vi
        WHERE
          vi.cytogenetic is not null
        UNION ALL
        SELECT
          vrs.in.variation_id,
          'vrsProcessingException' as name,
          vrs.out.errors as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `{S}.gks_vrs` vrs
        WHERE
          vrs.out.errors is not null
        UNION ALL
        SELECT
          vhl.variation_id,
          'clinvarHgvsList' as name,
          CAST(null as STRING) as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          vhl.value as value_hgvs_array,
          null as value_gene_array
        FROM var_ext_hgvs_list vhl
        UNION ALL
        SELECT
          vgl.variation_id,
          'clinvarGeneList' as name,
          CAST(null as STRING) as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          vgl.genes as value_gene_array
        FROM var_ext_gene_list vgl
      )
        SELECT
          x.variation_id,
          ARRAY_AGG(
            STRUCT(
              x.name,
              x.value_string,
              x.value_boolean,
              x.value_coding,
              x.value_hgvs_array,
              x.value_gene_array
            )
          ) as extensions
        FROM cat_ext_item x
        {VFILTER}
        GROUP BY
          x.variation_id
    """, '{S}', rec.schema_name);
    SET temp_catvar_ext_query = REPLACE(temp_catvar_ext_query, '{VFILTER}', vfilter_ext);
    SET temp_catvar_ext_query = REPLACE(temp_catvar_ext_query, '{CT}', temp_create);
    SET temp_catvar_ext_query = REPLACE(temp_catvar_ext_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_catvar_ext_query;

    -------------------------------------------------------------------------
    -- Step 4b: Dictionary table - genes (MappableConcept, keyed by ncbigene:{id}) — GLOBAL
    -------------------------------------------------------------------------
    SET dict_gene_query = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_dict_gene`
      AS
      SELECT
        FORMAT('ncbigene:%s', g.id) as key,
        JSON_STRIP_NULLS(TO_JSON(STRUCT(
          FORMAT('ncbigene:%s', g.id) as id,
          'gene' as conceptType,
          g.symbol as name,
          STRUCT(
            g.id as code,
            g.symbol as name,
            'https://www.ncbi.nlm.nih.gov/gene/' as system,
            [
              FORMAT('https://identifiers.org/ncbigene:%s', g.id),
              FORMAT('https://www.ncbi.nlm.nih.gov/gene/%s', g.id)
            ] as iris
          ) as primaryCoding,
          IF(
            g.hgnc_id is null,
            null,
            [
              STRUCT(
                STRUCT(
                  REGEXP_EXTRACT(g.hgnc_id, r'\\d+') as code,
                  'https://www.genenames.org' as system,
                  [
                    FORMAT('https://identifiers.org/hgnc:%s', REGEXP_EXTRACT(g.hgnc_id, r'\\d+')),
                    FORMAT(
                      'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%s',
                      REGEXP_EXTRACT(g.hgnc_id, r'\\d+')
                    )
                  ] as iris
                ) as coding,
                'exactMatch' as relation
              )
            ]
          ) as mappings
        )), remove_empty => TRUE) as value
      FROM `{S}.gene` g
      WHERE g.id IN (SELECT DISTINCT gene_id FROM `{S}.gene_association`)
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE dict_gene_query;

    -------------------------------------------------------------------------
    -- Step 5: Cross-reference mappings for categorical variants
    --         per-variation ({VFILTER} on the final select)
    -------------------------------------------------------------------------
    SET temp_catvar_map_query = REPLACE("""
      {CT} {P}.temp_catvar_mappings
      AS
      WITH catvar_mappings AS (

        SELECT
          vrs.in.variation_id,
          STRUCT(
            'https://www.ncbi.nlm.nih.gov/clinvar/' as system,
            vrs.in.variation_id as code,
            [FORMAT('https://identifiers.org/clinvar:%s',vrs.in.variation_id)] as iris
          ) as coding,
          'exactMatch' as relation
        FROM `{S}.gks_vrs` vrs
        WHERE vrs.in.variation_id is not null

        UNION ALL

        SELECT
          x.variation_id,
          STRUCT(
            COALESCE(iri.system, x.db) as system,
            x.id as code,
            CASE LOWER(x.db)
            WHEN 'clinvar' THEN [FORMAT('https://identifiers.org/clinvar:%s',x.id)]
            WHEN 'clingen' THEN [FORMAT('https://reg.clinicalgenome.org/redmine/projects/registry/genboree_registry/by_caid?caid=%s', x.id)]
            WHEN 'dbvar' THEN [FORMAT('https://www.ncbi.nlm.nih.gov/dbvar/variants/%s', x.id)]
            WHEN 'dbsnp' THEN [FORMAT('https://identifiers.org/dbsnp:rs%s', x.id)]
            WHEN 'pharmgkb clinical annotation' THEN [FORMAT('https://www.pharmgkb.org/clinicalAnnotation/%s', x.id)]
            WHEN 'omim' THEN [FORMAT('http://www.omim.org/entry/%s', REPLACE(x.id, '.','#'))]
            WHEN 'uniprotkb' THEN [FORMAT('https://www.uniprot.org/uniprot/%s', x.id)]
            WHEN 'genetic testing registry (gtr)' THEN [FORMAT('https://www.ncbi.nlm.nih.gov/gtr/tests/%s', x.id)]
            ELSE [] -- others exist which haven't been reconciled (e.g. VARSOME, BIC, Leiden, LOVD, etc..)
            END as iris
          ) as coding,
          -- note that there will be explicit 'clinvar' xrefs for haplotypes and genotypes that are related to snvs and haplotypes, so we will use 'relatedMatch' on those
          CASE LOWER(x.db)
          WHEN 'clingen' THEN 'closeMatch'
          ELSE 'relatedMatch'
          END as relation
        FROM `{S}.variation_xref` x
        LEFT JOIN (
          SELECT LOWER(db) as db_lower, ANY_VALUE(system) as system
          FROM `clinvar_ingest.gks_xref_iri_templates`
          WHERE category IN ('Variation', 'Tests')
          GROUP BY LOWER(db)
        ) iri ON iri.db_lower = LOWER(x.db)
      )
      SELECT
        m.variation_id,
        ARRAY_AGG(STRUCT(m.coding, m.relation)) as mappings
      FROM catvar_mappings m
      {VFILTER}
      GROUP BY m.variation_id
    """, '{S}', rec.schema_name);
    SET temp_catvar_map_query = REPLACE(temp_catvar_map_query, '{VFILTER}', vfilter_map);
    SET temp_catvar_map_query = REPLACE(temp_catvar_map_query, '{CT}', temp_create);
    SET temp_catvar_map_query = REPLACE(temp_catvar_map_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_catvar_map_query;

    -------------------------------------------------------------------------
    -- Step 6: Assemble categorical variant records with constraints
    --         per-variation ({VFILTER} on catvar CTE; {DVHEAD} targets real
    --         table in full mode, stg temp in incremental mode)
    -------------------------------------------------------------------------
    SET dict_variation_query = REPLACE("""
      {DVHEAD}
      AS
      WITH catvar AS (
        SELECT
          ctx.variation_id,
          ctx.catvar_type,
          FORMAT('clinvar:%s', ctx.variation_id) as id,
          'CategoricalVariant' as type,
          ctx.catvar_name as name,
          -- Store allele/location refs for constraints
          ctx.id as vrs_allele_id,
          ctx.location.id as vrs_location_id,
          ctx.copies,
          ctx.copyChange
        FROM {P}.temp_ctxvar ctx
        -- safe guard for upstream vrs process that returns bad records
        WHERE ctx.variation_id is not null
        {VFILTER}
      ),
      cv_constraint_item AS (
        -- DefiningAlleleConstraint for CanonicalAllele
        SELECT
          ctx.variation_id,
          'DefiningAlleleConstraint' as type,
          FORMAT('#/allele/%s', ctx.vrs_allele_id) as allele,
          null as location,
          null as matchCharacteristic,
          [ STRUCT(
              STRUCT(
                'liftover_to' as code,
                'ga4gh-gks-term:allele-relation' as system,
                CAST(null as ARRAY<STRING>) as iris
              ) as primaryCoding
            ),
            STRUCT(
              STRUCT(
                'transcribed_to' as code,
                'http://www.sequenceontology.org/' as system,
                ['http://www.sequenceontology.org/browser/current_release/term/transcribed_to'] as iris
              ) as primaryCoding
            )
          ] as relations,
          CAST(null as INTEGER) as copies,
          null as copyChange
        FROM catvar ctx
        WHERE
          ctx.catvar_type = 'CanonicalAllele'
        UNION ALL
        -- DefiningLocationConstraint for CNV types
        SELECT
          ctx.variation_id,
          'DefiningLocationConstraint' as type,
          null as allele,
          FORMAT('#/location/%s', ctx.vrs_location_id) as location,
          STRUCT(
            STRUCT(
              'is_within' as code,
              'ga4gh-gks-term:location-match' as system,
              CAST(null as ARRAY<STRING>) as iris
            ) as primaryCoding
          ) as matchCharacteristic,
          [ STRUCT(
              STRUCT(
                'liftover_to' as code,
                'ga4gh-gks-term:allele-relation' as system,
                CAST(null as ARRAY<STRING>) as iris
              ) as primaryCoding
            )
          ] as relations,
          CAST(null as INTEGER) as copies,
          null as copyChange
        FROM catvar ctx
        WHERE
          ctx.catvar_type IN ('CategoricalCnvCount', 'CategoricalCnvChange')
        UNION ALL
        -- CopyCountConstraint for CategoricalCnvCount
        SELECT
          ctx.variation_id,
          'CopyCountConstraint' as type,
          null as allele,
          null as location,
          null as matchCharacteristic,
          null as relations,
          ctx.copies,
          null as copyChange
        FROM catvar ctx
        WHERE
          ctx.catvar_type = 'CategoricalCnvCount'
        UNION ALL
        -- CopyChangeConstraint for CategoricalCnvChange
        SELECT
          ctx.variation_id,
          'CopyChangeConstraint' as type,
          null as allele,
          null as location,
          null as matchCharacteristic,
          null as relations,
          CAST(null as INTEGER) as copies,
          ctx.copyChange
        FROM catvar ctx
        WHERE
          ctx.catvar_type = 'CategoricalCnvChange'
      ),
      cv_constraints AS (
        SELECT
          cv.variation_id,
          ARRAY_AGG(
            STRUCT(
              cci.type,
              cci.allele,
              cci.location,
              cci.copies,
              cci.copyChange,
              cci.matchCharacteristic,
              cci.relations
            )
          ) as constraints
        FROM catvar cv
        LEFT JOIN cv_constraint_item cci
        ON
          cv.variation_id = cci.variation_id
        GROUP BY
          cv.variation_id,
          cv.name
      )
      SELECT
        cv.id,
        cv.type,
        cv.name,
        cvc.constraints,
        CASE cv.catvar_type
          WHEN 'CanonicalAllele' THEN [FORMAT('#/allele/%s', cv.vrs_allele_id)]
          WHEN 'CategoricalCnvCount' THEN [FORMAT('#/copyNumberCount/%s', cv.vrs_allele_id)]
          WHEN 'CategoricalCnvChange' THEN [FORMAT('#/copyNumberChange/%s', cv.vrs_allele_id)]
          ELSE []
        END as members,
        cvext.extensions,
        vm.mappings
      FROM catvar cv
      LEFT JOIN cv_constraints cvc
      ON
        cvc.variation_id = cv.variation_id
      LEFT JOIN {P}.temp_catvar_extension cvext
      ON
        cvext.variation_id = cv.variation_id
      LEFT JOIN {P}.temp_catvar_mappings vm
      ON
        vm.variation_id = cv.variation_id
    """, '{DVHEAD}', dv_head);
    SET dict_variation_query = REPLACE(dict_variation_query, '{VFILTER}', vfilter_dv);
    SET dict_variation_query = REPLACE(dict_variation_query, '{CT}', temp_create);
    SET dict_variation_query = REPLACE(dict_variation_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET dict_variation_query = REPLACE(dict_variation_query, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE dict_variation_query;

    -----------------------------------------------------------------------
    -- Step 7 (incremental only): UNION-CTAS merge gks_dict_variation — carry
    -- forward the unchanged baseline rows and union in the freshly staged
    -- changed rows. Explicit column list so any schema/column-order drift
    -- errors (the version-invalidation signal) instead of silently corrupting.
    -- The id is 'clinvar:<variation_id>'; strip the prefix to match the id sets.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_dict_variation` AS
        SELECT id, type, name, constraints, members, extensions, mappings
        FROM `{BASE}.gks_dict_variation`
        WHERE SPLIT(id, ':')[OFFSET(1)] NOT IN (
          SELECT variation_id FROM {P}.catvar_changed_ids
          UNION DISTINCT
          SELECT variation_id FROM {P}.catvar_removed_ids
        )
        UNION ALL
        SELECT id, type, name, constraints, members, extensions, mappings
        FROM {P}.stg_gks_dict_variation
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;
    END IF;

    -------------------------------------------------------------------------
    -- Validation: gks_dict_variation must carry EXACTLY the variation-table id
    -- set (its id is 'clinvar:<variation_id>' — strip the namespace prefix to
    -- compare) with exactly one row per variation. A nonzero delta means a
    -- missing, extra, or duplicate categorical-variant record — fail loudly.
    -- Runs in BOTH modes; in incremental mode it also proves the merge is
    -- complete (no carry-forward gap, no double-count).
    -------------------------------------------------------------------------
    EXECUTE IMMEDIATE FORMAT("""
      SELECT
        ABS((SELECT COUNT(*) FROM `%s.variation`) - (SELECT COUNT(*) FROM `%s.gks_dict_variation`))
        + (SELECT COUNT(*) FROM (
             SELECT id FROM `%s.variation`
             EXCEPT DISTINCT SELECT SPLIT(id, ':')[OFFSET(1)] FROM `%s.gks_dict_variation`))
        + (SELECT COUNT(*) FROM (
             SELECT SPLIT(id, ':')[OFFSET(1)] FROM `%s.gks_dict_variation`
             EXCEPT DISTINCT SELECT id FROM `%s.variation`))
    """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name)
    INTO catvar_id_mismatch;

    IF catvar_id_mismatch != 0 THEN
      RAISE USING MESSAGE = FORMAT(
        'gks_catvar validation FAILED for %s: gks_dict_variation id set does not exactly match variation.id (count/set delta = %t)',
        rec.schema_name, catvar_id_mismatch);
    END IF;

    IF NOT debug THEN
      DROP TABLE _SESSION.temp_seqref;
      DROP TABLE _SESSION.temp_seqloc;
      DROP TABLE _SESSION.temp_ctxvar_expression;
      DROP TABLE _SESSION.temp_ctxvar;
      DROP TABLE _SESSION.temp_catvar_extension;
      DROP TABLE _SESSION.temp_catvar_mappings;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.catvar_changed_ids;
        DROP TABLE IF EXISTS _SESSION.catvar_removed_ids;
        DROP TABLE IF EXISTS _SESSION.stg_gks_dict_variation;
      END IF;
    END IF;

  END FOR;

END;


-- Full rebuild (unchanged public signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_proc`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_catvar_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Guarded: falls back to full when the
-- baseline is missing/incomplete, the diff drivers are missing, or the pipeline gate mismatches.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_proc_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.gks_catvar_build`(on_date, debug, TRUE);
END;
