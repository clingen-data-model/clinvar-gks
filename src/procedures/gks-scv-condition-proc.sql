
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_condition_proc`(on_date DATE, debug BOOL)
BEGIN
  DECLARE query_gks_traits STRING;
  DECLARE temp_rcv_mapping_traits_query STRING;
  DECLARE temp_gks_scv_trait_sets_query STRING;
  DECLARE temp_all_rcv_traits_query STRING;
  DECLARE query_gks_trait_sets STRING;
  DECLARE temp_scv_trait_name_xrefs_query STRING;
  DECLARE temp_scv_trait_mappings_query STRING;  
  DECLARE temp_scv_trait_assignment_stage1_query STRING;
  DECLARE temp_scv_trait_assignment_stage2_query STRING;
  DECLARE query_condition_sets STRING;
  DECLARE temp_create STRING;
  DECLARE temp_prefix STRING;

  IF debug THEN
    SET temp_create = 'CREATE OR REPLACE TABLE';
  ELSE
    SET temp_create = 'CREATE TEMP TABLE';
  END IF;

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -- Clean up any persistent temp tables from a prior debug run
    IF NOT debug THEN
      CALL `clinvar_ingest.cleanup_temp_tables`(rec.schema_name, [
        'temp_rcv_mapping_traits', 'temp_gks_scv_trait_sets',
        'temp_all_rcv_traits', 'temp_scv_trait_name_xrefs',
        'temp_scv_trait_mappings', 'temp_scv_trait_assignment_stage1',
        'temp_scv_trait_assignment_stage2'
      ]);
    END IF;

    -- -----------------------------------------------------------------------
    -- STEP 1: Create gks_traits (canonical trait representations)
    -- All traits with clinvar.trait:{id} identifiers, with primaryCoding,
    -- mappings (deduplicated by code+system), and aliases extension.
    -- -----------------------------------------------------------------------
    SET query_gks_traits = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_traits` AS
      WITH traits AS (
        select distinct
          t.id,
          t.type,
          t.name,
          t.alternate_names as synonyms,
          clinvar_ingest.parseXRefItems(t.xrefs) as xrefs
        FROM `{S}.trait` t
      ),
      distinct_trait_xrefs AS (
        SELECT DISTINCT
          t.id as trait_id,
          t.name as trait_name,
          xref.id,
          xref.db,
          xref.type
        FROM traits t
        CROSS JOIN UNNEST(t.xrefs) as xref
      ),
      trait_xrefs AS (
        SELECT
          dtxr.trait_id as id,
          STRUCT(
            IF(dtxr.db='MedGen', dtxr.trait_name, null) as name,
            IF(iri.id_extract_pattern IS NOT NULL, REGEXP_EXTRACT(dtxr.id, iri.id_extract_pattern), dtxr.id) as code,
            iri.system as system,
            ARRAY_AGG(
              FORMAT(
                iri.template,
                CASE
                  WHEN iri.id_replace_pattern IS NOT NULL
                    THEN REGEXP_REPLACE(dtxr.id, iri.id_replace_pattern, iri.id_replacement)
                  WHEN iri.id_extract_pattern IS NOT NULL
                    THEN REGEXP_EXTRACT(dtxr.id, iri.id_extract_pattern)
                  ELSE dtxr.id
                END
              )
            ) as iris
          ) as mapping
        FROM distinct_trait_xrefs dtxr
        LEFT JOIN `clinvar_ingest.gks_xref_iri_templates` iri
          ON iri.category = 'Condition'
          AND iri.db = dtxr.db
          AND iri.type IS NOT DISTINCT FROM dtxr.type
        GROUP BY dtxr.trait_id, dtxr.trait_name, dtxr.id, dtxr.db, iri.id_extract_pattern, iri.system
      )
      SELECT
        FORMAT('clinvar.trait:%s', t.id) AS id,
        t.id as trait_id,
        t.type as conceptType,
        t.name,
        ARRAY_AGG(
          IF(
            tx.mapping.system = 'medgen',
            tx.mapping,
            null
          )
          IGNORE NULLS
        )[SAFE_OFFSET(0)] as primaryCoding,
        ARRAY_AGG(
          IF(
            tx.mapping.system <> 'medgen',
            STRUCT(tx.mapping as coding, 'relatedMatch' as relation),
            null
          )
          IGNORE NULLS
        ) as mappings,
        -- Use ANY_VALUE because we cannot GROUP BY the synonyms array
        ANY_VALUE(
          IF(
            ARRAY_LENGTH(t.synonyms) > 0, 
            [STRUCT(
              'aliases' AS name,
              t.synonyms AS value_array_string
            )],
            NULL 
          )
        ) AS extensions
      FROM traits t
      LEFT JOIN trait_xrefs tx
      ON
        tx.id = t.id
      GROUP BY
        t.id,
        t.type,
        t.name
    """, '{S}', rec.schema_name);
    EXECUTE IMMEDIATE query_gks_traits;

    -- -----------------------------------------------------------------------
    -- STEP 2: Create temp_rcv_mapping_traits
    -- -----------------------------------------------------------------------
    SET temp_rcv_mapping_traits_query = REPLACE("""
      {CT} {P}.temp_rcv_mapping_traits
      AS
        SELECT
          rm.rcv_accession,
          scv_id,
          rm.trait_set_id,
          `clinvar_ingest.parseTraitSet`(FORMAT('{"TraitSet": %s}', rm.trait_set_content)) AS ts
        FROM `{S}.rcv_mapping` rm
        CROSS JOIN UNNEST(rm.scv_accessions) as scv_id
    """, '{S}', rec.schema_name);
    SET temp_rcv_mapping_traits_query = REPLACE(temp_rcv_mapping_traits_query, '{CT}', temp_create);
    SET temp_rcv_mapping_traits_query = REPLACE(temp_rcv_mapping_traits_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_rcv_mapping_traits_query;

    -- -----------------------------------------------------------------------
    -- STEP 3: Create temp_gks_scv_trait_sets
    -- -----------------------------------------------------------------------
    SET temp_gks_scv_trait_sets_query = REPLACE("""
      {CT} {P}.temp_gks_scv_trait_sets
      AS
        SELECT
          cats.id as scv_id,
          rmt.trait_set_id as rcv_trait_set_id,
          rmt.ts.type as rcv_trait_set_type,
          ARRAY_LENGTH(rmt.ts.trait) as rcv_trait_count,
          ARRAY_LENGTH(cats.clinical_assertion_trait_ids) as cats_trait_count,
          cats.type as cats_type,
          cats.clinical_assertion_trait_ids,
          rmt.ts.trait as rcv_traits,
          JSON_VALUE(content, '$."@multipleConditionExplanation"') AS multiple_condition_explanation
        FROM {P}.temp_rcv_mapping_traits rmt
        JOIN `{S}.clinical_assertion_trait_set` cats
        ON
          rmt.scv_id = cats.id
    """, '{S}', rec.schema_name);
    SET temp_gks_scv_trait_sets_query = REPLACE(temp_gks_scv_trait_sets_query, '{CT}', temp_create);
    SET temp_gks_scv_trait_sets_query = REPLACE(temp_gks_scv_trait_sets_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_gks_scv_trait_sets_query;

    -- -----------------------------------------------------------------------
    -- STEP 4: Create temp_all_rcv_traits
    -- -----------------------------------------------------------------------
    SET temp_all_rcv_traits_query = REPLACE("""
      {CT} {P}.temp_all_rcv_traits
      AS
         WITH raw_rcv_traits AS (
          select
            sts.rcv_trait_set_id,
            t.id as rcv_trait_id,
            pref_name.element_value as rcv_trait_name,
            t.type as rcv_trait_type,
            t.trait_relationship.type as rcv_trait_relationship_type,
            -- IF(medgen.id = 'CN517202', 'C3661900', medgen.id) as medgen_id,
            medgen.id as medgen_id,
            ARRAY_AGG(DISTINCT alt_name.element_value IGNORE NULLS ORDER BY alt_name.element_value) as alternate_names,
            ARRAY_AGG(DISTINCT mondo.id IGNORE NULLS ORDER BY mondo.id) as mondo_ids,
            ARRAY_AGG(DISTINCT omim.id IGNORE NULLS ORDER BY omim.id) as omim_ids,
            ARRAY_AGG(DISTINCT omimps.id IGNORE NULLS ORDER BY omimps.id) as omimps_ids,
            ARRAY_AGG(DISTINCT hp.id IGNORE NULLS ORDER BY hp.id) as hp_ids,
            ARRAY_AGG(DISTINCT orphanet.id IGNORE NULLS ORDER BY orphanet.id) as orphanet_ids,
            ARRAY_AGG(DISTINCT mesh.id IGNORE NULLS ORDER BY mesh.id) as mesh_ids,
            ARRAY_AGG(DISTINCT sts.scv_id ORDER BY sts.scv_id) as scv_ids
          from {P}.temp_gks_scv_trait_sets sts
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
            omim.db = 'OMIM' AND omim.type = 'MIM'
          left join unnest(t.xref) as omimps
          on
            omimps.db = 'OMIM' AND omimps.type = 'Phenotypic series'
          left join unnest(t.xref) as orphanet
          on
            orphanet.db = 'Orphanet'
          left join unnest(t.xref) as hp
          on
            hp.db = 'Human Phenotype Ontology' AND hp.type = 'primary'
          left join unnest(t.xref) as mesh
          on
            mesh.db = 'MeSH'
          group by
            sts.rcv_trait_set_id,
            t.id,
            pref_name.element_value,
            t.type,
            t.trait_relationship.type,
            medgen.id
        ),
        -- Deduplicate rows with the same (rcv_trait_set_id, rcv_trait_id).
        -- Scalar attributes (name, type, relationship_type, medgen_id) come
        -- from the row with the most scv_ids (the "newer" row).
        -- Array columns are concatenated first, then deduplicated.
        merged AS (
          SELECT
            rcv_trait_set_id,
            rcv_trait_id,
            ARRAY_AGG(rcv_trait_name ORDER BY ARRAY_LENGTH(scv_ids) DESC LIMIT 1)[OFFSET(0)] AS rcv_trait_name,
            ARRAY_AGG(rcv_trait_type ORDER BY ARRAY_LENGTH(scv_ids) DESC LIMIT 1)[OFFSET(0)] AS rcv_trait_type,
            ARRAY_AGG(rcv_trait_relationship_type ORDER BY ARRAY_LENGTH(scv_ids) DESC LIMIT 1)[OFFSET(0)] AS rcv_trait_relationship_type,
            ARRAY_AGG(medgen_id IGNORE NULLS ORDER BY ARRAY_LENGTH(scv_ids) DESC LIMIT 1)[SAFE_OFFSET(0)] AS medgen_id,
            ARRAY_CONCAT_AGG(alternate_names) AS alternate_names,
            ARRAY_CONCAT_AGG(mondo_ids) AS mondo_ids,
            ARRAY_CONCAT_AGG(omim_ids) AS omim_ids,
            ARRAY_CONCAT_AGG(omimps_ids) AS omimps_ids,
            ARRAY_CONCAT_AGG(hp_ids) AS hp_ids,
            ARRAY_CONCAT_AGG(orphanet_ids) AS orphanet_ids,
            ARRAY_CONCAT_AGG(mesh_ids) AS mesh_ids,
            ARRAY_CONCAT_AGG(scv_ids) AS scv_ids
          FROM raw_rcv_traits
          GROUP BY rcv_trait_set_id, rcv_trait_id
        )
        SELECT
          rcv_trait_set_id,
          rcv_trait_id,
          rcv_trait_name,
          rcv_trait_type,
          rcv_trait_relationship_type,
          medgen_id,
          ARRAY(SELECT DISTINCT v FROM UNNEST(alternate_names) v WHERE v IS NOT NULL ORDER BY v) AS alternate_names,
          ARRAY(SELECT DISTINCT v FROM UNNEST(mondo_ids) v WHERE v IS NOT NULL ORDER BY v) AS mondo_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(omim_ids) v WHERE v IS NOT NULL ORDER BY v) AS omim_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(omimps_ids) v WHERE v IS NOT NULL ORDER BY v) AS omimps_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(hp_ids) v WHERE v IS NOT NULL ORDER BY v) AS hp_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(orphanet_ids) v WHERE v IS NOT NULL ORDER BY v) AS orphanet_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(mesh_ids) v WHERE v IS NOT NULL ORDER BY v) AS mesh_ids,
          ARRAY(SELECT DISTINCT v FROM UNNEST(scv_ids) v ORDER BY v) AS scv_ids
        FROM merged
    """, '{S}', rec.schema_name);
    SET temp_all_rcv_traits_query = REPLACE(temp_all_rcv_traits_query, '{CT}', temp_create);
    SET temp_all_rcv_traits_query = REPLACE(temp_all_rcv_traits_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_all_rcv_traits_query;

    -- -----------------------------------------------------------------------
    -- STEP 5: Create gks_trait_sets (persistent baseline traitset representations)
    -- Unique trait sets with clinvar.traitset:{id} identifiers, referencing
    -- member traits via #/traits/clinvar.trait:{trait_id}.
    -- -----------------------------------------------------------------------
    SET query_gks_trait_sets = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_trait_sets` AS
      WITH trait_set_traits AS (
        SELECT DISTINCT
          art.rcv_trait_set_id,
          art.rcv_trait_id
        FROM {P}.temp_all_rcv_traits art
      ),
      trait_set_info AS (
        SELECT DISTINCT
          gsts.rcv_trait_set_id,
          gsts.rcv_trait_set_type
        FROM {P}.temp_gks_scv_trait_sets gsts
      )
      SELECT
        FORMAT('clinvar.traitset:%s', tsi.rcv_trait_set_id) AS id,
        tsi.rcv_trait_set_type AS conceptSetType,
        ARRAY_AGG(
          FORMAT('#/condition/clinvar.trait:%s', tst.rcv_trait_id)
          ORDER BY tst.rcv_trait_id
        ) AS condition_refs,
        IF(
          ANY_VALUE(art.rcv_trait_relationship_type) IN ('Finding member','co-occurring condition'),
          'AND',
          'OR'
        ) AS membershipOperator
      FROM trait_set_info tsi
      JOIN trait_set_traits tst 
        ON tst.rcv_trait_set_id = tsi.rcv_trait_set_id
      LEFT JOIN {P}.temp_all_rcv_traits art 
        ON art.rcv_trait_set_id = tsi.rcv_trait_set_id AND art.rcv_trait_id = tst.rcv_trait_id
      GROUP BY tsi.rcv_trait_set_id, tsi.rcv_trait_set_type
    """, '{S}', rec.schema_name);
    SET query_gks_trait_sets = REPLACE(query_gks_trait_sets, '{P}', IF(debug, rec.schema_name, '_SESSION'));
    EXECUTE IMMEDIATE query_gks_trait_sets;
  
    -- -----------------------------------------------------------------------
    -- STEP 6: Create temp_scv_trait_name_xrefs
    -- -----------------------------------------------------------------------
    SET temp_scv_trait_name_xrefs_query = REPLACE("""
      {CT} {P}.temp_scv_trait_name_xrefs
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
          FROM `{S}.clinical_assertion_trait` cat
          WHERE
            ARRAY_LENGTH(SPLIT(id,'.')) = 2
            -- 7,289,602
            --SCV000380563 (von Wildebrand disorder mismaps to von Wildebrand disease in clinvar UI between SCV and RCV/VCV conditions.)
        ),
        submitted_xrefs AS (
          -- db
          -- x GeneReviews (ncbibook)
          -- x HP   -- Human Phenotype Ontology (hp)
          -- x HPO  -- Human Phenotype Ontology (hp)
          -- x MESH -- MeSH (mesh)
          -- x MONDO -- MONDO (mondo)
          -- x MeSH -- MeSH (mesh)
          -- x MedGen -- MedGen (medgen)
          -- x OMIM   -- OMIM (omim)
          -- x OMIM phenotypic series (omim.ps)
          -- x Orphanet -- Orphanet (orpha)
          -- x UMLS    -- MedGen (medgen)
          SELECT
            stx.id,

            ARRAY_AGG(
              CASE
              WHEN (xref.db = 'OMIM' and xref.id not like 'PS%') THEN
                STRUCT(REGEXP_EXTRACT(xref.id, r'\\d+') as code, 'omim' as system)
              WHEN (xref.db = 'OMIM phenotypic series' OR (xref.db = 'OMIM' AND xref.id like 'PS%')) THEN
                STRUCT(FORMAT('PS%s', REGEXP_EXTRACT(xref.id, r'\\d+')) as code, 'omim.ps' as system)
              WHEN (xref.db IN ('HP', 'HPO') AND REGEXP_CONTAINS(xref.id, r'^(HP:)?\\d+$')) THEN
                STRUCT(REGEXP_EXTRACT(xref.id, r'\\d+') as code, 'HP' as system)
              WHEN (xref.db = 'MONDO') THEN
                STRUCT(RIGHT(REGEXP_EXTRACT(xref.id, r'\\d+'),7) as code, 'mondo' as system)
              WHEN (xref.db IN ('MedGen', 'UMLS')) THEN
                STRUCT(UPPER(xref.id) as code, 'medgen' as system)
              WHEN (xref.db = 'Orphanet') THEN
                STRUCT(REGEXP_EXTRACT(xref.id, r'\\d+') as code, 'orpha' as system)
              WHEN (xref.db IN ('MeSH', 'MESH')) THEN
                STRUCT(UPPER(xref.id) as code, 'mesh' as system)
              WHEN (xref.db IN ('GeneReviews')) THEN
                STRUCT(UPPER(xref.id) as code, 'ncbibook' as system)
              ELSE
                STRUCT(CAST(NULL AS STRING) as code, CAST(NULL AS STRING) as system)
              END
            ) as norm_codings,

            ARRAY_AGG(
              STRUCT(xref.id as code, xref.db as system)
            ) as raw_codings

          FROM scv_trait_xrefs stx
          CROSS JOIN UNNEST(stx.xrefs) as xref
          GROUP BY
            stx.id
        )
        -- this statement is responsible for preserving the submitted xref id and db values as well as normalizing
        --  them so they best match the intended values and subsequently give the best opportunity to match with the gks_traits.xrefs.
        SELECT
          stx.id as cat_id,
          stx.type as cat_type,
          stx.name as cat_name,
          stx.trait_id as cat_trait_id,
          stx.medgen_id as cat_medgen_id,
          omim.code as omim_id,
          omimps.code as omimps_id,
          hp.code as hp_id,
          mondo.code as mondo_id,
          -- there are a couple odd situations whereby the submitted medgen_id does not end up in the clinvar trait_xrefs, so this will account for those
          IFNULL(medgen.code, stx.medgen_id) as medgen_id,
          orphanet.code as orphanet_id,
          mesh.code as mesh_id,
          ncbibook.code as ncbibook_id,
          sx.raw_codings as submitted_xrefs
        FROM scv_trait_xrefs stx
        LEFT JOIN submitted_xrefs sx
        ON
          sx.id = stx.id

        -- OMIM.  99999, PS999999
        left join unnest(sx.norm_codings) as omim
        on
          omim.system = 'omim'
        -- OMIMPS. PS999999
        left join unnest(sx.norm_codings) as omimps
        on
          omimps.system = 'omim.ps'

        -- HP  HP:99999, 99999, (1) C999999
        left join unnest(sx.norm_codings) as hp
        on
          hp.system = 'HP'

        -- MONDO MONDO:99999, 9999999 (should always be 7 in length
        -- remove leading zeroes if longer, add leading zeroes if shorter
        left join unnest(sx.norm_codings) as mondo
        on
          mondo.system = 'mondo'

        -- medgen c99999 (1 lowercase c), C99999 (conceptid), CN999999 (concept id), 999999 (medgen uid) - both work
        left join unnest(sx.norm_codings) as medgen
        on
          medgen.system = 'medgen'

        -- Orphanet ORPHA99999, 99999 (different length numeric components but doesn't matter)
        left join unnest(sx.norm_codings) as orphanet
        on
          orphanet.system = 'orpha'

        -- mesh D999999, C99.999.999.999.999. (sometimes several in a csv list), one name entry
        left join unnest(sx.norm_codings) as mesh
        on
          mesh.system = 'mesh'

        -- ncbibook NBK999999
        left join unnest(sx.norm_codings) as ncbibook
        on
          ncbibook.system = 'ncbibook'
    """, '{S}', rec.schema_name);
    SET temp_scv_trait_name_xrefs_query = REPLACE(temp_scv_trait_name_xrefs_query, '{CT}', temp_create);
    SET temp_scv_trait_name_xrefs_query = REPLACE(temp_scv_trait_name_xrefs_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_scv_trait_name_xrefs_query;

    -- -----------------------------------------------------------------------
    -- STEP 7: Create temp_scv_trait_mappings
    -- Replaces temp_all_scv_traits and temp_all_mapped_scv_traits.
    -- Uses COALESCE priority to select the best mapping key per SCV trait,
    -- then joins to trait_mapping to get the mapped medgen_id.
    -- Priority: cat_name > omim > hp > mondo > medgen > orphanet > mesh
    -- -----------------------------------------------------------------------    
    SET temp_scv_trait_mappings_query = REPLACE("""
      {CT} {P}.temp_scv_trait_mappings
      AS
        WITH scv_traits AS (
          SELECT DISTINCT
            stnx.cat_id,
            SPLIT(stnx.cat_id, '.')[OFFSET(0)] AS scv_id,
            stnx.cat_type,
            stnx.cat_name,
            stnx.cat_trait_id,
            stnx.cat_medgen_id,
            stnx.omim_id,
            stnx.omimps_id,
            stnx.hp_id,
            stnx.mondo_id,
            stnx.medgen_id,
            stnx.orphanet_id,
            stnx.mesh_id,
            stnx.ncbibook_id,
            stnx.submitted_xrefs,
            COALESCE(
              stnx.cat_name,
              stnx.omim_id,
              stnx.omimps_id,
              stnx.hp_id,
              stnx.mondo_id,
              stnx.medgen_id,
              stnx.orphanet_id,
              stnx.mesh_id,
              stnx.ncbibook_id
            ) AS mapping_value,
            CASE
              WHEN stnx.cat_name    IS NOT NULL THEN 'preferred'
              WHEN stnx.omim_id     IS NOT NULL THEN 'omim'
              WHEN stnx.omimps_id   IS NOT NULL THEN 'omim.ps'
              WHEN stnx.hp_id       IS NOT NULL THEN 'HP'
              WHEN stnx.mondo_id    IS NOT NULL THEN 'mondo'
              WHEN stnx.medgen_id   IS NOT NULL THEN 'medgen'
              WHEN stnx.orphanet_id IS NOT NULL THEN 'orpha'
              WHEN stnx.mesh_id     IS NOT NULL THEN 'mesh'
              WHEN stnx.ncbibook_id IS NOT NULL THEN 'ncbibook'
            END AS mapping_ref,
            IF(stnx.cat_name IS NOT NULL, 'Name', 'XRef') AS mapping_type
          FROM {P}.temp_scv_trait_name_xrefs stnx
        ),
        trait_mappings AS (
          SELECT DISTINCT
            clinical_assertion_id,
            mapping_type,
            CASE
              WHEN mapping_ref IN ('HP','HPO','Human Phenotype Ontology') THEN 'HP'
              WHEN mapping_ref = 'OMIM' AND mapping_value NOT LIKE 'PS%' THEN 'omim'
              WHEN mapping_ref LIKE 'OMIM%' AND mapping_value LIKE 'PS%' THEN 'omim.ps'
              WHEN mapping_ref = 'Orphanet' THEN 'orpha'
              ELSE lower(mapping_ref)
            END AS mapping_ref,
            IF(
              mapping_type = 'XRef',
              CASE
                WHEN (mapping_value LIKE 'HP:%' OR mapping_value LIKE 'ORPHA%') THEN REGEXP_EXTRACT(mapping_value, r'\\d+')
                WHEN (mapping_value LIKE 'MONDO:%') THEN RIGHT(REGEXP_EXTRACT(mapping_value, r'\\d+'),7)
                WHEN (LOWER(mapping_ref) = 'omim phenotypic series') THEN FORMAT('PS%s', REGEXP_EXTRACT(mapping_value, r'\\d+'))
                ELSE UPPER(mapping_value)
              END,
              mapping_value
            ) as mapping_value,
            medgen_id,
            medgen_name
            -- trait_type
          FROM `{S}.trait_mapping`
        ),
        alt_trait_mappings AS (
          SELECT DISTINCT
            clinical_assertion_id,
            mapping_value,
            medgen_id,
            medgen_name
          FROM `{S}.trait_mapping`
          WHERE mapping_ref = 'Alternate'
            AND mapping_type = 'Name'
        )
        SELECT
          st.scv_id,
          st.cat_id,
          gsts.rcv_trait_set_id,
          gsts.cats_trait_count,
          gsts.rcv_trait_count,
          gsts.multiple_condition_explanation,
          st.cat_type,
          COALESCE(st.cat_name, atm.mapping_value) AS cat_name,
          st.cat_trait_id,
          COALESCE(st.cat_medgen_id, atm.medgen_id) AS cat_medgen_id,
          st.omim_id,
          st.omimps_id,
          st.hp_id,
          st.mondo_id,
          st.medgen_id,
          st.orphanet_id,
          st.mesh_id,
          st.ncbibook_id,
          st.submitted_xrefs,
          st.mapping_type,
          st.mapping_ref,
          st.mapping_value,
          tm.medgen_id AS tm_medgen_id,
          tm.medgen_name AS tm_medgen_name
        FROM scv_traits st
        JOIN {P}.temp_gks_scv_trait_sets gsts
          ON gsts.scv_id = st.scv_id
        LEFT JOIN trait_mappings tm
          ON  st.scv_id = tm.clinical_assertion_id
          AND st.mapping_ref = tm.mapping_ref
          AND st.mapping_type = tm.mapping_type
          AND st.mapping_value = tm.mapping_value
        LEFT JOIN alt_trait_mappings atm
          ON  st.scv_id = atm.clinical_assertion_id
          AND st.cat_name IS NULL
    """, '{S}', rec.schema_name);
    SET temp_scv_trait_mappings_query = REPLACE(temp_scv_trait_mappings_query, '{CT}', temp_create);
    SET temp_scv_trait_mappings_query = REPLACE(temp_scv_trait_mappings_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_scv_trait_mappings_query;

    -- -----------------------------------------------------------------------
    -- STEP 8: Create temp_scv_trait_assignment_stage1
    -- Use temp_scv_trait_mappings to find rcv "normalized" traits
    -- associations to scv traits.
    -- -----------------------------------------------------------------------  
    SET temp_scv_trait_assignment_stage1_query = REPLACE("""
      {CT} {P}.temp_scv_trait_assignment_stage1
      AS
        WITH medgen_scv_traits AS (
          SELECT
            stm.scv_id,
            stm.cat_id,
            stm.cat_name,
            stm.cat_medgen_id,
            stm.cat_type,
            stm.submitted_xrefs,
            stm.rcv_trait_set_id,
            stm.tm_medgen_id,
            stm.tm_medgen_name,
            stm.mapping_type,
            stm.mapping_ref,
            stm.mapping_value,
            stm.cats_trait_count,
            stm.rcv_trait_count,
            stm.multiple_condition_explanation,
            COALESCE(stm.tm_medgen_id, stm.cat_medgen_id) AS lookup_medgen_id
          FROM {P}.temp_scv_trait_mappings stm
        ),
        scv_traits AS (
          SELECT
            mst.scv_id,
            mst.cat_id,
            mst.cat_name AS submitted_name,
            mst.cat_medgen_id AS submitted_medgen_id,
            mst.cat_type AS submitted_type,
            mst.submitted_xrefs,
            mst.rcv_trait_set_id,
            mst.tm_medgen_id,
            mst.tm_medgen_name,
            mst.lookup_medgen_id,
            mst.mapping_type,
            mst.mapping_ref,
            mst.mapping_value,
            mst.cats_trait_count,
            mst.rcv_trait_count,
            mst.multiple_condition_explanation,
            gt.trait_id AS mapped_trait_id,
            gt.name AS mapped_trait_name,
            gt.conceptType AS mapped_trait_type,
            gt.primaryCoding.code AS mapped_medgen_id,
            IF(gt.trait_id IS NOT NULL, 'trait-mapping-then-submitted-medgen-id', NULL) AS mapped_resolution_type
          FROM medgen_scv_traits mst
          LEFT JOIN `{S}.gks_traits` gt
            ON gt.primaryCoding.code = mst.lookup_medgen_id
        ),
        -- Pivot each SCV trait's match key into a row with priority
        -- Priority: medgen(1) > preferred name(2) > omim(3) > mondo(4) > HP(5) > omim.ps(6) > orpha(7) > mesh(8)
        st_lookup AS (
          SELECT cat_id, rcv_trait_set_id, 1 AS priority, lookup_medgen_id AS match_value, 'tm reftype xref medgen' AS resolution_type
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'medgen'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 2, IFNULL(mapped_trait_name, tm_medgen_name),'tm reftype preferred name'
          FROM scv_traits WHERE mapping_type = 'Name' AND mapping_ref = 'preferred' 
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 3, mapping_value, 'tm reftype xref omim'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'omim'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 4, 'MONDO:' || mapping_value, 'tm reftype xref mondo'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'mondo'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 5, 'HP:' || mapping_value, 'tm reftype xref HP'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'HP'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 6, mapping_value, 'tm reftype xref omim.ps'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'omim.ps'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 7, mapping_value, 'tm reftype xref orpha'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'orpha'
          UNION ALL
          SELECT cat_id, rcv_trait_set_id, 8, mapping_value, 'tm reftype xref mesh'
          FROM scv_traits WHERE mapping_type = 'XRef' AND mapping_ref = 'mesh'
        ),
        -- Flatten temp_all_rcv_traits into a lookup: one row per (trait_set_id, match_value)
        art_lookup AS (
          -- medgen (priority 1)
          SELECT rcv_trait_set_id, medgen_id AS match_value,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits
          WHERE medgen_id IS NOT NULL
          UNION ALL
          -- preferred name (priority 2) — normalized
          SELECT rcv_trait_set_id, rcv_trait_name, 
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits
          WHERE rcv_trait_name IS NOT NULL
          UNION ALL
          -- omim (priority 3)
          SELECT rcv_trait_set_id, omim_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(omim_ids) AS omim_id
          UNION ALL
          -- mondo (priority 4)
          SELECT rcv_trait_set_id, mondo_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(mondo_ids) AS mondo_id
          UNION ALL
          -- HP (priority 5)
          SELECT rcv_trait_set_id, hp_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(hp_ids) AS hp_id
          UNION ALL
          -- omim.ps (priority 6)
          SELECT rcv_trait_set_id, omimps_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(omimps_ids) AS omimps_id
          UNION ALL
          -- orpha (priority 7)
          SELECT rcv_trait_set_id, orphanet_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(orphanet_ids) AS orphanet_id
          UNION ALL
          -- mesh (priority 8)
          SELECT rcv_trait_set_id, mesh_id,
            rcv_trait_id, rcv_trait_name, rcv_trait_type, rcv_trait_relationship_type, medgen_id
          FROM {P}.temp_all_rcv_traits, UNNEST(mesh_ids) AS mesh_id
        ),
        -- Single join: match st_lookup to art_lookup on trait_set + match_value
        all_matches AS (
          SELECT
            sl.cat_id,
            sl.priority,
            sl.resolution_type,
            al.rcv_trait_set_id AS normalized_trait_set_id,
            al.rcv_trait_id AS normalized_trait_id,
            al.rcv_trait_name AS normalized_trait_name,
            al.rcv_trait_type AS normalized_trait_type,
            al.rcv_trait_relationship_type AS normalized_trait_relationship_type,
            al.medgen_id AS normalized_trait_medgen_id
          FROM st_lookup sl
          JOIN art_lookup al
            ON al.rcv_trait_set_id = sl.rcv_trait_set_id
            AND al.match_value = sl.match_value
        ),
        -- Pick best (lowest) priority per cat_id, with tiebreaker
        best_match AS (
          SELECT
            *,
            ROW_NUMBER() OVER (
              PARTITION BY cat_id
              ORDER BY priority, normalized_trait_id
            ) AS rn
          FROM all_matches
        )
        -- Final: join back to scv_traits for the full row, LEFT JOIN best_match for assigned
        SELECT
          st.*,
          bm.normalized_trait_set_id,
          bm.normalized_trait_id,
          bm.normalized_trait_name,
          bm.normalized_trait_type,
          bm.normalized_trait_relationship_type,
          bm.normalized_trait_medgen_id,
          bm.resolution_type AS normalized_resolution_type
        FROM scv_traits st
        LEFT JOIN best_match bm
          ON bm.cat_id = st.cat_id
          AND bm.rn = 1
    """, '{S}', rec.schema_name);
    SET temp_scv_trait_assignment_stage1_query = REPLACE(temp_scv_trait_assignment_stage1_query, '{CT}', temp_create);
    SET temp_scv_trait_assignment_stage1_query = REPLACE(temp_scv_trait_assignment_stage1_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_scv_trait_assignment_stage1_query;

    -- -----------------------------------------------------------------------
    -- STEP 9: Create temp_scv_trait_assignment_stage2
    -- Random trait assignment for remaining traits that have same number of
    -- unassigned scv traits as there are normalized traits for the same set.
    -- This will assign singletons as well as 2-to-2, 3-to-3, etc...
    -- -----------------------------------------------------------------------
    SET temp_scv_trait_assignment_stage2_query = REPLACE("""
      {CT} {P}.temp_scv_trait_assignment_stage2
      AS
        WITH unassigned AS (
          SELECT
            stas1.*
          FROM {P}.temp_scv_trait_assignment_stage1 stas1
          WHERE 
          stas1.normalized_trait_id IS NULL
            AND stas1.rcv_trait_count = stas1.cats_trait_count
        ),
        -- Traits already assigned to this scv_id in stage1
        already_assigned AS (
          SELECT DISTINCT
            stas1.scv_id,
            stas1.normalized_trait_id,
            stas1.mapped_trait_id
          FROM {P}.temp_scv_trait_assignment_stage1 stas1
          WHERE
            stas1.normalized_trait_id IS NOT NULL
        ),
        -- Unassigned traits per (scv_id, rcv_trait_set_id): all traits in the
        -- trait set minus those already assigned for this scv_id
        unassigned_traits AS (
          SELECT
            u.scv_id,
            u.rcv_trait_set_id,
            art.rcv_trait_id,
            ANY_VALUE(art.rcv_trait_name) AS rcv_trait_name,
            ANY_VALUE(art.rcv_trait_type) AS rcv_trait_type,
            ANY_VALUE(art.rcv_trait_relationship_type) AS rcv_trait_relationship_type,
            ANY_VALUE(art.medgen_id) AS medgen_id
          FROM (SELECT DISTINCT scv_id, rcv_trait_set_id FROM unassigned) u
          JOIN {P}.temp_all_rcv_traits art
            ON art.rcv_trait_set_id = u.rcv_trait_set_id
          LEFT JOIN already_assigned aa
            ON aa.scv_id = u.scv_id
            AND aa.normalized_trait_id = art.rcv_trait_id
          WHERE 
            aa.normalized_trait_id IS NULL
          GROUP BY 
            u.scv_id, 
            u.rcv_trait_set_id, 
            art.rcv_trait_id
        ),
        -- Count unassigned cat_ids and unassigned traits per scv_id;
        -- only eligible when counts match
        unassigned_cat_counts AS (
          SELECT scv_id, rcv_trait_set_id, COUNT(*) AS unassigned_cat_count
          FROM unassigned
          GROUP BY scv_id, rcv_trait_set_id
        ),
        unassigned_trait_counts AS (
          SELECT scv_id, rcv_trait_set_id, COUNT(*) AS unassigned_trait_count
          FROM unassigned_traits
          GROUP BY scv_id, rcv_trait_set_id
        ),
        valid_groups AS (
          SELECT
            uc.scv_id,
            uc.rcv_trait_set_id
          FROM unassigned_cat_counts uc
          JOIN unassigned_trait_counts ut
            ON ut.scv_id = uc.scv_id
            AND ut.rcv_trait_set_id = uc.rcv_trait_set_id
          WHERE uc.unassigned_cat_count = ut.unassigned_trait_count
        ),
        numbered_unassigned AS (
          SELECT
            u.*,
            ROW_NUMBER() OVER (PARTITION BY u.scv_id ORDER BY u.cat_id) AS rn
          FROM unassigned u
          JOIN valid_groups vg ON vg.scv_id = u.scv_id
        ),
        numbered_traits AS (
          SELECT
            ut.scv_id, ut.rcv_trait_set_id, ut.rcv_trait_id, ut.rcv_trait_name, ut.rcv_trait_type,
            ut.rcv_trait_relationship_type, ut.medgen_id,
            ROW_NUMBER() OVER (PARTITION BY ut.scv_id ORDER BY ut.rcv_trait_id) AS rn
          FROM unassigned_traits ut
          JOIN valid_groups vg
            ON vg.scv_id = ut.scv_id
            AND vg.rcv_trait_set_id = ut.rcv_trait_set_id
        )
        SELECT
          nu.* EXCEPT(
            rn,
            normalized_trait_set_id,
            normalized_trait_id,
            normalized_trait_name,
            normalized_trait_type,
            normalized_trait_relationship_type,
            normalized_trait_medgen_id,
            normalized_resolution_type
          ),
          nt.rcv_trait_set_id as normalized_trait_set_id,
          nt.rcv_trait_id as normalized_trait_id,
          nt.rcv_trait_name as normalized_trait_name,
          nt.rcv_trait_type as normalized_trait_type,
          nt.rcv_trait_relationship_type as normalized_trait_relationship_type,
          nt.medgen_id as normalized_trait_medgen_id,
          'random trait assignment' AS normalized_resolution_type
        FROM numbered_unassigned nu
        LEFT JOIN numbered_traits nt
          ON nt.scv_id = nu.scv_id
          AND nt.rn = nu.rn
        UNION ALL 
        SELECT stas1.*
        FROM {P}.temp_scv_trait_assignment_stage1 stas1
        LEFT JOIN numbered_unassigned nu
        ON
          nu.cat_id = stas1.cat_id
        WHERE nu.cat_id IS NULL
    """, '{S}', rec.schema_name);
    SET temp_scv_trait_assignment_stage2_query = REPLACE(temp_scv_trait_assignment_stage2_query, '{CT}', temp_create);
    SET temp_scv_trait_assignment_stage2_query = REPLACE(temp_scv_trait_assignment_stage2_query, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE temp_scv_trait_assignment_stage2_query;


    -- -----------------------------------------------------------------------
    -- STEP 10: Create gks_scv_condition_sets
    -- -----------------------------------------------------------------------
    SET query_condition_sets = REPLACE("""
      CREATE OR REPLACE TABLE `{S}.gks_scv_condition_sets`
      AS
        WITH base_conditions AS (
          -- 1. Build the heavy condition struct ONCE and calculate the window partition count.
          -- This keeps the network shuffle tiny (just counting the scv_id partition).
          SELECT 
            scm.scv_id,
            IF(scm.rcv_trait_count > 1, FORMAT('#/conditionSet/%s', ts.id), NULL) AS conditionSet,
            IF(scm.rcv_trait_count = 1, ts.condition_refs[SAFE_OFFSET(0)], NULL) AS condition,
            scm.multiple_condition_explanation,
            scm.cats_trait_count as scv_trait_count,
            STRUCT(
              scm.cat_id AS id,
              scm.submitted_name AS name,
              scm.submitted_type AS type,
              scm.submitted_medgen_id AS medgen_id,
              IF(ARRAY_LENGTH(scm.submitted_xrefs) > 0, scm.submitted_xrefs, []) AS xrefs,
              
              IF(scm.mapped_trait_id IS NULL AND scm.normalized_trait_medgen_id IS DISTINCT FROM scm.tm_medgen_id,
                STRUCT(scm.tm_medgen_id AS id, scm.tm_medgen_name AS name),
                NULL
              ) AS original_medgen_match,
              
              IF(scm.mapped_trait_id IS DISTINCT FROM scm.normalized_trait_id, 
                FORMAT('#/condition/clinvar.trait:%s', scm.mapped_trait_id), 
                NULL
              ) AS direct_match,
              
              FORMAT('#/condition/clinvar.trait:%s', scm.normalized_trait_id) AS normalized_match,
              scm.normalized_resolution_type AS normalized_resolution,
              STRUCT(scm.mapping_type AS type, scm.mapping_ref AS ref, scm.mapping_value AS value) AS mapping
            ) AS condition_struct
          FROM 
            {P}.temp_scv_trait_assignment_stage2 scm
          LEFT JOIN `{S}.gks_trait_sets` 
            ts ON FORMAT('clinvar.traitset:%s', scm.rcv_trait_set_id) = ts.id
        ),
        multi_sets AS (
          -- 2a. Aggregate ONLY multi-condition records. 
          -- We only pay the memory/CPU penalty for ARRAY_AGG and regex sorting on rows that actually need it.
          SELECT
            scv_id,
            STRUCT(
              conditionSet,
              condition,
              multiple_condition_explanation,
              ARRAY_AGG(condition_struct ORDER BY CAST(REGEXP_EXTRACT(condition_struct.id, r'\\.(\\d+)$') AS INT)) AS concepts
            ) AS value_submitted_condition_set
          FROM base_conditions
          WHERE scv_trait_count > 1
          GROUP BY scv_id, conditionSet, condition, multiple_condition_explanation
        ),
        singles AS (
          -- 2b. Isolate single-condition records. 
          -- Zero aggregation, zero regex, zero shuffle footprint.
          SELECT
            scv_id,
            (SELECT AS STRUCT
              conditionSet,
              condition,
              condition_struct.*
            )
            AS value_submitted_condition
          FROM base_conditions
          WHERE scv_trait_count = 1
        )
        -- 3. Final assembly. 
        -- A double LEFT JOIN on mutually exclusive subsets is highly performant in BigQuery columnar storage.
        SELECT
          gsts.scv_id,
          STRUCT(
            -- Dynamically assign the name based on which join successfully hit
            IF(ms.scv_id IS NOT NULL, 'submittedConditionSet', 'submittedCondition') AS name,
            ms.value_submitted_condition_set,
            s.value_submitted_condition
          ) AS extensions
        FROM 
          {P}.temp_gks_scv_trait_sets gsts
        LEFT JOIN 
          multi_sets ms ON ms.scv_id = gsts.scv_id
        LEFT JOIN 
          singles s ON s.scv_id = gsts.scv_id
    """, '{S}', rec.schema_name);
    SET query_condition_sets = REPLACE(query_condition_sets, '{CT}', temp_create);
    SET query_condition_sets = REPLACE(query_condition_sets, '{P}', IF(debug, rec.schema_name, '_SESSION'));

    EXECUTE IMMEDIATE query_condition_sets;

    IF NOT debug THEN

      DROP TABLE IF EXISTS _SESSION.temp_rcv_mapping_traits;
      DROP TABLE IF EXISTS _SESSION.temp_gks_scv_trait_sets;
      DROP TABLE IF EXISTS _SESSION.temp_all_rcv_traits;
      DROP TABLE IF EXISTS _SESSION.temp_scv_trait_name_xrefs;
      DROP TABLE IF EXISTS _SESSION.temp_scv_trait_mappings;  
      DROP TABLE IF EXISTS _SESSION.temp_scv_trait_assignment_stage1;
      DROP TABLE IF EXISTS _SESSION.temp_scv_trait_assignment_stage2;

    END IF;

  END FOR;

END;