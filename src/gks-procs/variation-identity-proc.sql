
CREATE OR REPLACE PROCEDURE `clinvar_ingest.variation_identity_proc`(on_date DATE)
BEGIN

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO
    -- the only way to acquire consistent copy number count info is from the scv data
    -- using the AbsoluteCopyNumber and CopyNumberTuple submitted values
    -- the presumption is that if multiple scvs exist for the same variant they will all
    -- have the same absCN or CNTuple value. If not exceptions will likely occur.
    EXECUTE IMMEDIATE FORMAT("""
      CREATE or REPLACE TABLE `%s.temp_variation`
      AS
      WITH cn AS (
        select 
          x.variation_id,
          x.variation_name,
          string_agg(distinct a.attribute.type) as copy_type,
          string_agg(distinct a.attribute.value) as copy_value
        from (
          select
            v.id as variation_id,
            v.name as variation_name,
            cav.clinical_assertion_id as scv_id,
            `clinvar_ingest.parseAttributeSet`(cav.content) as attribs
          from `%s.clinical_assertion_variation` cav
          join `%s.clinical_assertion` ca on ca.id = cav.clinical_assertion_id
          join `%s.variation` v on v.id = ca.variation_id
          where cav.content like '%%CopyNumber%%'
        ) x
        cross join unnest(x.attribs) as a
        where a.attribute.type in ('AbsoluteCopyNumber','CopyNumberTuple')
        group by x.variation_id, x.variation_name 
      ),
      var AS (
        SELECT 
          v.id as variation_id,
          v.name,
          v.subclass_type,
          v.variation_type,
          JSON_EXTRACT_SCALAR(v.content, "$.Location.CytogeneticLocation['$']") as cytogenetic,
          JSON_EXTRACT_SCALAR(v.content, "$['CanonicalSPDI']['$']") as canonical_spdi,
          CAST(IF(cn.copy_type = 'AbsoluteCopyNumber', cn.copy_value, null) AS INT64) as absolute_copies,
          IF(cn.copy_type = 'CopyNumberTuple', ARRAY(SELECT CAST(elem AS INT64) FROM UNNEST(SPLIT(cn.copy_value)) as elem), null) as range_copies,
          v.content
        FROM `%s.variation` v
        LEFT JOIN cn on cn.variation_id = v.id
        WHERE 
          -- bad variant list DO NOT try to deal with these right now, these have been submitted to clinvar for correction
          v.id not in (
            "3027503" -- two variants in one! two locations, etc, but different snvs?!
          )
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
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );
 
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_loc` AS
      WITH l AS (
        SELECT 
          v.variation_id,
          v.variation_type,
          seq.*,
          CAST(REGEXP_EXTRACT(seq.assembly, r'\\d+') as INT64) as assembly_version,
          -- derive a vcf/gnomad-formatted representation from the vcf data if available and 
          -- required non-nulls are position_vcf, ref_allele_vcf, alt_allele_vcf and accession
          -- SPECIAL case: some clinvar locations have a chromosome value of 'Un', these should be skipped)
          IF(seq.chr = 'Un', NULL, FORMAT('%%s-%%i-%%s-%%s',seq.chr, seq.position_vcf, seq.reference_allele_vcf, seq.alternate_allele_vcf)) as gnomad_source,
          IF(seq.accession is not null, 
            `clinvar_ingest.deriveHGVS`(v.variation_type,seq), 
            null
          ) as loc_hgvs_source
        FROM `%s.temp_variation` v
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
        IFNULL(CAST(l.start as STRING), FORMAT('[%%s,%%s]', IFNULL(CAST(l.outer_start as STRING), 'null'), IFNULL(CAST(l.inner_start as STRING), 'null'))) as derived_start,
        IFNULL(CAST(l.stop as STRING), FORMAT('[%%s,%%s]', IFNULL(CAST(l.inner_stop as STRING), 'null'), IFNULL(CAST(l.outer_stop as STRING), 'null'))) as derived_stop
      FROM l
      LEFT JOIN li 
      ON 
        li.variation_id = l.variation_id and 
        li.accession = l.accession and 
        -- use additional assembly string match since mito accessions are duplicated across assemblies
        -- without this it will produce a cartesian product of rows for all mito variants.
        li.assembly = l.assembly
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_hgvs` AS

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
          STRING_AGG(DISTINCT IF(STARTS_WITH(mc.id, mc.db), mc.id, FORMAT('%%s:%%s', mc.db, mc.id)) ) as consq_id,
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
        FROM `%s.temp_variation` tv
        JOIN `%s.variation` v
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
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      UPDATE `%s.temp_variation` tv
        SET tv.vrs_class = 
          CASE 
            WHEN (tv.variation_type IN ('Deletion', 'Duplication')) 
              AND (var.derived_variant_length IS NULL OR var.derived_variant_length > 1000 OR var.has_range_endpoints) THEN
              'CopyNumberChange'
            WHEN tv.variation_type IN ('Deletion', 'Duplication', 'Indel', 'Insertion', 'Microsatellite', 'Tandem duplication', 'single nucleotide variant', 'Microsatellite') AND NOT var.has_range_endpoints THEN
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
            row_number() over (partition by vl.variation_id order by vl.varlen_precedence) as rn
          FROM `%s.variation_loc` vl
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
            row_number() over (partition by vh.variation_id order by vh.varlen_precedence) as rn
          FROM `%s.variation_hgvs` vh
          LEFT JOIN `%s.variation_loc` vl
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
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_xref` AS
      SELECT 
        v.variation_id, 
        xref.*
      FROM `%s.temp_variation` v
      CROSS JOIN UNNEST(`clinvar_ingest.parseXRefs`(JSON_EXTRACT(v.content, r'$.XRefList'))) as xref
    """, 
    rec.schema_name, 
    rec.schema_name
    );
 
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_spdi` AS
      SELECT
        v.variation_id,
        'GRCh38' as assembly,
        38 as assembly_version,
        SPLIT(v.canonical_spdi, ":")[OFFSET(0)] as accession,
        v.canonical_spdi as spdi_source
      FROM `%s.temp_variation` v
      WHERE v.canonical_spdi is not null
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_members` AS
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
        from  `%s.variation_spdi` vs
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
        from  `%s.variation_hgvs` vh    
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
        from  `%s.variation_loc` vl
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
        from  `%s.variation_loc` vl
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
        from  `%s.variation_hgvs` vh
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
        from `%s.variation_hgvs` vh
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
        from `%s.variation_hgvs` vh
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
        from `%s.variation_hgvs` vh
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
        from `%s.variation_hgvs` vh
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
      join `%s.temp_variation` tv
      on
        tv.variation_id = vs.variation_id
      left join `%s.variation_hgvs` vh
      on
        vh.variation_id = vs.variation_id
        and
        vh.accession = vs.accession
        and
        IFNULL(vh.assembly_version,0) = IFNULL(vs.assembly_version,0)
      left join `%s.variation_loc` vl
      on
        vl.variation_id = vs.variation_id
        and
        vl.accession = vs.accession
        and
        IFNULL(vl.assembly_version,0) = IFNULL(vs.assembly_version,0)
      where vs.rn = 1
      -- 27,578,636 (2024-03-31)
      -- 27,576,509 (2024-04-07)
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.variation_identity` AS 
        -- find potential resolvable originating alleles per variation_id
        WITH v AS (
          select
            *
          from (
            select 
              vm.*,
              row_number() over (partition by vm.variation_id order by vm.precedence, vm.assembly_version desc, vm.issue, vm.accession) as rn
            from `%s.variation_members` vm
            )
          where rn = 1
          -- 2,814,021 (2024-03-31)
          -- 2,797,069 (2024-04-07)
        ),
        x AS (
          SELECT 
            x.id as variation_id, 
            x.db as system,
            x.id as code,
            IF(x.db='ClinGen', 'closeMatch', 'relatedMatch') as relation
          FROM `%s.variation_xref` x
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
          v.variant_length,
          m.mappings,

        FROM `%s.temp_variation` tv
        LEFT JOIN v
        ON
          v.variation_id = tv.variation_id
        LEFT JOIN m
        ON tv.variation_id = m.variation_id
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

  END FOR;
END;