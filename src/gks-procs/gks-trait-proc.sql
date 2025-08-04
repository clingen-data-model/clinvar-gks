CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_trait_proc`(on_date DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    EXECUTE IMMEDIATE FORMAT("""  
      CREATE OR REPLACE TABLE `%s.gks_trait`
      AS
        WITH traits AS (
          select distinct
            t.id,
            t.type,
            t.name,
            ARRAY_TO_STRING(t.alternate_names,', ') as synonyms,
            clinvar_ingest.parseXRefItems(t.xrefs) as xrefs
          FROM `%s.trait` t
        ),
        trait_xrefs AS (
          select 
            t.id,
            t.name,
            t.type,
            t.synonyms,
            STRUCT(
              IF(xref.db='MedGen', t.name, null) as name,
              xref.id as code,
              xref.db as system,
              CASE xref.db
              WHEN 'MedGen' THEN
                [
                  FORMAT('https://identifiers.org/medgen:%%s', xref.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/medgen/%%s', xref.id)
                ] 
              WHEN 'OMIM' THEN
                [
                  FORMAT('https://identifiers.org/mim:%%s', xref.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/medgen/%%s', xref.id)
                ]
              WHEN 'Human Phenotype Ontology' THEN
                [
                  FORMAT('https://identifiers.org/%%s', xref.id),
                  FORMAT('https://hpo.jax.org/browse/term/%%s', xref.id)
                ]
              WHEN 'MONDO' THEN
                [
                  FORMAT('https://identifiers.org/mondo:%%s', REGEXP_EXTRACT(xref.id, r'(\\d+)')),
                  FORMAT('http://purl.obolibrary.org/obo/MONDO_%%s', REGEXP_EXTRACT(xref.id, r'(\\d+)'))
                ]    
              WHEN 'Orphanet' THEN
                [
                  FORMAT('https://identifiers.org/orphanet.ordo:Orphanet_%%s', xref.id),
                  FORMAT('http://www.orpha.net/ORDO/Orphanet_%%s', xref.id)
                ]    
              WHEN 'MeSH' THEN
                [
                  FORMAT('https://identifiers.org/mesh:%%s', xref.id),
                  FORMAT('https://www.ncbi.nlm.nih.gov/mesh/?term=%%s', xref.id)
                ]    
              WHEN 'EFO' THEN
                [
                  FORMAT('https://identifiers.org/efo:%%s', xref.id),
                  FORMAT('http://www.ebi.ac.uk/efo/EFO_%%s', xref.id)
                ]    
              ELSE
                []
              END as iris
            ) as mapping
          from traits t
          CROSS JOIN UNNEST(t.xrefs) as xref
          WHERE
            xref.ref_field is null 
            and 
            xref.db <> 'Gene'
            and
            (xref.type is null or xref.type = 'primary')
        )
        SELECT 
          t.id,
          t.type as conceptType,
          t.name,
          ARRAY_AGG( 
            IF(
              tx.mapping.system = 'MedGen',
              tx.mapping, 
              null
            )
            IGNORE NULLS  
          )[SAFE_OFFSET(0)] as primaryCoding,
          ARRAY_AGG( 
            IF(
              tx.mapping.system <> 'MedGen',
              STRUCT(tx.mapping as coding, 'relatedMatch' as relation), 
              null
            )
            IGNORE NULLS
          ) as mappings,
          ARRAY_CONCAT(
            [
              STRUCT( 
                'clinvar trait id' as name,
                t.id as value_string,
                [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
              ),
              STRUCT( 
                'clinvar trait type' as name,
                t.type as value_string,
                [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
              )
            ],
            IF(
              t.synonyms is not null and t.synonyms <> '',
              [STRUCT(
                'aliases' as name, 
                t.synonyms as value_string,
                [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
              )],
              [] 
            )
          ) as extensions
        FROM traits t
        LEFT JOIN trait_xrefs tx
        ON
          tx.id = t.id
        GROUP BY 
          t.id,
          t.type,
          t.name,
          t.synonyms
      """, 
      rec.schema_name, 
      rec.schema_name
      );

  END FOR;

END;





-- CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_trait_proc`(on_date DATE)
-- BEGIN
--   FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
--   DO
--     EXECUTE IMMEDIATE FORMAT("""
--       CREATE OR REPLACE TABLE `%s.gks_trait`
--       as
--         select 
--           scv.id as scv_id,
--           scv.version as scv_ver,
--           FORMAT('%%s.%%i', scv.id, scv.version) as full_scv_id,
--           ts.id as trait_set_id,
--           ts.type as trait_set_type,
--           scv.clinical_assertion_trait_set_id as ca_trait_set_id,
--           cat.id as cat_id,
--           cat.name as cat_name,
--           t.id as trait_id,
--           ca_trait_id,
--           STRUCT (
--             FORMAT('clinvarTrait:%%s',t.id) as id,
--             t.type as type,
--             IFNULL(t.name, 'None') as label,
--             IF(
--               t.medgen_id is null, null,
--               [
--                 -- for now just do medgen, leave the other xrefs for later
--                 STRUCT(
--                     STRUCT (
--                     t.medgen_id as code, 
--                     'https://www.ncbi.nlm.nih.gov/medgen/' as system
--                     ) as coding,
--                   'exactMatch' as relation
--                 )
--               ]
--             ) as mappings
--           ) as condition
--         FROM `%s.gks_scv` scv
--         JOIN `%s.clinical_assertion_trait_set` cats
--         ON
--           scv.clinical_assertion_trait_set_id = cats.id
--         CROSS JOIN UNNEST(cats.clinical_assertion_trait_ids) as ca_trait_id
--         JOIN `%s.clinical_assertion_trait` cat
--         ON
--           cat.id = ca_trait_id
--         LEFT JOIN `%s.trait` t
--         ON
--           t.id = cat.trait_id
--         LEFT JOIN `%s.trait_set` ts
--         ON
--           ts.id = scv.trait_set_id
--     """, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name, rec.schema_name);

