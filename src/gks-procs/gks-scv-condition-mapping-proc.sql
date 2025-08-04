CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_condition_mapping_proc`(on_date DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_normalized_trait_mappings 
      AS 
      SELECT DISTINCT
        * 
        EXCEPT (release_date)
        REPLACE(
          LOWER(mapping_type) as mapping_type, 
          LOWER(mapping_ref) as mapping_ref, 
          LOWER(mapping_value) as mapping_value
        )
      FROM `%s.trait_mapping` 
    """, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_rcv_mapping_traits
      AS
        SELECT 
          rm.rcv_accession,
          scv_id,
          rm.trait_set_id,
          `clinvar_ingest.parseTraitSet`(FORMAT('{"TraitSet": %%s}', rm.trait_set_content)) AS ts
        FROM `%s.rcv_mapping` rm
        CROSS JOIN UNNEST(rm.scv_accessions) as scv_id
    """, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE %s.gks_scv_trait_sets
      AS
        SELECT 
          cats.id as scv_id,
          rmt.trait_set_id as trait_set_id,
          rmt.ts.type as trait_set_type,
          ARRAY_LENGTH(rmt.ts.trait) as rcv_trait_count,
          ARRAY_LENGTH(cats.clinical_assertion_trait_ids) as cats_trait_count,
          cats.type as cats_type,
          cats.clinical_assertion_trait_ids,
          rmt.ts.trait as rcv_traits,
          [
            STRUCT(
              'clinvar trait set type' as name, 
              rmt.ts.type as value_string,
              [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
            ),
            STRUCT(
              'clinvar trait set id' as name, 
              rmt.trait_set_id as value_string,
              [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
            )
          ] as extensions
        FROM _SESSION.temp_rcv_mapping_traits rmt
        JOIN `%s.clinical_assertion_trait_set` cats
        ON
          rmt.scv_id = cats.id
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_all_rcv_traits
      AS
        -- IMPORTANT! there is one and only one rcv trait that has 2 medgen ids, trait_id 17556 'not provided' and it has an old medgen id 'CN517202' in addition to the current one 'C3661900'
        -- this should be considered downstream. 
        select 
          sts.trait_set_id,
          t.id as trait_id,
          pref_name.element_value as trait_name,
          t.type as trait_type,
          t.trait_relationship.type as trait_relationship_type,
          medgen.id as medgen_id,
          ARRAY_AGG(DISTINCT alt_name.element_value IGNORE NULLS ORDER BY alt_name.element_value) as alternate_names,
          ARRAY_AGG(DISTINCT mondo.id IGNORE NULLS ORDER BY mondo.id) as mondo_ids,
          ARRAY_AGG(DISTINCT omim.id IGNORE NULLS ORDER BY omim.id) as omim_ids,
          ARRAY_AGG(DISTINCT hp.id IGNORE NULLS ORDER BY hp.id) as hp_ids,
          ARRAY_AGG(DISTINCT orphanet.id IGNORE NULLS ORDER BY orphanet.id) as orphanet_ids,
          ARRAY_AGG(DISTINCT mesh.id IGNORE NULLS ORDER BY mesh.id) as mesh_ids,
          ARRAY_AGG(DISTINCT sts.scv_id ORDER BY sts.scv_id) as scv_ids  -- <<< convenience array so that we do not need to join the 5M+ rows from the gks_scv_trait_sets table when dealing with small sets of scvs downstream
        from `%s.gks_scv_trait_sets` sts
        cross join unnest(sts.rcv_traits) as t
        left join unnest(t.name) as pref_name
        on
          pref_name.type = 'Preferred'
        left join unnest(t.name) as alt_name
        on
          alt_name.type = 'Alternate'
        left join unnest(t.xref) as medgen
        on
          medgen.db = 'MedGen'
        left join unnest(t.xref) as mondo
        on
          mondo.db = 'MONDO'
        left join unnest(t.xref) as omim
        on
          omim.db = 'OMIM'
        left join unnest(t.xref) as orphanet
        on
          orphanet.db = 'Orphanet'
        left join unnest(t.xref) as hp
        on
          hp.db = 'Human Phenotype Ontology'
        left join unnest(t.xref) as mesh
        on
          mesh.db = 'MeSH'  
        group by
          sts.trait_set_id,
          t.id,
          pref_name.element_value,
          t.type,
          t.trait_relationship.type,
          medgen.id
    """, rec.schema_name);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_normalized_traits
      AS
        -- build a list of unique normalized trait id records reducing any
        -- duplicate trait id records to use the one with more lookup values
        -- (alt name, omim ids, hp_ids, etc...) and where the trait_type is
        -- first alphabetically. This will be the master list to assign
        -- trait_ids to the ca trait records.
        WITH trait_recs AS (
          SELECT DISTINCT
            art.*
            EXCEPT (trait_set_id, scv_ids, trait_relationship_type)
          FROM _SESSION.temp_all_rcv_traits art
        ),
        dupe_trait_recs AS (
          SELECT
            trait_id
          FROM trait_recs
          GROUP BY
            trait_id
          HAVING count(*) = 1
        )
        SELECT
          oth.*
        FROM trait_recs src
        JOIN trait_recs oth
        ON
          oth.trait_id = src.trait_id
          and
          (
            ARRAY_LENGTH(oth.alternate_names) > ARRAY_LENGTH(src.alternate_names)
            OR
            ARRAY_LENGTH(oth.mondo_ids) > ARRAY_LENGTH(src.mondo_ids)
            OR
            ARRAY_LENGTH(oth.omim_ids) > ARRAY_LENGTH(src.omim_ids)
            OR
            ARRAY_LENGTH(oth.hp_ids) > ARRAY_LENGTH(src.hp_ids)
            OR
            ARRAY_LENGTH(oth.orphanet_ids) > ARRAY_LENGTH(src.orphanet_ids)
            OR
            ARRAY_LENGTH(oth.mesh_ids) > ARRAY_LENGTH(src.mesh_ids)
            or
            oth.trait_type < src.trait_type    -- 2 dupes with different trait_types (disease and finding) this will cause disease to be prioritized in results
          )
        UNION ALL
        SELECT DISTINCT
          tr.*
        FROM trait_recs tr
        JOIN dupe_trait_recs dtr
        ON
          dtr.trait_id = tr.trait_id
    """);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_scv_trait_name_xrefs
      AS
        WITH scv_trait_xrefs AS (
          SELECT
            id,
            type,
            medgen_id,
            name,
            trait_id,
            alternate_names,
            clinvar_ingest.parseXRefItems(xrefs) as xrefs
          FROM `%s.clinical_assertion_trait` cat
          WHERE
            ARRAY_LENGTH(SPLIT(id,'.')) = 2
          -- 3,616,101
        ),
        submitted_xrefs AS (
          -- db
          -- x GeneReviews
          -- x HP   -- Human Phenotype Ontology
          -- x HPO  -- Human Phenotype Ontology
          -- x MESH -- MeSH
          -- x MONDO -- MONDO
          -- x MeSH -- MeSH
          -- x MedGen -- MedGen
          -- x OMIM   -- OMIM
          -- x OMIM phenotypic series -- OMIM
          -- x Orphanet -- Orphanet
          -- x UMLS    -- MedGen
          SELECT
            stx.id,
            ARRAY_AGG(STRUCT(xref.id as code, xref.db as system)) as codings
          FROM scv_trait_xrefs stx
          CROSS JOIN UNNEST(stx.xrefs) as xref
          GROUP BY
            stx.id
        )
        SELECT
          stx.id as cat_id,
          stx.type as cat_type,
          stx.name as cat_name,
          stx.trait_id as cat_trait_id,
          stx.medgen_id as cat_medgen_id,
          omim.id as omim_id,
          `clinvar_ingest.normalizeHpId`(hp.id) as hp_id,
          mondo.id as mondo_id,
          medgen.id as medgen_id,
          orphanet.id as orphanet_id,
          mesh.id as mesh_id,
          sx.codings as submitted_xrefs
        FROM scv_trait_xrefs stx
        LEFT JOIN submitted_xrefs sx
        ON
          sx.id = stx.id
        left join unnest(xrefs) as omim
        on
          omim.db IN ('OMIM', 'OMIM phenotypic series')
        left join unnest(xrefs) as hp
        on
          hp.db IN ('HP', 'HPO')
        left join unnest(xrefs) as mondo
        on
          mondo.db = 'MONDO'
        left join unnest(xrefs) as medgen
        on
          medgen.db IN ('MedGen', 'UMLS')
        left join unnest(xrefs) as orphanet
        on
          orphanet.db = 'Orphanet'  
        left join unnest(xrefs) as mesh
        on
          mesh.db IN ('MeSH', 'MESH')
    """, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_all_scv_traits`
      AS
        WITH all_ca_traits_and_mappings AS (
          -- This query returns ALL ca traits (both those directly related to the scv as well as the scv's observatoins, if any)
          -- We are intentionally bringing back both the scv and scv_obs traits since it is presumed that each trait will have
          -- it's own trait mapping. And we can use the ca-trait id pattern to discern which records are scv traits vs scv-obs traits.
          SELECT
            REGEXP_EXTRACT(cat.id, r'SCV[0-9]+') as scv_id,
            ARRAY_AGG(distinct cat.id) as cat_ids,
            ARRAY_AGG(
              IF(
                ntm.clinical_assertion_id is not null,
                STRUCT(ntm),
                null
              ) IGNORE NULLS
            ) as trait_mappings
          FROM `%s.clinical_assertion_trait` cat 
          LEFT JOIN _SESSION.temp_normalized_trait_mappings ntm
          ON 
            ntm.clinical_assertion_id = REGEXP_EXTRACT(cat.id, r'SCV[0-9]+')
          GROUP BY 
            REGEXP_EXTRACT(cat.id, r'SCV[0-9]+')
        )
        SELECT
          actam.scv_id,
          cat_id,
          sts.trait_set_id,
          sts.cats_trait_count,
          sts.rcv_trait_count,
          ARRAY_LENGTH(actam.cat_ids) as total_cat_cnt,
          IFNULL(array_length(actam.trait_mappings),0) as total_tm_count,
          stnx.cat_medgen_id,
          stnx.cat_name,
          stnx.cat_trait_id,
          stnx.cat_type,
          stnx.hp_id,
          stnx.medgen_id,
          stnx.mesh_id,
          stnx.mondo_id,
          stnx.omim_id,
          stnx.orphanet_id,
          stnx.submitted_xrefs
        FROM all_ca_traits_and_mappings actam
        JOIN `%s.gks_scv_trait_sets` sts
        ON
          actam.scv_id = sts.scv_id
        CROSS JOIN UNNEST(actam.cat_ids) as cat_id
        LEFT JOIN _SESSION.temp_scv_trait_name_xrefs stnx
        ON
          stnx.cat_id = cat_id
        WHERE 
          -- only return direct scv related trait records
          ARRAY_LENGTH(SPLIT(cat_id, '.')) = 2

    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_all_mapped_scv_traits`
      AS
        WITH scv_trait_base_mappings AS (
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: preferred name '%%s'", LOWER(ast.cat_name)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'name'
            AND
            ntm.mapping_ref = 'preferred'
            AND
            ntm.mapping_value = lower(ast.cat_name)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: medgen id '%%s'", LOWER(ast.medgen_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref = 'medgen'
            AND
            ntm.mapping_value = lower(ast.medgen_id)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: omim id '%%s'", LOWER(ast.omim_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref like 'omim%%'
            AND
            ntm.mapping_value = lower(ast.omim_id)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: mondo id '%%s'", LOWER(ast.mondo_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref = 'mondo'
            AND
            ntm.mapping_value = lower(ast.mondo_id)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: hpo id '%%s'", LOWER(ast.hp_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref IN ('hp', 'hpo', 'human phenotype ontology')
            AND
            ntm.mapping_value = lower(ast.hp_id)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: mesh id '%%s'", LOWER(ast.mesh_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          from `%s.gks_all_scv_traits` ast
          join _SESSION.temp_normalized_trait_mappings ntm  
          on
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref = 'mesh'
            AND
            ntm.mapping_value = lower(ast.mesh_id)
          UNION ALL
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_type,
            ast.cat_name,
            ast.cat_medgen_id,
            FORMAT("scv trait: orphanet id '%%s'", LOWER(ast.orphanet_id)) AS tm_match,
            ntm.mapping_type,
            ntm.mapping_ref,
            ntm.mapping_value,
            ntm.medgen_id
          FROM `%s.gks_all_scv_traits` ast
          JOIN _SESSION.temp_normalized_trait_mappings ntm 
          ON
            ntm.clinical_assertion_id = ast.scv_id
            AND
            ntm.trait_type = ast.cat_type
            AND
            ntm.mapping_type = 'xref'
            AND
            ntm.mapping_ref = 'orphanet'
            AND
            ntm.mapping_value = lower(ast.orphanet_id)
        ),
        single_trait_mapping_remaining AS (
          SELECT
            ast.scv_id
          FROM `%s.gks_all_scv_traits` ast
          LEFT JOIN scv_trait_base_mappings stbm
          ON
            stbm.cat_id = ast.cat_id
          WHERE
            stbm.cat_id IS NULL
            AND
            ast.total_cat_cnt = ast.total_tm_count
          GROUP BY
            ast.scv_id
          HAVING COUNT(*) = 1
        )
        SELECT
          ast.scv_id,
          ast.cat_id,
          ast.trait_set_id,
          ast.cat_type,
          ast.cat_name,
          ast.cat_medgen_id,
          'scv trait: default to remaining trait mapping' AS tm_match,
          ntm.mapping_type,
          ntm.mapping_ref,
          ntm.mapping_value,
          ntm.medgen_id
        FROM single_trait_mapping_remaining stmr
        JOIN `%s.gks_all_scv_traits` ast
        ON
          ast.scv_id = stmr.scv_id
        LEFT JOIN scv_trait_base_mappings stbm
        ON
          stbm.cat_id = ast.cat_id
        LEFT JOIN _SESSION.temp_normalized_trait_mappings ntm 
        ON
          ntm.clinical_assertion_id = ast.scv_id
          AND 
          (
            ntm.mapping_type IS DISTINCT FROM stbm.mapping_type
            AND
            ntm.mapping_ref IS DISTINCT FROM stbm.mapping_ref
            AND
            ntm.mapping_value IS DISTINCT FROM stbm.mapping_value
          )
        WHERE
          stbm.cat_id IS NULL
        UNION ALL
        SELECT
          stbm.scv_id,
          stbm.cat_id,
          stbm.trait_set_id,
          stbm.cat_type,
          stbm.cat_name,
          stbm.cat_medgen_id,
          stbm.tm_match,
          stbm.mapping_type,
          stbm.mapping_ref,
          stbm.mapping_value,
          stbm.medgen_id
        FROM scv_trait_base_mappings stbm
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
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_rcv_trait_assignment_stage1
      AS
        -- Assign rcv traits to ca traits
        -- 1st match attempt: trait-mapping medgen_id to rcv medgen_id
        -- 2nd match attempt: trait-mapping mapping ref/type/values
        WITH rcv_trait_medgen_assignment AS (
          SELECT DISTINCT 
            amst.scv_id,
            amst.cat_id,
            amst.tm_match as cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'rcv-tm medgen id' AS assign_type
          from `%s.gks_all_mapped_scv_traits` amst
          JOIN _SESSION.temp_all_rcv_traits art
          on
            amst.trait_set_id = art.trait_set_id
            AND
            amst.medgen_id = art.medgen_id
        ),
        unassigned_scv_traits AS (
          SELECT
            amst.scv_id,
            amst.cat_id,
            amst.cat_name,
            amst.cat_medgen_id,
            amst.tm_match as cat_tm_match,
            amst.trait_set_id,
            amst.cat_type,
            amst.mapping_type,
            amst.mapping_ref,
            amst.mapping_value,
            amst.medgen_id
          from `%s.gks_all_mapped_scv_traits` amst
          left join rcv_trait_medgen_assignment rtma
          on
            rtma.cat_id = amst.cat_id
          where
            rtma.cat_id is null
        ),
        rcv_trait_reftype_assignment AS (
          --   process the various trait_mapping ref/type records with their rcv trait record 
          --   (DO NOT compare trait_type for rcv trait to trait mapping values)
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype preferred name' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'name'
            AND
            ust.mapping_ref = 'preferred'
          WHERE
            ust.mapping_value = lower(art.trait_name)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype alternate name' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'name'
            AND
            ust.mapping_ref = 'alternate'
          CROSS JOIN UNNEST(art.alternate_names) as alt_name
          WHERE
            ust.mapping_value = lower(alt_name)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref medgen' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref = 'medgen'
          WHERE
            ust.mapping_value = lower(art.medgen_id)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref omim' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref like 'omim%%'
          CROSS JOIN UNNEST(art.omim_ids) as omim_id
          WHERE
            ust.mapping_value = LOWER(omim_id)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref mondo' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref = 'mondo'
          CROSS JOIN UNNEST(art.mondo_ids) as mondo_id
          WHERE
            ust.mapping_value = LOWER(mondo_id)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref hp' AS assign_type
          from unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          on
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref IN ('hp', 'hpo', 'human phenotype ontology')
          CROSS JOIN UNNEST(art.hp_ids) as hp_id
          WHERE
            ust.mapping_value = LOWER(hp_id)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref mesh' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref = 'mesh'
          CROSS JOIN UNNEST(art.mesh_ids) as mesh_id
          WHERE
            ust.mapping_value = LOWER(mesh_id)
          UNION ALL
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'tm reftype xref orphanet' AS assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON
            ust.trait_set_id = art.trait_set_id
            AND
            ust.mapping_type = 'xref'
            AND
            ust.mapping_ref = 'orphanet'
          CROSS JOIN UNNEST(art.orphanet_ids) as orphanet_id
          WHERE
            ust.mapping_value = LOWER(orphanet_id)
        )
        select 
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM rcv_trait_medgen_assignment rtma
        UNION ALL
        SELECT     
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM rcv_trait_reftype_assignment rtra
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_rcv_trait_assignment_stage2
      AS
        WITH unassigned_scv_traits AS (
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.cat_name,
            ast.cat_medgen_id,
            amst.tm_match as cat_tm_match,
            ast.trait_set_id,
            ast.hp_id,
            ast.medgen_id,
            ast.mesh_id,
            ast.mondo_id,
            ast.omim_id,
            ast.orphanet_id,
            ast.cats_trait_count,
            ast.rcv_trait_count,
            ast.total_cat_cnt,
            ast.total_tm_count
          FROM `%s.gks_all_scv_traits` ast
          LEFT JOIN `%s.gks_all_mapped_scv_traits` amst
          ON
            amst.cat_id = ast.cat_id
          LEFT JOIN _SESSION.temp_rcv_trait_assignment_stage1 rtas1
          ON
            rtas1.cat_id = ast.cat_id
          WHERE
            rtas1.cat_id is null
        ),
        singleton_unassigned_scv_traits AS (
          -- figure out which remaining scv traits have only one trait left to map, 
          -- and figure out which trait ids are already mapped
          SELECT
            ust.scv_id,
            ust.trait_set_id,
            ARRAY_TO_STRING(ARRAY_AGG(DISTINCT ust.cat_id),',') as cat_id,
            ARRAY_TO_STRING(ARRAY_AGG(DISTINCT ust.cat_tm_match),',') as cat_tm_match,
            ARRAY_AGG(IF(rtas1.cat_id is null, null, STRUCT(rtas1.cat_id, rtas1.trait_id, rtas1.trait_name)) IGNORE NULLS) as assigned,
            ARRAY_TO_STRING(ARRAY_AGG(DISTINCT IF(rtas1.trait_id is null, art.trait_id, null) ignore nulls),',') as unassigned_trait_id
          FROM unassigned_scv_traits ust
          LEFT JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          LEFT JOIN _SESSION.temp_rcv_trait_assignment_stage1 rtas1
          ON
            rtas1.scv_id = ust.scv_id
            AND
            rtas1.trait_id = art.trait_id
          WHERE
            ust.cats_trait_count = ust.rcv_trait_count
          GROUP BY 
            ust.scv_id,
            ust.trait_set_id
          HAVING (
            COUNT(distinct ust.cat_id) = 1
            AND
            COUNT(DISTINCT IF(rtas1.trait_id is null, art.trait_id, null)) = 1
          )
        ),
        rcv_trait_singleton_assignment AS (
          SELECT
            s.scv_id,
            s.cat_id,
            s.cat_tm_match,
            art.trait_set_id,
            art.trait_id,
            art.trait_name,
            art.trait_type,
            art.trait_relationship_type,
            art.medgen_id as trait_medgen_id,
            'single remaining trait' as assign_type
          FROM singleton_unassigned_scv_traits AS s
          -- join once to pull in all possible trait_set_traits for this trait_set_id
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = s.trait_set_id
            AND
            art.trait_id = s.unassigned_trait_id

          WHERE
            -- HACK! exclude the duplicate 'not provided' trait in the '9460' trait set.
            NOT (art.trait_id = '17556' and art.medgen_id = 'CN517202')
        )
        SELECT  
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM _SESSION.temp_rcv_trait_assignment_stage1 rtas1
        UNION ALL
        SELECT 
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM rcv_trait_singleton_assignment rtsa
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_rcv_trait_assignment_stage3
      AS
        WITH unassigned_scv_traits AS (
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.cat_name,
            ast.cat_medgen_id,
            amst.tm_match as cat_tm_match,
            ast.trait_set_id,
            ast.hp_id,
            ast.medgen_id,
            ast.mesh_id,
            ast.mondo_id,
            ast.omim_id,
            ast.orphanet_id,
            ast.cats_trait_count,
            ast.rcv_trait_count,
            ast.total_cat_cnt,
            ast.total_tm_count
          FROM `%s.gks_all_scv_traits` ast
          LEFT JOIN `%s.gks_all_mapped_scv_traits` amst
          ON
            amst.cat_id = ast.cat_id
          LEFT JOIN _SESSION.temp_rcv_trait_assignment_stage2 rtas2
          ON
            rtas2.cat_id = ast.cat_id
          WHERE
            rtas2.cat_id is null
        ),
        rcv_trait_direct_assignment AS (
          SELECT DISTINCT 
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait medgen_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          WHERE
            ust.medgen_id = art.medgen_id
          UNION ALL
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait omim_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          CROSS JOIN UNNEST(nt.omim_ids) as omim_id
          WHERE
            ust.omim_id = omim_id
          UNION ALL
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait hp_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          CROSS JOIN UNNEST(nt.hp_ids) as hp_id
          WHERE
            ust.hp_id = hp_id
          UNION ALL
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait mondo_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          CROSS JOIN UNNEST(nt.mondo_ids) as mondo_id
          WHERE
            ust.mondo_id = mondo_id
          UNION ALL
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait orphanet_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          CROSS JOIN UNNEST(nt.orphanet_ids) as orphanet_id
          WHERE
            ust.orphanet_id = orphanet_id
          UNION ALL
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            art.trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv trait mesh_id' as assign_type
          FROM unassigned_scv_traits ust
          JOIN _SESSION.temp_all_rcv_traits art
          ON 
            art.trait_set_id = ust.trait_set_id
          JOIN _SESSION.temp_normalized_traits nt
          ON
            nt.trait_id = art.trait_id
          CROSS JOIN UNNEST(nt.mesh_ids) as mesh_id
          WHERE
            ust.mesh_id = mesh_id
        )
        select  
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        from _SESSION.temp_rcv_trait_assignment_stage2 rtas2
        UNION ALL
        select 
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        from rcv_trait_direct_assignment rtda
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE TEMP TABLE _SESSION.temp_rcv_trait_assignment_stage4
      AS
        WITH unassigned_scv_traits AS (
          SELECT
            ast.scv_id,
            ast.cat_id,
            ast.trait_set_id,
            ast.cat_name,
            amst.tm_match as cat_tm_match,
            ast.hp_id,
            ast.medgen_id,
            ast.mesh_id,
            ast.mondo_id,
            ast.omim_id,
            ast.orphanet_id,
            ast.cats_trait_count,
            ast.rcv_trait_count,
            ast.total_cat_cnt,
            ast.total_tm_count
          FROM `%s.gks_all_scv_traits` ast
          LEFT JOIN `%s.gks_all_mapped_scv_traits` amst
          ON
            amst.cat_id = ast.cat_id
          LEFT JOIN _SESSION.temp_rcv_trait_assignment_stage3 rtas3
          ON
            rtas3.cat_id = ast.cat_id
          WHERE
            rtas3.cat_id is null
        ),
        rcv_rogue_assignment_1 AS (
          -- trait assignments that are not part of the mapped trait_set - yes this happens!
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait omim_id' as assign_type
          FROM _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.omim_ids) as omim_id
          JOIN unassigned_scv_traits ust
          ON
            ust.omim_id = omim_id
        ),
        rcv_rogue_assignment_2 AS (
          select DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait hp_id' as assign_type
          from _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.hp_ids) as hp_id
          JOIN unassigned_scv_traits ust
          ON
            ust.hp_id = hp_id
          LEFT JOIN rcv_rogue_assignment_1 rra1
          ON
            rra1.cat_id = ust.cat_id
          WHERE
            rra1.cat_id is null
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_1 rra1
        ),
        rcv_rogue_assignment_3 AS (
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait orphanet_id' as assign_type
          FROM _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.orphanet_ids) as orphanet_id
          JOIN unassigned_scv_traits ust
          ON
            ust.orphanet_id = orphanet_id
          LEFT JOIN rcv_rogue_assignment_2 rra2
          ON
            rra2.cat_id = ust.cat_id
          WHERE
            rra2.cat_id is null
          UNION ALL
          select
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_2 rra2
        ),
        rcv_rogue_assignment_4 AS (
          select DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait mondo_id' as assign_type
          from _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.mondo_ids) as mondo_id
          JOIN unassigned_scv_traits ust
          ON
            ust.mondo_id = mondo_id
          LEFT JOIN rcv_rogue_assignment_3 rra3
          ON
            rra3.cat_id = ust.cat_id
          WHERE
            rra3.cat_id is null
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_3 rra3
        ),
        rcv_rogue_assignment_5 AS (
          select DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait mesh_id' as assign_type
          from _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.mesh_ids) as mesh_id
          JOIN unassigned_scv_traits ust
          ON
            ust.mesh_id = mesh_id  
          LEFT JOIN rcv_rogue_assignment_4 rra4
          ON
            rra4.cat_id = ust.cat_id
          WHERE
            rra4.cat_id is null
          -- 0
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_4 rra4
        ),
        rcv_rogue_assignment_6 AS (
          select DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait name' as assign_type
          FROM _SESSION.temp_normalized_traits nt
          JOIN unassigned_scv_traits ust
          ON
            LOWER(nt.trait_name) = LOWER(ust.cat_name)
          LEFT JOIN rcv_rogue_assignment_5 rra5
          ON
            rra5.cat_id = ust.cat_id
          WHERE
            rra5.cat_id is null
            AND
            -- hack to remove all but one 'not provided' trait id from normalized trait matching for this query
            NOT (nt.trait_name = 'not provided' and nt.trait_id in ('54780', '76440','76481','78165','78166','78167'))
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_5 rra5
        ),
        rcv_rogue_assignment_7 AS (
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue alternate trait name' as assign_type
          FROM _SESSION.temp_normalized_traits nt
          CROSS JOIN UNNEST(nt.alternate_names) alt_name
          JOIN unassigned_scv_traits ust
          ON
            LOWER(alt_name) = LOWER(ust.cat_name)
          LEFT JOIN rcv_rogue_assignment_6 rra6
          ON
            rra6.cat_id = ust.cat_id
          WHERE
            rra6.cat_id is null
            AND
            -- hack to remove all but one 'not provided' trait id from normalized trait matching for this query
            NOT (alt_name = 'not provided' and nt.trait_id in ('54780', '76440','76481','78165','78166','78167'))
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_6 rra6
        ),
        rcv_rogue_assignment_final AS (
          SELECT DISTINCT
            ust.scv_id,
            ust.cat_id,
            ust.cat_tm_match,
            ust.trait_set_id,
            nt.trait_id,
            nt.trait_name,
            nt.trait_type,
            CAST(null as STRING) as trait_relationship_type,
            nt.medgen_id as trait_medgen_id,
            'rcv-scv rogue trait name' as assign_type
          FROM _SESSION.temp_normalized_traits nt
          JOIN unassigned_scv_traits ust
          ON
            nt.medgen_id = ust.medgen_id
            AND
            ust.cat_name is null
          LEFT JOIN rcv_rogue_assignment_7 rra7
          ON
            rra7.cat_id = ust.cat_id
          WHERE
            rra7.cat_id is null
          UNION ALL
          SELECT
            scv_id,
            cat_id,
            cat_tm_match,
            trait_set_id,
            trait_id,
            trait_name,
            trait_type,
            trait_relationship_type,
            trait_medgen_id,
            assign_type
          FROM rcv_rogue_assignment_7 rra7
        )
        SELECT  
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM _SESSION.temp_rcv_trait_assignment_stage3 rtas3
        UNION ALL
        SELECT 
          scv_id,
          cat_id,
          cat_tm_match,
          trait_set_id,
          trait_id,
          trait_name,
          trait_type,
          trait_relationship_type,
          trait_medgen_id,
          assign_type
        FROM rcv_rogue_assignment_final rraf
    """, 
    rec.schema_name, 
    rec.schema_name
    );

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_scv_condition_mapping`
      AS
        SELECT
          rtas4.scv_id,
          rtas4.cat_id,
          rtas4.trait_set_id,
          ast.cat_name,
          ast.cat_medgen_id,
          ast.cat_type,
          rtas4.cat_tm_match,
          rtas4.trait_id,
          rtas4.trait_name,
          rtas4.trait_relationship_type,
          rtas4.trait_medgen_id,
          rtas4.assign_type,
          amst.mapping_type,
          amst.mapping_ref,
          amst.mapping_value,
          amst.medgen_id,
          ast.submitted_xrefs
        FROM _SESSION.temp_rcv_trait_assignment_stage4 rtas4
        JOIN `%s.gks_all_scv_traits` ast
        ON
          rtas4.cat_id = ast.cat_id
        LEFT JOIN `%s.gks_all_mapped_scv_traits` amst
        ON
          amst.cat_id = ast.cat_id
        UNION ALL      
        SELECT
          ast.scv_id,
          ast.cat_id,
          ast.trait_set_id,
          ast.cat_name,
          ast.cat_medgen_id,
          ast.cat_type,
          amst.tm_match as cat_tm_match,
          CAST(null as STRING) as trait_id,
          CAST(null as STRING) as trait_name,
          CAST(null as STRING) as trait_relationship_type,
          CAST(null as STRING)  as trait_medgen_id,
          'unassignable scv trait' as assign_type,
          CAST(null as string) as mapping_type,
          CAST(null as string) as mapping_ref,
          CAST(null as string) as mapping_value,
          CAST(null as string) as medgen_id,
          [] as submitted_xrefs
        FROM `%s.gks_all_scv_traits` ast
        LEFT JOIN `%s.gks_all_mapped_scv_traits` amst
        ON
          amst.cat_id = ast.cat_id
        LEFT JOIN _SESSION.temp_rcv_trait_assignment_stage4 rtas4
        ON
          rtas4.cat_id = ast.cat_id
        WHERE
          rtas4.cat_id is null

    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

    DROP TABLE _SESSION.temp_normalized_trait_mappings;
    DROP TABLE _SESSION.temp_rcv_mapping_traits;
    DROP TABLE _SESSION.temp_all_rcv_traits;
    DROP TABLE _SESSION.temp_normalized_traits;
    DROP TABLE _SESSION.temp_scv_trait_name_xrefs;
    DROP TABLE _SESSION.temp_rcv_trait_assignment_stage1;
    DROP TABLE _SESSION.temp_rcv_trait_assignment_stage2;
    DROP TABLE _SESSION.temp_rcv_trait_assignment_stage3;
    DROP TABLE _SESSION.temp_rcv_trait_assignment_stage4;

  END FOR;

END;