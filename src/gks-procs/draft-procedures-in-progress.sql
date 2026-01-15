draft-procedures-in-progress.sql

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings`
AS
  SELECT DISTINCT
    * 
    EXCEPT (release_date)
    REPLACE(
      LOWER(mapping_type) as mapping_type, 
      LOWER(mapping_ref) as mapping_ref, 
      LOWER(mapping_value) as mapping_value
    )
  FROM `clinvar_2025_03_23_v2_3_1.trait_mapping` 
  -- 5,991,257
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_mapping_traits`
AS
  SELECT 
    rm.rcv_accession,
    scv_id,
    rm.trait_set_id,
    `clinvar_ingest.parseTraitSet`(FORMAT('{"TraitSet": %s}', rm.trait_set_content)) AS ts
  FROM `clinvar_2025_03_23_v2_3_1.rcv_mapping` rm
  CROSS JOIN UNNEST(rm.scv_accessions) as scv_id
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_scv_trait_sets`
AS
  SELECT 
    cats.id as scv_id,
    rmt.trait_set_id as trait_set_id,
    ARRAY_LENGTH(rmt.ts.trait) as rcv_trait_count,
    ARRAY_LENGTH(cats.clinical_assertion_trait_ids) as cats_trait_count,
    cats.type as cats_type,
    cats.clinical_assertion_trait_ids,
    rmt.ts.trait as rcv_traits 
  FROM `clinvar_2025_03_23_v2_3_1.gks_rcv_mapping_traits` rmt
  JOIN `clinvar_2025_03_23_v2_3_1.clinical_assertion_trait_set` cats
  ON
    rmt.scv_id = cats.id
  -- 5,229,100
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_scv_trait_name_xrefs`
AS
  WITH scv_trait_xrefs AS (
    select
      id,
      type,
      medgen_id,
      name,
      trait_id,
      alternate_names,
      clinvar_ingest.parseXRefItems(xrefs) as xrefs
    FROM `clinvar_2025_03_23_v2_3_1.clinical_assertion_trait` cat
    WHERE
      ARRAY_LENGTH(SPLIT(id,'.')) = 2
    -- 3,616,101
  )
  -- db
  -- ? GeneReviews
  -- x HP   -- HP
  -- x HPO  -- HP
  -- x MESH -- MeSH
  -- x MONDO -- MONDO
  -- x MeSH -- MeSH
  -- x MedGen -- MedGen
  -- x OMIM   -- OMIM
  -- x OMIM phenotypic series -- OMIM
  -- x Orphanet -- Orphanet
  -- x UMLS    -- MedGen
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
    mesh.id as mesh_id
  FROM scv_trait_xrefs stx
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
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits`
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
    FROM `clinvar_2025_03_23_v2_3_1.clinical_assertion_trait` cat 
    LEFT JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm
    ON 
      ntm.clinical_assertion_id = REGEXP_EXTRACT(cat.id, r'SCV[0-9]+')
    GROUP BY 
      REGEXP_EXTRACT(cat.id, r'SCV[0-9]+')
    -- 5,229,100
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
    stnx.orphanet_id
  FROM all_ca_traits_and_mappings actam
  JOIN `clinvar_2025_03_23_v2_3_1.gks_scv_trait_sets` sts
  ON
    actam.scv_id = sts.scv_id
  CROSS JOIN UNNEST(actam.cat_ids) as cat_id
  LEFT JOIN `clinvar_2025_03_23_v2_3_1.gks_scv_trait_name_xrefs` stnx
  ON
    stnx.cat_id = cat_id
  WHERE 
    -- only return direct scv related trait records
    ARRAY_LENGTH(SPLIT(cat_id, '.')) = 2
  -- 5,670,063
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits`
AS
  WITH scv_trait_base_mappings AS (
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: preferred name '%s'", LOWER(ast.cat_name)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "name"
      AND
      ntm.mapping_ref = 'preferred'
      AND
      ntm.mapping_value = lower(ast.cat_name)
    -- 1,317,843
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: medgen id '%s'", LOWER(ast.medgen_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref = 'medgen'
      AND
      ntm.mapping_value = lower(ast.medgen_id)
    -- 3,491,703
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: omim id '%s'", LOWER(ast.omim_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref like 'omim%'
      AND
      ntm.mapping_value = lower(ast.omim_id)
    -- 740,533
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: mondo id '%s'", LOWER(ast.mondo_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref = 'mondo'
      AND
      ntm.mapping_value = lower(ast.mondo_id)
    -- 69,609
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: hpo id '%s'", LOWER(ast.hp_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref IN ('hp', 'hpo', 'human phenotype ontology')
      AND
      ntm.mapping_value = lower(ast.hp_id)
    -- 21,626
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: mesh id '%s'", LOWER(ast.mesh_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    join `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    on
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref = 'mesh'
      AND
      ntm.mapping_value = lower(ast.mesh_id)
    -- 5,549
    UNION ALL
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_type,
      ast.cat_name,
      ast.cat_medgen_id,
      FORMAT("scv trait: orphanet id '%s'", LOWER(ast.orphanet_id)) AS match_value,
      ntm.mapping_type,
      ntm.mapping_ref,
      ntm.mapping_value,
      ntm.medgen_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
    ON
      ntm.clinical_assertion_id = ast.scv_id
      AND
      ntm.trait_type = ast.cat_type
      AND
      ntm.mapping_type = "xref"
      AND
      ntm.mapping_ref = 'orphanet'
      AND
      ntm.mapping_value = lower(ast.orphanet_id)
    -- 17,505
    -- 5,664,368
  )
  ,
  single_trait_mapping_remaining AS (
    SELECT
      ast.scv_id
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
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
    -- 5,624 total, 1,966 have equal counts, 1,958 have only one unmapped tm
  )
  SELECT
    ast.scv_id,
    ast.cat_id,
    ast.trait_set_id,
    ast.cat_type,
    ast.cat_name,
    ast.cat_medgen_id,
    "scv trait: default to remaining trait mapping" AS match_value,
    ntm.mapping_type,
    ntm.mapping_ref,
    ntm.mapping_value,
    ntm.medgen_id
  FROM single_trait_mapping_remaining stmr
  JOIN `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
  ON
    ast.scv_id = stmr.scv_id
  LEFT JOIN scv_trait_base_mappings stbm
  ON
    stbm.cat_id = ast.cat_id
  LEFT JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_trait_mappings` ntm 
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
  -- 1,958
  UNION ALL
  SELECT
    stbm.scv_id,
    stbm.cat_id,
    stbm.trait_set_id,
    stbm.cat_type,
    stbm.cat_name,
    stbm.cat_medgen_id,
    stbm.match_value,
    stbm.mapping_type,
    stbm.mapping_ref,
    stbm.mapping_value,
    stbm.medgen_id
  from scv_trait_base_mappings stbm
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits`
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
  from `clinvar_2025_03_23_v2_3_1.gks_scv_trait_sets` sts
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

    
  -- 36,650 (one duplicate trait id 17556 'not provided' due to multiple medgen id assignments)
;

CREATE OR REPLACE TABLE  `clinvar_2025_03_23_v2_3_1.gks_normalized_traits`
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
    FROM `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
  )
  ,
  dupe_trait_recs AS (
    SELECT
      trait_id
    FROM trait_recs
    GROUP BY
      trait_id
    HAVING count(*) = 1
    -- 21,352
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
  -- 21,371 unique trait_ids
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage1`
AS
  -- Assign rcv traits to ca traits
  -- 1st match attempt: trait-mapping medgen_id to rcv medgen_id
  -- 2nd match attempt: trait-mapping mapping ref/type/values
  WITH rcv_trait_medgen_assignment AS (
    SELECT DISTINCT 
      amst.scv_id,
      amst.cat_id,
      amst.cat_name,
      amst.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "rcv-tm medgen id" AS assign_type,
      amst.mapping_type,
      amst.mapping_ref,
      amst.mapping_value,
      amst.medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      amst.trait_set_id = art.trait_set_id
      AND
      amst.medgen_id = art.medgen_id
      -- 5,458,335 rcv traits matched of 5,666,326 all scv traits
  )
  ,
  unassigned_scv_traits_pass1 AS (
    SELECT
      amst.scv_id,
      amst.cat_id,
      amst.cat_name,
      amst.cat_medgen_id,
      amst.trait_set_id,
      amst.cat_type,
      amst.mapping_type,
      amst.mapping_ref,
      amst.mapping_value,
      amst.medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
    left join rcv_trait_medgen_assignment rtma
    on
      rtma.cat_id = amst.cat_id
    where
      rtma.cat_id is null
    -- 207,991 scv traits remain unassigned to rcv traits
  )
  ,
  rcv_trait_reftype_assignment AS (
    --   process the various trait_mapping ref/type records with their rcv trait record 
    --   (DO NOT compare trait_type for rcv trait to trait mapping values)
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype preferred name" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "name"
      and
      ustp1.mapping_ref = 'preferred'
    WHERE
      ustp1.mapping_value = lower(art.trait_name)
      -- 35,512
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype alternate name" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "name"
      and
      ustp1.mapping_ref = 'alternate'
    cross join unnest(art.alternate_names) as alt_name
    WHERE
      ustp1.mapping_value = lower(alt_name)
    -- 18
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref medgen" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref = 'medgen'
    WHERE
      ustp1.mapping_value = lower(art.medgen_id)
    -- 0 (These all get matched in the 1st match attempt trait mapping medgen id.)
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref omim%" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref like 'omim%'
    cross join unnest(art.omim_ids) as omim_id
    WHERE
      ustp1.mapping_value = lower(omim_id)
    -- 0
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref mondo" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref = 'mondo'
    cross join unnest(art.mondo_ids) as mondo_id
    WHERE
      ustp1.mapping_value = lower(mondo_id)
    -- 0
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref hp" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref IN ('hp', 'hpo', 'human phenotype ontology')
    cross join unnest(art.hp_ids) as hp_id
    WHERE
      ustp1.mapping_value = lower(hp_id)
    -- 0
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref mesh" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref = 'mesh'
    cross join unnest(art.mesh_ids) as mesh_id
    WHERE
      ustp1.mapping_value = lower(mesh_id)
    -- 0
    UNION ALL
    SELECT DISTINCT 
      ustp1.scv_id,
      ustp1.cat_id,
      ustp1.cat_name,
      ustp1.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "tm reftype xref orphanet" AS assign_type,
      ustp1.mapping_type,
      ustp1.mapping_ref,
      ustp1.mapping_value,
      ustp1.medgen_id
    from unassigned_scv_traits_pass1 ustp1
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    on
      ustp1.trait_set_id = art.trait_set_id
      AND
      ustp1.mapping_type = "xref"
      and
      ustp1.mapping_ref = 'orphanet'
    cross join unnest(art.orphanet_ids) as orphanet_id
    WHERE
      ustp1.mapping_value = lower(orphanet_id)
    -- 1
    -- 35,531 total matches
  )
  select 
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from rcv_trait_medgen_assignment rtma
  UNION ALL
  select     
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from rcv_trait_reftype_assignment rtra
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage2`
AS
  WITH unassigned_scv_traits AS (
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.cat_name,
      ast.cat_medgen_id,
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
    from `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    left join `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
    on
      amst.cat_id = ast.cat_id
    left join `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage1` rtas1
    on
      rtas1.cat_id = ast.cat_id
    where
      rtas1.cat_id is null
    -- 176,197 ca traits not mapped, 172,460 scv traits have trait mappings
  )
  ,
  singleton_unassigned_scv_traits AS (
    -- figure out which remaining scv traits have only one trait left to map, 
    -- and figure out which trait ids are already mapped
    select
      ust.scv_id,
      ust.trait_set_id,
      ARRAY_TO_STRING(ARRAY_AGG(DISTINCT ust.cat_id),',') as cat_id,
      ARRAY_TO_STRING(ARRAY_AGG(DISTINCT ust.cat_name),',') as cat_name,
      ARRAY_TO_STRING(ARRAY_AGG(DISTINCT ust.cat_medgen_id),',') as cat_medgen_id,
      ARRAY_AGG(IF(rtas1.cat_id is null, null, STRUCT(rtas1.cat_id, rtas1.trait_id, rtas1.trait_name)) IGNORE NULLS) as assigned,
      ARRAY_TO_STRING(ARRAY_AGG(DISTINCT IF(rtas1.trait_id is null, art.trait_id, null) ignore nulls),',') as unassigned_trait_id
    from unassigned_scv_traits ust
    left JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    left join `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage1` rtas1
    on
      rtas1.scv_id = ust.scv_id
      and
      rtas1.trait_id = art.trait_id
    where
      ust.cats_trait_count = ust.rcv_trait_count
    group by 
      ust.scv_id,
      ust.trait_set_id
    having (
      count(distinct ust.cat_id) = 1
      AND
      count(DISTINCT IF(rtas1.trait_id is null, art.trait_id, null)) = 1
    )
    -- 175,326
  )
  ,
  rcv_trait_singleton_assignment AS (
    SELECT
      s.scv_id,
      s.cat_id,
      s.cat_name,
      s.cat_medgen_id,
      art.trait_set_id,
      art.trait_id,
      art.trait_name,
      art.trait_relationship_type,
      art.medgen_id as trait_medgen_id,
      "single remaining trait" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    FROM singleton_unassigned_scv_traits AS s

    -- join once to pull in all possible trait_set_traits for this trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = s.trait_set_id
      and
      art.trait_id = s.unassigned_trait_id

    WHERE
      -- HACK! exclude the duplicate 'not provided' trait in the "9460" trait set.
      NOT (art.trait_id = "17556" and art.medgen_id = "CN517202")
    -- 175,326
  )
  select  
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage1` rtas1
  UNION ALL
  select 
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from rcv_trait_singleton_assignment rtsa
  -- 5,669,192
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage3`
AS
  WITH unassigned_scv_traits AS (
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.cat_name,
      ast.cat_medgen_id,
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
    from `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    left join `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
    on
      amst.cat_id = ast.cat_id
    left join `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage2` rtas2
    on
      rtas2.cat_id = ast.cat_id
    where
      rtas2.cat_id is null
    -- 871
  )
  ,
  rcv_trait_direct_assignment AS (
    select DISTINCT 
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait medgen_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    where
      ust.medgen_id = art.medgen_id
    -- 2 
    UNION ALL
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait omim_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    CROSS JOIN UNNEST(nt.omim_ids) as omim_id
    where
      ust.omim_id = omim_id
    -- 4
    UNION ALL
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait hp_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    CROSS JOIN UNNEST(nt.hp_ids) as hp_id
    where
      ust.hp_id = hp_id
    -- 5
    UNION ALL
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait mondo_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    CROSS JOIN UNNEST(nt.mondo_ids) as mondo_id
    where
      ust.mondo_id = mondo_id
    -- 0
    UNION ALL
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait orphanet_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    CROSS JOIN UNNEST(nt.orphanet_ids) as orphanet_id
    where
      ust.orphanet_id = orphanet_id
    -- 0
    UNION ALL
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      art.trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv trait mesh_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from unassigned_scv_traits ust
    JOIN `clinvar_2025_03_23_v2_3_1.gks_all_rcv_traits` art
    ON 
      art.trait_set_id = ust.trait_set_id
    JOIN `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    ON
      nt.trait_id = art.trait_id
    CROSS JOIN UNNEST(nt.mesh_ids) as mesh_id
    where
      ust.mesh_id = mesh_id
    -- 0
    -- 11 total
  )
  select  
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage2` rtas2
  UNION ALL
  select 
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from rcv_trait_direct_assignment rtda
  -- 5,669,203
;

CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage4`
AS
  WITH unassigned_scv_traits AS (
    SELECT
      ast.scv_id,
      ast.cat_id,
      ast.trait_set_id,
      ast.cat_name,
      ast.cat_medgen_id,
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
    from `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
    left join `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
    on
      amst.cat_id = ast.cat_id
    left join `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage3` rtas3
    on
      rtas3.cat_id = ast.cat_id
    where
      rtas3.cat_id is null
    -- 860
  )
  ,
  rcv_rogue_assignment_1 AS (
    -- trait assignments that are not part of the mapped trait_set - yes this happens!
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait omim_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    CROSS JOIN UNNEST(nt.omim_ids) as omim_id
    join unassigned_scv_traits ust
    on
      ust.omim_id = omim_id
    -- 592
  )
  ,
  rcv_rogue_assignment_2 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait hp_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    CROSS JOIN UNNEST(nt.hp_ids) as hp_id
    join unassigned_scv_traits ust
    on
      ust.hp_id = hp_id
    left join rcv_rogue_assignment_1 rra1
    on
      rra1.cat_id = ust.cat_id
    where
      rra1.cat_id is null
    --64
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_1 rra1

    -- 656 total
  )
  ,
  rcv_rogue_assignment_3 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait orphanet_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    CROSS JOIN UNNEST(nt.orphanet_ids) as orphanet_id
    join unassigned_scv_traits ust
    on
      ust.orphanet_id = orphanet_id
    left join rcv_rogue_assignment_2 rra2
    on
      rra2.cat_id = ust.cat_id
    where
      rra2.cat_id is null
    -- 0
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_2 rra2
    -- 656 total
  )
  ,
  rcv_rogue_assignment_4 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait mondo_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    CROSS JOIN UNNEST(nt.mondo_ids) as mondo_id
    join unassigned_scv_traits ust
    on
      ust.mondo_id = mondo_id
    left join rcv_rogue_assignment_3 rra3
    on
      rra3.cat_id = ust.cat_id
    where
      rra3.cat_id is null
    -- 0
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_3 rra3
    -- 656 total
  )
  ,
  rcv_rogue_assignment_5 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait mesh_id" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    CROSS JOIN UNNEST(nt.mesh_ids) as mesh_id
    join unassigned_scv_traits ust
    on
      ust.mesh_id = mesh_id  
    left join rcv_rogue_assignment_4 rra4
    on
      rra4.cat_id = ust.cat_id
    where
      rra4.cat_id is null
    -- 0
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_4 rra4
    -- 656 total
  )
  ,
  rcv_rogue_assignment_6 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait name" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    join unassigned_scv_traits ust
    on
      LOWER(nt.trait_name) = LOWER(ust.cat_name)
    left join rcv_rogue_assignment_5 rra5
    on
      rra5.cat_id = ust.cat_id
    where
      rra5.cat_id is null
      and
      -- hack to remove all but one 'not provided' trait id from normalized trait matching for this query
      NOT (nt.trait_name = 'not provided' and nt.trait_id in ("54780", "76440","76481","78165","78166","78167"))
    -- 28
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_5 rra5
    -- 684 total
  )
  ,
  rcv_rogue_assignment_7 AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue alternate trait name" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    cross join unnest(nt.alternate_names) alt_name
    join unassigned_scv_traits ust
    on
      LOWER(alt_name) = LOWER(ust.cat_name)
    left join rcv_rogue_assignment_6 rra6
    on
      rra6.cat_id = ust.cat_id
    where
      rra6.cat_id is null
      and
      -- hack to remove all but one 'not provided' trait id from normalized trait matching for this query
      NOT (alt_name = 'not provided' and nt.trait_id in ("54780", "76440","76481","78165","78166","78167"))
    -- 9
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_6 rra6
    -- 693 total
  )
  ,
  rcv_rogue_assignment_final AS (
    select DISTINCT
      ust.scv_id,
      ust.cat_id,
      ust.cat_name,
      ust.cat_medgen_id,
      ust.trait_set_id,
      nt.trait_id,
      nt.trait_name,
      CAST(null as STRING) as trait_relationship_type,
      nt.medgen_id as trait_medgen_id,
      "rcv-scv rogue trait name" as assign_type,
      cast(null as string) as mapping_type,
      cast(null as string) as mapping_ref,
      cast(null as string) as mapping_value,
      cast(null as string) as medgen_id
    from `clinvar_2025_03_23_v2_3_1.gks_normalized_traits` nt
    join unassigned_scv_traits ust
    on
      nt.medgen_id = ust.medgen_id
      and
      ust.cat_name is null
    left join rcv_rogue_assignment_7 rra7
    on
      rra7.cat_id = ust.cat_id
    where
      rra7.cat_id is null
    -- 10
    UNION ALL
    select
      scv_id,
      cat_id,
      cat_name,
      cat_medgen_id,
      trait_set_id,
      trait_id,
      trait_name,
      trait_relationship_type,
      trait_medgen_id,
      assign_type,
      mapping_type,
      mapping_ref,
      mapping_value,
      medgen_id
    from rcv_rogue_assignment_7 rra7
    -- 703 total
  )
  select  
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage3` rtas3
  UNION ALL
  select 
    scv_id,
    cat_id,
    cat_name,
    cat_medgen_id,
    trait_set_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id
  from rcv_rogue_assignment_final rraf
  -- 5,669,906
;


CREATE OR REPLACE TABLE `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_final`
AS
  SELECT
    ast.scv_id,
    ast.cat_id,
    ast.trait_set_id,
    ast.cat_name,
    ast.cat_medgen_id,
    CAST(null as STRING) as trait_id,
    CAST(null as STRING) as trait_name,
    CAST(null as STRING) as trait_relationship_type,
    CAST(null as STRING)  as trait_medgen_id,
    "unassignable scv trait" as assign_type,
    cast(null as string) as mapping_type,
    cast(null as string) as mapping_ref,
    cast(null as string) as mapping_value,
    cast(null as string) as medgen_id
  from `clinvar_2025_03_23_v2_3_1.gks_all_scv_traits` ast
  left join `clinvar_2025_03_23_v2_3_1.gks_all_mapped_scv_traits` amst
  on
    amst.cat_id = ast.cat_id
  left join `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage4` rtas4
  on
    rtas4.cat_id = ast.cat_id
  where
    rtas4.cat_id is null
  -- 118
  UNION ALL
  SELECT
    scv_id,
    cat_id,
    trait_set_id,
    cat_name,
    cat_medgen_id,
    trait_id,
    trait_name,
    trait_relationship_type,
    trait_medgen_id,
    assign_type,
    mapping_type,
    mapping_ref,
    mapping_value,
    medgen_id 
  FROM `clinvar_2025_03_23_v2_3_1.gks_rcv_trait_assignment_stage4` rtas4
;
