CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_catvar_proc`(on_date DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_seqref`
      as
      SELECT DISTINCT
        vrs.in.accession as name,
        vrs.out.location.sequenceReference.*,
        CASE 
        WHEN LEFT(vrs.in.accession,3) IN ('AC_','NC_','NG_','NT_','NW_','NZ_') THEN 'genomic'
        WHEN LEFT(vrs.in.accession,3) IN ('NM_','XM_') THEN 'mrna'
        WHEN LEFT(vrs.in.accession,3) IN ('NR_','XR_') THEN 'rna'
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
      from `%s.gks_vrs` vrs
      where
        vrs.out.location.sequenceReference.refgetAccession is not null 
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_seqloc`
      as
      WITH x AS (
        select DISTINCT
          vrs.out.location.*  
        from `%s.gks_vrs` vrs
        where
          vrs.out.location.id is not null 
      )
      select
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
      from x
      join `%s.gks_seqref` sq
      on
        sq.refgetAccession = x.sequenceReference.refgetAccession
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_ctxvar_expression`
      AS
      WITH exp_item AS ( 
        select 
          vrs.in.variation_id,
          vrs.in.accession,
          vrs.in.fmt as syntax,
          vrs.in.source as value,
          CAST(null as STRING) as hgvs_type,
          CAST(null as STRING) as issue,
          1 as precedence,
          vrs.in.assembly_version
        from `%s.gks_vrs` vrs
        where 
          vrs.in.fmt = 'spdi' 
          and
          vrs.out.id is not null
        UNION ALL
        -- select DISTINCT to eliminate the dupe MT occurences across builds
        select DISTINCT
          vl.variation_id,
          IFNULL(
            vl.accession,
            FORMAT('%%i-chr%%s', vl.assembly_version, vl.chr)
          ) as accession,
          'gnomad' as syntax,
          vl.gnomad_source as value,
          CAST(null as STRING) as hgvs_type,
          CAST(null as STRING) as issue,
          3 as precedence,
          vl.assembly_version
        from `%s.variation_loc` vl
        join `%s.gks_vrs` vrs
        on
          vl.variation_id = vrs.in.variation_id
          AND
          vl.accession = vrs.in.accession
          AND
          vl.assembly_version is not distinct from vrs.in.assembly_version
        where
            vl.gnomad_source is not null 
            and 
            vrs.out.id is not null
        UNION ALL
        select 
          vh.variation_id,
          vh.accession,
          format('hgvs.%%s', IFNULL(REGEXP_EXTRACT(e.nucleotide, r':([gmcnrp])\\.'), LEFT(vh.type, 1))) as syntax,
          e.nucleotide as value,
          vh.type as hgvs_type,
          vh.issue,
          2 as precedence,
          vh.assembly_version
        from `%s.variation_hgvs` vh
        cross join unnest(expr) as e
        join `%s.gks_vrs` vrs
        on
          vh.variation_id = vrs.in.variation_id
          AND
          vh.accession = vrs.in.accession
          AND
          vh.assembly_version is not distinct from vrs.in.assembly_version
        where
          e.nucleotide is not null 
          and 
          vrs.out.id is not null
        UNION ALL
        select DISTINCT
          vl.variation_id,
          vl.accession,
          'hgvs.g' as syntax,
          vl.loc_hgvs_source as value,
          'genomic' as hgvs_type,
          vl.loc_hgvs_issue as issue,
          4 as precedence,    
          vl.assembly_version
        from `%s.variation_loc` vl
        join `%s.gks_vrs` vrs
        on
          vl.variation_id = vrs.in.variation_id
          AND
          vl.accession = vrs.in.accession
          AND
          vl.assembly_version is not distinct from vrs.in.assembly_version
        left join `%s.variation_hgvs` vh
        on
          vh.variation_id = vl.variation_id
          and
          vh.accession = vl.accession
          and
          vh.assembly_version is not distinct from vl.assembly_version
        where
          vl.gnomad_source is null
          and
          vl.loc_hgvs_source is not null
          and
          vh.variation_id is null
          and 
          vrs.out.id is not null
      )
      select
        exp_item.variation_id,
        exp_item.accession,
        exp_item.assembly_version,
        ARRAY_AGG(exp_item.value ORDER BY exp_item.hgvs_type DESC, exp_item.precedence)[0] as name,
        (CASE exp_item.assembly_version WHEN 38 THEN 'GRCh38' WHEN 37 THEN 'GRCh37' WHEN 36 THEN 'NCBI36' ELSE null END) as assembly,
        ARRAY_AGG(STRUCT(exp_item.syntax, exp_item.value) ORDER BY exp_item.precedence) as expressions,
        ARRAY_AGG(DISTINCT exp_item.hgvs_type IGNORE NULLS ORDER BY exp_item.hgvs_type DESC) as types,
        ARRAY_AGG(DISTINCT exp_item.issue IGNORE NULLS) as issues
      from exp_item
      group by 
        exp_item.variation_id,
        exp_item.accession,
        exp_item.assembly_version       
    """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_ctxvar`
      as
      WITH ctxvar AS (
        select 
          vrs.in.variation_id,
          vrs.in.vrs_class,
          vrs.in.issue,
          CASE vrs.`out`.type
          WHEN 'Allele' THEN 'CanonicalAllele' 
          WHEN 'CopyNumberChange' THEN 'CategoricalCnvChange' 
          WHEN 'CopyNumberCount' THEN 'CategoricalCnvCount' 
          ELSE 'Non-Constrained' 
          END as catvar_type,
          vrs.in.name,
          vrs.out.*  
        from `%s.gks_vrs` vrs 
      )
      select DISTINCT
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
      from ctxvar
      left join `%s.gks_ctxvar_expression` exp
      on
        exp.variation_id = ctxvar.variation_id
      left join `%s.gks_seqloc` sl
      on
        sl.id = ctxvar.location.id    
      
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_catvar_extension`
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
        -- clinvar hgvs list structure nucleotide, protein, molecular consequence, mane select, mane pluse 
        SELECT 
          vh.variation_id,
          vh.accession,
          format('hgvs.%%s', IFNULL(REGEXP_EXTRACT(exp.nucleotide, r':([gmcnrp])\\.'), '?')) as nucleotide_syntax,
          exp.nucleotide as nucleotide_value,
          format('hgvs.%%s', IFNULL(REGEXP_EXTRACT(exp.protein, r':([gmcnrp])\\.'), '?')) as protein_syntax,
          exp.protein as protein_value,
          SPLIT(vh.consq_id) as consq_ids,
          vh.hgvs_source,
          vh.mane_plus,
          vh.mane_select ,
          vh.type
        FROM `%s.variation_hgvs` vh
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
              [format('https://identifiers.org/%%s',hcsq.consq_code)] as iris
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
        select
          ga.variation_id,
          ARRAY_AGG(
            STRUCT(
              g.id as entrez_gene_id,
              g.hgnc_id,
              g.symbol,
              ga.relationship_type,
              ga.source,
              IF(
                g.hgnc_id is null,
                [
                  FORMAT('https://identifiers.org/ncbigene:%%s',g.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/gene/%%s',g.id)
                ],
                [
                  FORMAT('https://identifiers.org/%%s',LOWER(g.hgnc_id)),          
                  FORMAT('https://identifiers.org/ncbigene:%%s',g.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/gene/%%s',g.id)
                ]
              ) as iris
            )
          ) as genes
        from `%s.gene_association` ga
        join `%s.gene` g
        on
          g.id = ga.gene_id
        GROUP BY
          ga.variation_id
      ),
      cat_ext_item AS (
        SELECT
          ctx.variation_id,
          'categorical variation type' as name,
          ctx.catvar_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `%s.gks_ctxvar` ctx
        union all
        SELECT
          ctx.variation_id,
          'defining vrs variation type' as name,
          ctx.vrs_class as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        FROM `%s.gks_ctxvar` ctx
        union all
        select
          variation_id,
          'clinvar variation type' as name,
          vi.variation_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        from `%s.variation_identity` vi
        WHERE 
          vi.variation_type is not null
        union all
        select
          variation_id,
          'clinvar subclass type' as name,
          vi.subclass_type as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        from `%s.variation_identity` vi
        where 
          vi.subclass_type is not null
        union all
        select
          variation_id,
          'clinvar cytogenetic location' as name,
          vi.cytogenetic as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        from `%s.variation_identity` vi
        where 
          vi.cytogenetic is not null
        UNION ALL
        select
          ctx.variation_id,
          'vrs pre-processing issue' as name,
          ctx.vrs_issue as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        from `%s.gks_ctxvar` ctx
        where
          ctx.vrs_issue is not null
        UNION ALL
        select
          vrs.in.variation_id,
          'vrs processing exception' as name,
          vrs.out.errors as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          null as value_gene_array
        from `%s.gks_vrs` vrs
        where 
          vrs.out.errors is not null
        UNION ALL
        select
          vhl.variation_id,
          'clinvar hgvs list' as name,
          CAST(null as STRING) as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          vhl.value as value_hgvs_array,
          null as value_gene_array
        from var_ext_hgvs_list vhl
        UNION ALL
        select
          vgl.variation_id,
          'clinvar gene list' as name,
          CAST(null as STRING) as value_string,
          CAST(null as BOOLEAN) as value_boolean,
          null as value_coding,
          null as value_hgvs_array,
          vgl.genes as value_gene_array
        from var_ext_gene_list vgl
      )
        select
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
        from cat_ext_item x
        group by
          x.variation_id
    """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_catvar_mappings`
      AS
      WITH catvar_mappings AS (

        SELECT 
          vrs.in.variation_id,
          STRUCT(
            'ClinVar' as system,
            vrs.in.variation_id as code,
            [FORMAT('https://identifiers.org/clinvar:%%s',vrs.in.variation_id)] as iris
          ) as coding,
          'exactMatch' as relation
        FROM `%s.gks_vrs` vrs 
        where vrs.in.variation_id is not null

        UNION ALL

        SELECT 
          x.variation_id,
          STRUCT(
            x.db as system,
            x.id as code,
            CASE LOWER(x.db)
            WHEN 'clinvar' THEN [FORMAT('https://identifiers.org/clinvar:%%s',x.id)]
            WHEN 'clingen' THEN [FORMAT('https://reg.clinicalgenome.org/redmine/projects/registry/genboree_registry/by_caid?caid=%%s', x.id)]
            WHEN 'dbvar' THEN [FORMAT('https://www.ncbi.nlm.nih.gov/dbvar/variants/%%s', x.id)]
            WHEN 'dbsnp' THEN [FORMAT('https://identifiers.org/dbsnp:rs%%s', x.id)]
            WHEN 'pharmgkb clinical annotation' THEN [FORMAT('https://www.pharmgkb.org/clinicalAnnotation/%%s', x.id)]
            WHEN 'omim' THEN [FORMAT('http://www.omim.org/entry/%%s', REPLACE(x.id, '.','#'))]
            WHEN 'uniprotkb' THEN [FORMAT('https://www.uniprot.org/uniprot/%%s', x.id)]
            WHEN 'genetic testing registry (gtr)' THEN [FORMAT('https://www.ncbi.nlm.nih.gov/tests/%%s', x.id)]
            ELSE [] -- others exist which haven't been reconciled (e.g. VARSOME, BIC, Leiden, LOVD, etc..)
            END as iris
          ) as coding,
          -- note that there will be explicit 'clinvar' xrefs for haplotypes and genotypes that are related to snvs and haplotypes, so we will use 'relatedMatch' on those
          CASE LOWER(x.db)
          WHEN 'clingen' THEN 'closeMatch'
          ELSE 'relatedMatch'
          END as relation
        FROM `%s.variation_xref` x  
      )
      SELECT
        m.variation_id,
        ARRAY_AGG(STRUCT(m.coding, m.relation)) as mappings
      FROM catvar_mappings m
      GROUP BY m.variation_id    
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_catvar_pre`
      AS
      WITH catvar AS (
        SELECT
          ctx.variation_id,
          ctx.catvar_type,
          FORMAT('clinvar:%%s', ctx.variation_id) as id,
          'CategoricalVariant' as type,
          ctx.catvar_name as name,
          STRUCT(
            ctx.name,
            ctx.id,
            ctx.digest,
            ctx.type,
            ctx.location,
            ctx.state,
            ctx.copies,
            ctx.copyChange,
            ctx.expressions
          ) as member
        FROM `%s.gks_ctxvar` ctx
        -- safe guard for upstream vrs process that returns bad records
        WHERE ctx.variation_id is not null
      ),
      cv_constraint_item AS (
        SELECT
          ctx.variation_id,
          'DefiningAlleleConstraint' as type,
          FORMAT('#/%%s/members/0/', ctx.variation_id) as allele,
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
                'http://www.sequenceontology.org' as system,
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
        SELECT
          ctx.variation_id,
          'DefiningLocationConstraint' as type,
          null as allele,
          FORMAT('#/%%s/members/0/location/', ctx.variation_id) as location,
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
        SELECT
          ctx.variation_id,
          'CopyCountConstraint' as type,
          null as allele,
          null as location,
          null as matchCharacteristic,
          null as relations,
          ctx.member.copies,
          null as copyChange
        FROM catvar ctx
        WHERE 
          ctx.catvar_type = 'CategoricalCnvCount'
        UNION ALL
        SELECT
          ctx.variation_id,
          'CopyChangeConstraint' as type,
          null as allele,
          null as location,
          null as matchCharacteristic,
          null as relations,
          CAST(null as INTEGER) as copies,
          ctx.member.copyChange
        FROM catvar ctx
        WHERE 
          ctx.catvar_type = 'CategoricalCnvChange'
      ),
      cv_constraints AS (
        select
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
        from catvar cv
        left join cv_constraint_item cci
        on
          cv.variation_id = cci.variation_id
        GROUP BY 
          cv.variation_id,
          cv.name
      )
      select 
        cv.id,
        cv.type,
        cv.name,
        cvc.constraints,
        [cv.member] as members,
        cvext.extensions,
        vm.mappings
      from catvar cv
      left join cv_constraints cvc
      on
        cvc.variation_id = cv.variation_id
      left join `%s.gks_catvar_extension` cvext
      on
        cvext.variation_id = cv.variation_id
      left join `%s.gks_catvar_mappings` vm
      ON
        vm.variation_id = cv.variation_id        
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_catvar`
      AS
      WITH x as (
        SELECT 
          cv.id,
          JSON_STRIP_NULLS(
            TO_JSON(cv),
            remove_empty => TRUE
          ) AS json_data
        FROM `%s.gks_catvar_pre` cv
      )
      select 
        x.id, 
        `clinvar_ingest.normalizeAndKeyById`(x.json_data) as rec 
      from x
    """, 
    rec.schema_name, 
    rec.schema_name
    );

  END FOR;

END;