--   END FOR;

-- END;


-- CREATE OR REPLACE TABLE `%s.gks_ts_lookup`
-- as
-- select 
--   ts.id as trait_set_id, ts.type as trait_set_type,
--   ARRAY_TO_STRING((ARRAY_AGG(trait_id RESPECT NULLS ORDER BY trait_id)), '|','NULL') as traits
-- from `%s.trait_set` ts
-- cross join unnest(ts.trait_ids) as trait_id
-- join `%s.trait` t
-- on
--   t.id = trait_id
-- group by ts.id, ts.type
-- ;



-- -- NOTE: WE ARE CHANGING the NULL trait_set_id values in an original clinical assertion table here (BE CAREFUL?)
-- -- -- still need to make sure all trait_set_ids are right for the gks cats table
-- -- select
-- --   ca.trait_set_id,
-- --   x.*,
-- --   tslu.*
-- UPDATE `%s.clinical_assertion` ca
-- set ca.trait_set_id = tslu.trait_set_id
-- from 
-- (
--   select 
--     gkt.scv_id, gkt.trait_set_id,
--     ARRAY_TO_STRING((ARRAY_AGG(gkt.trait_id RESPECT NULLS ORDER BY gkt.trait_id)), '|','NULL') as traits
--   from `%s.gks_traits` gkt  
--   group by gkt.scv_id, gkt.trait_set_id

--   -- 250,023 of  are null trait_set_ids
--   -- 3,909,572 have trait_set_ids (unclear how confident we are on these)
--   -- total of 4,159,595 records
--   -- some observations below
--   --CN166718 replaced by C5555857
--   --CN181497 replaced by CN204472 (not clear)
--   --CN043578 replaced by C4082197

-- ) x
-- left join `%s.gks_ts_lookup` tslu
-- on
--   tslu.traits = x.traits 
-- -- join `clinvar_2024_08_05_v1_6_62.clinical_assertion` ca
-- -- on x.scv_id = ca.id
-- where 
--   x.trait_set_id is null 
--   and tslu.trait_set_id is not null
--   and x.scv_id = ca.id
--   -- and ca.trait_set_id is  null
-- ;