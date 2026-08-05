
-------------------------------------------------------------------------------
-- variation_identity — build the variation identity tables from a ClinVar release
--
-- Three entry points:
--   variation_identity(on_date, debug)              -> full rebuild (unchanged behavior)
--   variation_identity_incremental(on_date, debug)  -> incremental (carry-forward + merge)
--   variation_identity_build(on_date, debug, incr)  -> internal implementation
--
-- Incremental strategy (see docs/superpowers/plans/2026-08-05-incremental-variation-identity-v2.md):
--   The heavy per-variation content parsing (parseSequenceLocations / parseHGVS /
--   parseXRefs / SPDI) runs ONLY for the variations that changed since the prior
--   release; the rest are carried forward from the baseline release and merged via
--   UNION-CTAS. `mappings` is recomputed GLOBALLY from the merged variation_xref so
--   its cross-variation dependency (xref rows keyed on the external id) stays correct.
--   Version-invalidation: call the *_incremental wrapper only when this proc is
--   unchanged since the baseline release; otherwise use the full rebuild.
-------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `clinvar_ingest.variation_identity_build`(on_date DATE, debug BOOL, incremental BOOL)
BEGIN
  DECLARE temp_variation_query STRING;
  DECLARE query_variation_loc STRING;
  DECLARE query_variation_hgvs STRING;
  DECLARE query_refine_vrs_class STRING;
  DECLARE query_variation_xref STRING;
  DECLARE temp_variation_spdi_query STRING;
  DECLARE temp_variation_members_query STRING;
  DECLARE query_variation_identity STRING;
  DECLARE query_changed_set STRING;
  DECLARE query_merge STRING;
  DECLARE temp_create STRING;

  -- incremental control / fallback guard
  DECLARE eff_incremental BOOL DEFAULT FALSE;
  DECLARE baseline_schema STRING DEFAULT NULL;
  DECLARE base_ok BOOL DEFAULT FALSE;
  DECLARE diff_ok BOOL DEFAULT FALSE;

  -- mode-dependent SQL fragments (contain {S}/{P}/{CT} placeholders, resolved per query)
  DECLARE vl_head STRING; DECLARE vh_head STRING; DECLARE vx_head STRING; DECLARE vi_head STRING;
  DECLARE vl_ref STRING;  DECLARE vh_ref STRING;  DECLARE vx_ref STRING;
  DECLARE vfilter STRING;
  DECLARE xm_ctes STRING; DECLARE mappings_col STRING; DECLARE mappings_join STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (select s.schema_name, s.prev_release_date FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -----------------------------------------------------------------------
    -- Resolve baseline + fallback guard: incremental is only safe when the
    -- prior release exists, has all four output tables, and the current
    -- release has the diff driver tables. Otherwise fall back to a full
    -- rebuild (always correct).
    -----------------------------------------------------------------------
    SET eff_incremental = FALSE;
    SET baseline_schema = NULL;
    SET base_ok = FALSE;
    SET diff_ok = FALSE;

    IF incremental AND rec.prev_release_date IS NOT NULL THEN
      SET baseline_schema = (
        SELECT s2.schema_name FROM clinvar_ingest.schema_on(rec.prev_release_date) AS s2 LIMIT 1
      );
    END IF;

    IF baseline_schema IS NOT NULL THEN
      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('variation_identity','variation_loc','variation_hgvs','variation_xref')) = 4
      """, baseline_schema) INTO base_ok;

      EXECUTE IMMEDIATE FORMAT("""
        SELECT (SELECT COUNT(*) FROM `%s.INFORMATION_SCHEMA.TABLES`
                WHERE table_name IN ('diff_variation','diff_clinical_assertion','diff_clinical_assertion_variation')) = 3
      """, rec.schema_name) INTO diff_ok;

      SET eff_incremental = base_ok AND diff_ok;
    END IF;

    -----------------------------------------------------------------------
    -- Mode-dependent fragments. In full mode the derived tables are the real
    -- {S} outputs; in incremental mode they are per-changed-variation staging
    -- temps ({P}.stg_*), merged into {S} after the parse steps.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET vl_head = '{CT} {P}.stg_variation_loc';
      SET vh_head = '{CT} {P}.stg_variation_hgvs';
      SET vx_head = '{CT} {P}.stg_variation_xref';
      SET vi_head = '{CT} {P}.stg_variation_identity';
      SET vl_ref  = '{P}.stg_variation_loc';
      SET vh_ref  = '{P}.stg_variation_hgvs';
      SET vx_ref  = '{P}.stg_variation_xref';
      SET vfilter = 'AND v.id IN (SELECT variation_id FROM {P}.changed_variation_ids)';
      SET xm_ctes = '';
      SET mappings_col = '';
      SET mappings_join = '';
    ELSE
      SET vl_head = 'CREATE OR REPLACE TABLE `{S}.variation_loc`';
      SET vh_head = 'CREATE OR REPLACE TABLE `{S}.variation_hgvs`';
      SET vx_head = 'CREATE OR REPLACE TABLE `{S}.variation_xref`';
      SET vi_head = 'CREATE OR REPLACE TABLE `{S}.variation_identity`';
      SET vl_ref  = '`{S}.variation_loc`';
      SET vh_ref  = '`{S}.variation_hgvs`';
      SET vx_ref  = '`{S}.variation_xref`';
      SET vfilter = '';
      SET xm_ctes = """,
        x AS (
          SELECT
            x.id as variation_id,
            x.db as system,
            x.id as code,
            IF(x.db='ClinGen', 'closeMatch', 'relatedMatch') as relation
          FROM `{S}.variation_xref` x
          group by
            x.id,
            x.db,
            x.id
        ),
        m as (
          SELECT
            x.variation_id,
            ARRAY_AGG(STRUCT(x.system, x.code, x.relation)) as mappings
          FROM x
          GROUP BY x.variation_id
        )""";
      SET mappings_col = """
          m.mappings,""";
      SET mappings_join = """
        LEFT JOIN m
        ON tv.variation_id = m.variation_id""";
    END IF;

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_variation', 'temp_variation_spdi', 'temp_variation_members',
        'stg_variation_loc', 'stg_variation_hgvs', 'stg_variation_xref',
        'stg_variation_identity', 'changed_variation_ids', 'removed_variation_ids'
      ]);
    END IF;

    -----------------------------------------------------------------------
    -- Step 0 (incremental only): build the changed / removed variation sets.
    --   changed = diff_variation(new|modified) ∪ copy-number cascade, minus removed.
    --   removed = diff_variation(removed).
    -- The copy-number cascade covers variations whose `variation` row is byte-
    -- identical but whose CopyNumber-bearing SCV data changed (added/removed/
    -- modified), resolved over BOTH the compare {S} and baseline {base} snapshots
    -- (a removed CAV/CA no longer appears in {S}).
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      SET query_changed_set = REPLACE("""
        {CT} {P}.removed_variation_ids AS
        SELECT id AS variation_id
        FROM `{S}.diff_variation`
        WHERE change_type = 'removed'
      """, '{BASE}', baseline_schema);
      SET query_changed_set = REPLACE(query_changed_set, '{CT}', temp_create);
      SET query_changed_set = REPLACE(query_changed_set, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_changed_set = REPLACE(query_changed_set, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_changed_set;

      SET query_changed_set = REPLACE("""
        {CT} {P}.changed_variation_ids AS
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
        )
        WHERE variation_id NOT IN (SELECT variation_id FROM {P}.removed_variation_ids)
      """, '{BASE}', baseline_schema);
      SET query_changed_set = REPLACE(query_changed_set, '{CT}', temp_create);
      SET query_changed_set = REPLACE(query_changed_set, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_changed_set = REPLACE(query_changed_set, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_changed_set;
    END IF;

    -------------------------------------------------------------------------
    -- Step 1: Extract variation records with copy number data and initial
    --         VRS class assignment
    -------------------------------------------------------------------------
    SET temp_variation_query = REPLACE("""
      {CT} {P}.temp_variation
      AS
      WITH cn AS (
        SELECT
          x.variation_id,
          x.variation_name,
          STRING_AGG(DISTINCT a.attribute.type) AS copy_type,
          STRING_AGG(DISTINCT a.attribute.value) AS copy_value
        FROM (
          SELECT
            v.id AS variation_id,
            v.name AS variation_name,
            cav.clinical_assertion_id AS scv_id,
            `clinvar_ingest.parseAttributeSet`(cav.content) AS attribs
          FROM `{S}.clinical_assertion_variation` cav
          JOIN `{S}.clinical_assertion` ca
          ON
            ca.id = cav.clinical_assertion_id
            AND
            -- exclude null statement_type records which were introduced in the 2025-08-08 release due to
            -- the segregation of functional data statements from GermlineClassification scvs.
            ca.statement_type IS NOT NULL
          JOIN `{S}.variation` v
          ON
            v.id = ca.variation_id
          WHERE
            cav.content LIKE '%CopyNumber%'
        ) x
        CROSS JOIN UNNEST(x.attribs) AS a
        WHERE
          a.attribute.type IN ('AbsoluteCopyNumber','CopyNumberTuple')
        GROUP BY
          x.variation_id,
          x.variation_name
      ),
      var AS (
        SELECT
          v.id as variation_id,
          v.name,
          v.subclass_type,
          v.variation_type,
          JSON_EXTRACT_SCALAR(v.content, "$.Location.CytogeneticLocation['$']") AS cytogenetic,
          JSON_EXTRACT_SCALAR(v.content, "$['CanonicalSPDI']['$']") AS canonical_spdi,
          CAST(
            IF(
              cn.copy_type = 'AbsoluteCopyNumber',
              cn.copy_value,
              null
            )
            AS INT64
          ) AS absolute_copies,
          IF(
            cn.copy_type = 'CopyNumberTuple',
            ARRAY(
              SELECT
                CAST(elem AS INT64)
                FROM UNNEST(SPLIT(cn.copy_value)) AS elem
            ),
            null
          ) AS range_copies,
          v.content
        FROM `{S}.variation` v
        LEFT JOIN cn ON cn.variation_id = v.id
        WHERE
          -- bad variant list DO NOT try to deal with these right now, these have been submitted to clinvar for correction
          v.id not in (
            "3027503" -- two variants in one! two locations, etc, but different snvs?!
          )
          {VFILTER}
      )
      SELECT
        var.variation_id,
        var.name,
        var.subclass_type,
        var.variation_type,
        var.cytogenetic,
        var.canonical_spdi,
        var.absolute_copies,
        var.range_copies,
        -- establish baseline vrs_class target type, updated later for copyChange and allele and text
        CASE
          WHEN var.canonical_spdi is not null THEN
            'Allele'
          WHEN (
            ((ARRAY_LENGTH(var.range_copies) > 0) OR var.absolute_copies is not null)
            and
            var.variation_type in ('copy number gain','copy number loss','Deletion','Duplication')
          ) THEN
            'CopyNumberCount'
          WHEN var.subclass_type = 'Genotype' THEN
            'Not Available'
          WHEN var.subclass_type = 'Haplotype' THEN
            'Haplotype'
          WHEN var.variation_type in ('copy number loss', 'copy number gain') THEN
            'CopyNumberChange'
        END vrs_class,
        CASE
        WHEN (ARRAY_LENGTH(var.range_copies) > 0) THEN
          'range copies are not supported.'
        WHEN (var.subclass_type IN ('Haplotype', 'Genotype')) THEN
          'haplotype and genotype variations are not supported.'
        END as issue,
        var.content
      FROM var
    """, '{VFILTER}', vfilter);
    SET temp_variation_query = REPLACE(temp_variation_query, '{CT}', temp_create);
    SET temp_variation_query = REPLACE(temp_variation_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET temp_variation_query = REPLACE(temp_variation_query, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE temp_variation_query;

    -------------------------------------------------------------------------
    -- Step 2: Parse sequence locations with derived gnomAD and HGVS
    --         expressions
    -------------------------------------------------------------------------
    SET query_variation_loc = REPLACE("""
      {VLHEAD} AS
      WITH l AS (
        SELECT
          v.variation_id,
          v.variation_type,
          seq.*,
          CAST(REGEXP_EXTRACT(seq.assembly, r'\\d+') as INT64) as assembly_version,
          -- derive a vcf/gnomad-formatted representation from the vcf data if available and
          -- required non-nulls are position_vcf, ref_allele_vcf, alt_allele_vcf and accession
          -- SPECIAL case: some clinvar locations have a chromosome value of 'Un', these should be skipped)
          IF(seq.chr = 'Un', NULL, FORMAT('%s-%i-%s-%s',seq.chr, seq.position_vcf, seq.reference_allele_vcf, seq.alternate_allele_vcf)) as gnomad_source,
          IF(seq.accession is not null,
            `clinvar_ingest.deriveHGVS`(v.variation_type,seq),
            null
          ) as loc_hgvs_source
        FROM {P}.temp_variation v
        CROSS JOIN UNNEST(
          `clinvar_ingest.parseSequenceLocations`(JSON_EXTRACT(v.content, r'$.Location'))
        ) as seq
        WHERE
          seq.accession is not null
      ),
      li AS (
        -- identify any issues for derived loc_hgvs expressions in advance if possible
        SELECT
          l.*,
          CASE
          WHEN (NOT REGEXP_CONTAINS(l.loc_hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_')) THEN
            'sequence for accession not supported by vrs-python release'
          -- WHEN REGEXP_CONTAINS(l.loc_hgvs_source, r':m\\.') THEN
          --   'mitochondria (m.) expressions not supported.'
          END as issue
        from l
        where l.loc_hgvs_source is not null
      )
      SELECT
        l.*,
        li.issue as loc_hgvs_issue,
        CASE
          WHEN l.assembly_version=38 THEN 1
          WHEN l.assembly_version=37 THEN 2
          WHEN l.assembly_version=36 THEN 3
        END varlen_precedence,
        (IFNULL(l.inner_start, IFNULL(l.inner_stop, IFNULL(l.outer_start,IFNULL(l.outer_stop, NULL)))) is not null) as has_range_endpoints,
        CASE
        WHEN l.variant_length is not NULL THEN
          l.variant_length
        WHEN IFNULL(l.start, IFNULL(l.stop, null)) is not null THEN
          (l.stop - l.start)
        WHEN IFNULL(l.inner_start, IFNULL(l.inner_stop, NULL)) is not null THEN
          (l.inner_stop - l.inner_start)
        WHEN IFNULL(l.outer_start, IFNULL(l.outer_stop, NULL)) is not null THEN
          (l.outer_stop - l.outer_start)
        END as derived_variant_length,
        IFNULL(CAST(l.start as STRING), FORMAT('[%s,%s]', IFNULL(CAST(l.outer_start as STRING), 'null'), IFNULL(CAST(l.inner_start as STRING), 'null'))) as derived_start,
        IFNULL(CAST(l.stop as STRING), FORMAT('[%s,%s]', IFNULL(CAST(l.inner_stop as STRING), 'null'), IFNULL(CAST(l.outer_stop as STRING), 'null'))) as derived_stop
      FROM l
      LEFT JOIN li
      ON
        li.variation_id = l.variation_id and
        li.accession = l.accession and
        -- use additional assembly string match since mito accessions are duplicated across assemblies
        -- without this it will produce a cartesian product of rows for all mito variants.
        li.assembly = l.assembly
    """, '{VLHEAD}', vl_head);
    SET query_variation_loc = REPLACE(query_variation_loc, '{CT}', temp_create);
    SET query_variation_loc = REPLACE(query_variation_loc, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET query_variation_loc = REPLACE(query_variation_loc, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE query_variation_loc;

    -------------------------------------------------------------------------
    -- Step 3: Parse HGVS expressions with molecular consequences and
    --         MANE designations
    -------------------------------------------------------------------------
    SET query_variation_hgvs = REPLACE("""
      {VHHEAD} AS

      WITH h AS (
        -- clinvar has thousands of variants that have multiple representations on the same accession
        -- we don't want to loose that info, but we also need to pick the best expression when this
        -- occurs to use for vrsifying the context on this accession. There are a handful that seem
        -- to be different variants instead of alternate representations. This is mainly related to
        -- representing both as precise and ambiguous endpoints on the same start and end location.
        -- these will need to be left for handling later (add this to the RELEASE NOTES)
        select
          v.id as variation_id,
          hgvs.nucleotide_expression.sequence_accession_version as accession,
          hgvs.type,
          hgvs.assembly,
          hgvs.nucleotide_expression.expression as nucleotide,
          hgvs.protein_expression.expression as protein,
          STRING_AGG(DISTINCT IF(STARTS_WITH(mc.id, mc.db), mc.id, FORMAT('%s:%s', mc.db, mc.id)) ) as consq_id,
          STRING_AGG(DISTINCT mc.type) as consq_label,
          hgvs.nucleotide_expression.mane_select,
          hgvs.nucleotide_expression.mane_plus_clinical as mane_plus,
          -- calculate whether there is a balanced # of parens in the hgvs expression
          (MOD(LENGTH(REGEXP_REPLACE(hgvs.nucleotide_expression.expression, r"[^\\(\\)]", "")), 2) = 0) AS has_balanced_parens,
          -- create clean hgvs... for deletion expression, remove any appended numbers,
          -- since these are not needed and currently not handled by hgvs parser
          REGEXP_REPLACE(hgvs.nucleotide_expression.expression, r"del[0-9]+", "del") as hgvs_source,
          -- capture the build_number for sorting
          CAST(REGEXP_EXTRACT(hgvs.assembly, r'\\d+') as INT64) as assembly_version
        FROM {P}.temp_variation tv
        JOIN `{S}.variation` v
        ON
          v.id = tv.variation_id
        cross join unnest (`clinvar_ingest.parseHGVS`(JSON_EXTRACT(v.content, r'$.HGVSlist')) ) as hgvs
        left join unnest(hgvs.molecular_consequence) as mc
        WHERE
          hgvs.nucleotide_expression.sequence_accession_version is not null
        group by
          v.id,
          hgvs.type,
          hgvs.assembly,
          hgvs.nucleotide_expression.sequence_accession_version,
          hgvs.nucleotide_expression.expression,
          hgvs.protein_expression.expression,
          hgvs.nucleotide_expression.mane_select,
          hgvs.nucleotide_expression.mane_plus_clinical
      ),
      h_issues AS (
        -- identify all issues for hgvs expressions in advance if possible
        SELECT
          h.*,
          CASE
          WHEN (NOT REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_')) THEN
            'sequence for accession not supported by vrs-python release'
          WHEN REGEXP_CONTAINS(h.hgvs_source, r'\\[[\\(\\)\\-0-9]+\\]') THEN
            'repeat expressions are not supported.'
          WHEN NOT h.has_balanced_parens THEN
            'expression contains unbalaned paretheses.'
          WHEN REGEXP_CONTAINS(h.hgvs_source, r'[0-9]+[\\+\\-][0-9]+') THEN
            'intronic positions are not resolvable in sequence.'
          WHEN REGEXP_CONTAINS(h.hgvs_source, r'^NP') THEN
            'protein expressions not supported.'
          WHEN NOT (
            --snv
            REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_[0-9]+\\.[0-9]+\\:[gmcnr]\\.[0-9]+[ACTGN]\\>[ACTGN]+$') OR
            -- same as ref
            REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_[0-9]+\\.[0-9]+\\:[gmcnr]\\.[0-9]+[ACTGN]?\\=$') OR
            -- single residue dup or del or delins?
            REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_[0-9]+\\.[0-9]+\\:[gmcnr]\\.[0-9]+(dup|del|delins)[ACTGN]*$') OR
            -- precise range dup or del or delins or ins
            REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_[0-9]+\\.[0-9]+\\:[gmcnr]\\.[0-9]+_[0-9]+(dup|del|delins|ins)[ACTGN]*$') OR
            -- inner/outer range dup or del
            REGEXP_CONTAINS(h.hgvs_source, r'^(NC|NT|NW|NG|NM|NR|XM|XR)_[0-9]+\\.[0-9]+\\:[gmcnr]\\.\\([0-9\\?]+_[0-9\\?]+\\)_\\([0-9\\?]+_[0-9\\?]+\\)(dup|del)[ACTGN]*$')
          ) THEN
            'unsupported hgvs expression.'
          END as issue
        from h
      ),
      h_top AS (
        SELECT
          *,
          -- when extracting 'has_range_endpoints', 'start_pos' and 'end_pos', ignore the unsupported LRG_??? accessions.
          REGEXP_CONTAINS(hgvs_source, r'[gmcnr]\\.\\([0-9\\?]+_[0-9\\?]+\\)_\\([0-9\\?]+_[0-9\\?]+\\)(dup|del)[ACTGN]*$') as has_range_endpoints,
          CAST(REGEXP_EXTRACT(hgvs_source, r'[gmcnr]\\.([0-9]+)') AS INT64) AS start_pos,
          CAST(REGEXP_EXTRACT(hgvs_source, r'[gmcnr]\\.[0-9]+_([0-9]+)') AS INT64) AS end_pos,
          CASE
            WHEN assembly_version=38 THEN 1
            WHEN assembly_version=37 THEN 2
            WHEN assembly_version=36 THEN 3
            ELSE 4
          END varlen_precedence
        FROM (
          SELECT *,
            ROW_NUMBER() OVER(
              PARTITION BY
                h_issues.variation_id,
                h_issues.accession
              ORDER BY
                h_issues.variation_id,
                h_issues.accession,
                h_issues.assembly_version DESC,
                h_issues.consq_label DESC,
                h_issues.has_balanced_parens DESC,
                h_issues.protein DESC,
                LENGTH(h_issues.nucleotide)
            ) AS rn
          FROM h_issues
        )
        WHERE rn = 1
      )
      select
        h_top.variation_id,
        h_top.accession,
        h_top.type,
        h_top.hgvs_source,
        h_top.issue,
        h_top.assembly,
        h_top.assembly_version,
        h_top.consq_id,
        h_top.consq_label,
        h_top.mane_select,
        h_top.mane_plus,
        h_top.has_range_endpoints,
        h_top.varlen_precedence,
        IF(h_top.start_pos is not NULL, IFNULL(h_top.end_pos, h_top.start_pos + 1) - h_top.start_pos, null) as derived_variant_length,
        ARRAY_AGG(
          STRUCT(
            h.nucleotide,
            h.protein )
          ORDER BY
            h.protein DESC
        ) as expr
      FROM h
      JOIN h_top
      ON
        h_top.variation_id = h.variation_id and
        h_top.accession = h.accession
      GROUP BY
        h_top.variation_id,
        h_top.accession,
        h_top.type,
        h_top.hgvs_source,
        h_top.issue,
        h_top.assembly,
        h_top.assembly_version,
        h_top.consq_id,
        h_top.consq_label,
        h_top.mane_select,
        h_top.mane_plus,
        h_top.has_range_endpoints,
        h_top.varlen_precedence,
        h_top.start_pos,
        h_top.end_pos
    """, '{VHHEAD}', vh_head);
    SET query_variation_hgvs = REPLACE(query_variation_hgvs, '{CT}', temp_create);
    SET query_variation_hgvs = REPLACE(query_variation_hgvs, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET query_variation_hgvs = REPLACE(query_variation_hgvs, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE query_variation_hgvs;

    -------------------------------------------------------------------------
    -- Step 4: Refine VRS class assignments using derived variant length
    --         and range endpoint information
    -------------------------------------------------------------------------
    SET query_refine_vrs_class = REPLACE("""
      UPDATE {P}.temp_variation tv
        SET tv.vrs_class =
          CASE
            WHEN (tv.variation_type IN ('Deletion', 'Duplication'))
              AND (var.derived_variant_length IS NULL OR var.derived_variant_length > 1000 OR var.has_range_endpoints) THEN
              'CopyNumberChange'
            WHEN tv.variation_type IN ('Deletion', 'Duplication', 'Indel', 'Insertion', 'Microsatellite', 'Tandem duplication', 'single nucleotide variant') AND NOT var.has_range_endpoints THEN
              'Allele'
            ELSE
              'Not Available'
          END
      FROM (
        SELECT
          *
        FROM (
          SELECT
            vl.variation_id,
            vl.has_range_endpoints,
            vl.derived_variant_length,
            row_number() over (partition by vl.variation_id order by vl.varlen_precedence, vl.derived_variant_length DESC NULLS LAST) as rn
          FROM {VL} vl
        )
        WHERE rn = 1
        UNION DISTINCT
        SELECT
          *
        FROM (
          SELECT
            vh.variation_id,
            vh.has_range_endpoints,
            vh.derived_variant_length,
            row_number() over (partition by vh.variation_id order by vh.varlen_precedence, vh.derived_variant_length DESC NULLS LAST) as rn
          FROM {VH} vh
          LEFT JOIN {VL} vl
          on
            vl.variation_id = vh.variation_id
          WHERE
            vl.variation_id is null
        )
        WHERE rn = 1
      ) var
      WHERE
        var.variation_id = tv.variation_id and
        tv.vrs_class is null
    """, '{VL}', vl_ref);
    SET query_refine_vrs_class = REPLACE(query_refine_vrs_class, '{VH}', vh_ref);
    SET query_refine_vrs_class = REPLACE(query_refine_vrs_class, '{CT}', temp_create);
    SET query_refine_vrs_class = REPLACE(query_refine_vrs_class, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET query_refine_vrs_class = REPLACE(query_refine_vrs_class, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE query_refine_vrs_class;

    -------------------------------------------------------------------------
    -- Step 5: Extract cross-references to external databases
    -------------------------------------------------------------------------
    SET query_variation_xref = REPLACE("""
      {VXHEAD} AS
      SELECT
        v.variation_id,
        xref.*
      FROM {P}.temp_variation v
      CROSS JOIN UNNEST(`clinvar_ingest.parseXRefs`(JSON_EXTRACT(v.content, r'$.XRefList'))) as xref
    """, '{VXHEAD}', vx_head);
    SET query_variation_xref = REPLACE(query_variation_xref, '{CT}', temp_create);
    SET query_variation_xref = REPLACE(query_variation_xref, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET query_variation_xref = REPLACE(query_variation_xref, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE query_variation_xref;

    -------------------------------------------------------------------------
    -- Step 6: Extract canonical SPDI expressions (internal temp table)
    -------------------------------------------------------------------------
    -- Derive the assembly from the CanonicalSPDI accession's OWN parsed location
    -- assembly (variation_loc, built in Step 2). ClinVar's CanonicalSPDI is usually
    -- on a GRCh38 accession but NOT always — a handful sit on GRCh37 accessions
    -- (e.g. NC_000011.9), so hardcoding GRCh38/38 mislabels them. When the SPDI
    -- accession's assembly can't be resolved from variation_loc, emit NULL rather
    -- than guessing, so downstream flags it as an exception.
    SET temp_variation_spdi_query = REPLACE("""
      {CT} {P}.temp_variation_spdi AS
      SELECT
        v.variation_id,
        a.assembly,
        a.assembly_version,
        SPLIT(v.canonical_spdi, ':')[OFFSET(0)] as accession,
        v.canonical_spdi as spdi_source
      FROM {P}.temp_variation v
      LEFT JOIN (
        -- One assembly per (variation_id, accession). When an accession legitimately
        -- appears at multiple assemblies — the mitochondrion NC_012920.1 is shared by
        -- GRCh37/38, as are some alt scaffolds — prefer the highest (GRCh38), so it stays
        -- consistent with the catvar temp_seqref dedup (which also prefers GRCh38) instead
        -- of picking arbitrarily.
        SELECT variation_id, accession, assembly, assembly_version
        FROM {VL}
        QUALIFY ROW_NUMBER() OVER (
          PARTITION BY variation_id, accession
          ORDER BY assembly_version DESC NULLS LAST
        ) = 1
      ) a
      ON
        a.variation_id = v.variation_id
        AND a.accession = SPLIT(v.canonical_spdi, ':')[OFFSET(0)]
      WHERE v.canonical_spdi is not null
    """, '{VL}', vl_ref);
    SET temp_variation_spdi_query = REPLACE(temp_variation_spdi_query, '{CT}', temp_create);
    SET temp_variation_spdi_query = REPLACE(temp_variation_spdi_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET temp_variation_spdi_query = REPLACE(temp_variation_spdi_query, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE temp_variation_spdi_query;

    -------------------------------------------------------------------------
    -- Step 7: Consolidate all expression sources with 9-level precedence
    --         hierarchy (internal temp table)
    -------------------------------------------------------------------------
    SET temp_variation_members_query = REPLACE("""
      {CT} {P}.temp_variation_members AS
      WITH var_source as (
        select DISTINCT
          variation_id,
          assembly_version,
          accession,
          'spdi' as fmt,
          spdi_source as source,
          CAST(null AS STRING) as issue,
          -- #1 spdi (genomic top level b38 alleles)
          1 as precedence
        from  {P}.temp_variation_spdi vs
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #2 hgvs (genomic, top-level)
          2 as precedence
        from  {VH} vh
        where
          vh.hgvs_source is not null
          and
          vh.type = 'genomic, top-level'
        UNION ALL
        select DISTINCT
          vl.variation_id,
          vl.assembly_version,
          vl.accession,
          'gnomad' as fmt,
          vl.gnomad_source as source,
          CAST(null AS STRING) as issue,
          -- #3 gnomad location-based (genomic 'top-level')
          3 as precedence
        from  {VL} vl
        where
          vl.gnomad_source is not null
        UNION ALL
        select DISTINCT
          vl.variation_id,
          vl.assembly_version,
          vl.accession,
          'hgvs' as fmt,
          vl.loc_hgvs_source as source,
          vl.loc_hgvs_issue as issue,
          -- #4 derived hgvs for non-precise location regions (genomic 'top-level')
          4 as precedence
        from  {VL} vl
        where
          vl.loc_hgvs_source is not null
          and
          vl.gnomad_source is null
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #5 hgvs genomic (not top-level)
          5 as precedence
        from  {VH} vh
        where
          vh.hgvs_source is not null
          and
          vh.type = 'genomic'
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #6 hgvs coding mane select
          6 as precedence
        from {VH} vh
        where
          vh.hgvs_source is not null
          and
          IFNULL(vh.mane_select, FALSE)
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #7 hgvs coding mane plus
          7 as precedence
        from {VH} vh
        where
          vh.hgvs_source is not null
          and
          IFNULL(vh.mane_plus, FALSE)
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #8 hgvs coding not mane select or plus
          8 as precedence
        from {VH} vh
        where
          vh.hgvs_source is not null
          and
          vh.type = 'coding' and not IFNULL(vh.mane_select, FALSE) and not IFNULL(vh.mane_plus, FALSE)
        UNION ALL
        select DISTINCT
          vh.variation_id,
          vh.assembly_version,
          vh.accession,
          'hgvs' as fmt,
          vh.hgvs_source as source,
          vh.issue,
          -- #9 hgvs not 'genomic, top-level' or 'genomic' or 'coding'
          9 as precedence
        from {VH} vh
        where
          vh.hgvs_source is not null
          and
          vh.type not in ('genomic, top-level', 'genomic', 'coding')
      )
      select
        vs.variation_id,
        vs.assembly_version,
        vs.accession,
        tv.vrs_class,
        tv.absolute_copies,
        tv.range_copies,
        vs.fmt,
        vs.source,
        IF(
          tv.vrs_class = 'CopyNumberChange',
          CASE
            WHEN tv.variation_type IN ('Deletion', 'copy number loss') THEN
              "loss"
            WHEN tv.variation_type IN ('Duplication', 'copy number gain') THEN
              "gain"
            ELSE
              NULL
            END,
          NULL
        ) as copy_change_type,
        IFNULL(tv.issue,IFNULL(vs.issue, IF(vs.fmt is null OR vs.source is NULL, 'Pipeline could not identify a valid source or fmt', NULL))) as issue,
        vs.precedence,
        vh.type as hgvs_type,
        vh.consq_id,
        vh.consq_label,
        vh.mane_select,
        vh.mane_plus,
        vh.expr as hgvs,
        vl.chr,
        vl.variant_length
      from (
        select
          variation_id,
          assembly_version,
          accession,
          fmt,
          source,
          issue,
          precedence,
          row_number() over (partition by variation_id, accession order by precedence) as rn
        from var_source
      ) vs
      join {P}.temp_variation tv
      on
        tv.variation_id = vs.variation_id
      left join {VH} vh
      on
        vh.variation_id = vs.variation_id
        and
        vh.accession = vs.accession
        and
        IFNULL(vh.assembly_version,0) = IFNULL(vs.assembly_version,0)
      left join {VL} vl
      on
        vl.variation_id = vs.variation_id
        and
        vl.accession = vs.accession
        and
        IFNULL(vl.assembly_version,0) = IFNULL(vs.assembly_version,0)
      where vs.rn = 1
      -- 27,578,636 (2024-03-31)
      -- 27,576,509 (2024-04-07)
    """, '{VH}', vh_ref);
    SET temp_variation_members_query = REPLACE(temp_variation_members_query, '{VL}', vl_ref);
    SET temp_variation_members_query = REPLACE(temp_variation_members_query, '{CT}', temp_create);
    SET temp_variation_members_query = REPLACE(temp_variation_members_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET temp_variation_members_query = REPLACE(temp_variation_members_query, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE temp_variation_members_query;

    -------------------------------------------------------------------------
    -- Step 8: Select single best expression per variation and build final
    --         output. Full mode attaches `mappings` inline; incremental mode
    --         builds the core (no mappings) to staging and recomputes mappings
    --         globally from the merged variation_xref after the merge.
    -------------------------------------------------------------------------
    SET query_variation_identity = REPLACE("""
      {VIHEAD} AS
        -- find potential resolvable originating alleles per variation_id
        WITH v AS (
          select
            *
          from (
            select
              vm.*,
              row_number() over (partition by vm.variation_id order by vm.precedence, vm.assembly_version desc, vm.issue, vm.accession) as rn
            from {P}.temp_variation_members vm
            )
          where rn = 1
          -- 2,814,021 (2024-03-31)
          -- 2,797,069 (2024-04-07)
        ){XM_CTES}
        SELECT
          tv.variation_id,
          tv.name,
          v.assembly_version,
          v.accession,
          IFNULL(v.vrs_class, IFNULL(tv.vrs_class, 'Unknown')) as vrs_class,
          v.absolute_copies,
          v.range_copies,
          v.fmt,
          v.source,
          v.copy_change_type,
          IFNULL(v.issue, IFNULL(tv.issue, IF(v.variation_id is null, 'No viable variation members identified.', null))) as issue,
          v.precedence,
          tv.variation_type,
          tv.subclass_type,
          tv.cytogenetic,
          v.chr,
          v.variant_length,{MAPPINGS_COL}

        FROM {P}.temp_variation tv
        LEFT JOIN v
        ON
          v.variation_id = tv.variation_id{MAPPINGS_JOIN}
    """, '{VIHEAD}', vi_head);
    SET query_variation_identity = REPLACE(query_variation_identity, '{XM_CTES}', xm_ctes);
    SET query_variation_identity = REPLACE(query_variation_identity, '{MAPPINGS_COL}', mappings_col);
    SET query_variation_identity = REPLACE(query_variation_identity, '{MAPPINGS_JOIN}', mappings_join);
    SET query_variation_identity = REPLACE(query_variation_identity, '{CT}', temp_create);
    SET query_variation_identity = REPLACE(query_variation_identity, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    SET query_variation_identity = REPLACE(query_variation_identity, '{S}', rec.schema_name);

    EXECUTE IMMEDIATE query_variation_identity;

    -----------------------------------------------------------------------
    -- Step 9 (incremental only): UNION-CTAS merge the four outputs — carry
    -- forward the unchanged baseline rows and union in the freshly parsed
    -- changed rows. Explicit column lists so any schema/column-order drift
    -- errors (the version-invalidation signal) instead of silently corrupting.
    -- variation_xref is merged BEFORE variation_identity, because the global
    -- `mappings` recompute reads the merged {S}.variation_xref.
    -----------------------------------------------------------------------
    IF eff_incremental THEN
      -- merge variation_loc
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_loc` AS
        SELECT
          variation_id, variation_type, for_display, assembly, assembly_accession_version, assembly_status,
          accession, chr, `start`, `stop`, inner_start, inner_stop, outer_start, outer_stop, variant_length,
          display_start, display_stop, position_vcf, reference_allele_vcf, alternate_allele_vcf, strand,
          reference_allele, alternate_allele, for_display_length, assembly_version, gnomad_source,
          loc_hgvs_source, loc_hgvs_issue, varlen_precedence, has_range_endpoints, derived_variant_length,
          derived_start, derived_stop
        FROM `{BASE}.variation_loc`
        WHERE variation_id NOT IN (
          SELECT variation_id FROM {P}.changed_variation_ids
          UNION DISTINCT
          SELECT variation_id FROM {P}.removed_variation_ids
        )
        UNION ALL
        SELECT
          variation_id, variation_type, for_display, assembly, assembly_accession_version, assembly_status,
          accession, chr, `start`, `stop`, inner_start, inner_stop, outer_start, outer_stop, variant_length,
          display_start, display_stop, position_vcf, reference_allele_vcf, alternate_allele_vcf, strand,
          reference_allele, alternate_allele, for_display_length, assembly_version, gnomad_source,
          loc_hgvs_source, loc_hgvs_issue, varlen_precedence, has_range_endpoints, derived_variant_length,
          derived_start, derived_stop
        FROM {P}.stg_variation_loc
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- merge variation_hgvs
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_hgvs` AS
        SELECT
          variation_id, accession, type, hgvs_source, issue, assembly, assembly_version, consq_id,
          consq_label, mane_select, mane_plus, has_range_endpoints, varlen_precedence, derived_variant_length, expr
        FROM `{BASE}.variation_hgvs`
        WHERE variation_id NOT IN (
          SELECT variation_id FROM {P}.changed_variation_ids
          UNION DISTINCT
          SELECT variation_id FROM {P}.removed_variation_ids
        )
        UNION ALL
        SELECT
          variation_id, accession, type, hgvs_source, issue, assembly, assembly_version, consq_id,
          consq_label, mane_select, mane_plus, has_range_endpoints, varlen_precedence, derived_variant_length, expr
        FROM {P}.stg_variation_hgvs
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- merge variation_xref
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_xref` AS
        SELECT variation_id, db, id, type, status, url, ref_field
        FROM `{BASE}.variation_xref`
        WHERE variation_id NOT IN (
          SELECT variation_id FROM {P}.changed_variation_ids
          UNION DISTINCT
          SELECT variation_id FROM {P}.removed_variation_ids
        )
        UNION ALL
        SELECT variation_id, db, id, type, status, url, ref_field
        FROM {P}.stg_variation_xref
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;

      -- merge variation_identity core + recompute mappings GLOBALLY from merged {S}.variation_xref
      SET query_merge = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.variation_identity` AS
        WITH core AS (
          SELECT
            variation_id, name, assembly_version, accession, vrs_class, absolute_copies, range_copies,
            fmt, source, copy_change_type, issue, precedence, variation_type, subclass_type, cytogenetic,
            chr, variant_length
          FROM `{BASE}.variation_identity`
          WHERE variation_id NOT IN (
            SELECT variation_id FROM {P}.changed_variation_ids
            UNION DISTINCT
            SELECT variation_id FROM {P}.removed_variation_ids
          )
          UNION ALL
          SELECT
            variation_id, name, assembly_version, accession, vrs_class, absolute_copies, range_copies,
            fmt, source, copy_change_type, issue, precedence, variation_type, subclass_type, cytogenetic,
            chr, variant_length
          FROM {P}.stg_variation_identity
        ),
        x AS (
          SELECT
            x.id as variation_id,
            x.db as system,
            x.id as code,
            IF(x.db='ClinGen', 'closeMatch', 'relatedMatch') as relation
          FROM `{S}.variation_xref` x
          group by
            x.id,
            x.db,
            x.id
        ),
        m as (
          SELECT
            x.variation_id,
            ARRAY_AGG(STRUCT(x.system, x.code, x.relation)) as mappings
          FROM x
          GROUP BY x.variation_id
        )
        SELECT
          core.*,
          m.mappings
        FROM core
        LEFT JOIN m
        ON core.variation_id = m.variation_id
      """, '{BASE}', baseline_schema);
      SET query_merge = REPLACE(query_merge, '{P}', IF(debug, rec.schema_name, '_SESSION'));
      SET query_merge = REPLACE(query_merge, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_merge;
    END IF;

    IF NOT debug THEN
      DROP TABLE _SESSION.temp_variation;
      DROP TABLE _SESSION.temp_variation_spdi;
      DROP TABLE _SESSION.temp_variation_members;
      IF eff_incremental THEN
        DROP TABLE IF EXISTS _SESSION.stg_variation_loc;
        DROP TABLE IF EXISTS _SESSION.stg_variation_hgvs;
        DROP TABLE IF EXISTS _SESSION.stg_variation_xref;
        DROP TABLE IF EXISTS _SESSION.stg_variation_identity;
        DROP TABLE IF EXISTS _SESSION.changed_variation_ids;
        DROP TABLE IF EXISTS _SESSION.removed_variation_ids;
      END IF;
    END IF;

  END FOR;
END;


-- Full rebuild (unchanged signature/behavior)
CREATE OR REPLACE PROCEDURE `clinvar_ingest.variation_identity`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.variation_identity_build`(on_date, debug, FALSE);
END;


-- Incremental rebuild (carry-forward + merge). Only assert this when the
-- variation_identity transform is unchanged since the baseline release.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.variation_identity_incremental`(on_date DATE, debug BOOL)
BEGIN
  CALL `clinvar_ingest.variation_identity_build`(on_date, debug, TRUE);
END;
