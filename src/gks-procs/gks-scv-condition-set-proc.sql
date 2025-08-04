CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_condition_sets_proc`(on_date DATE)
BEGIN
  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    EXECUTE IMMEDIATE FORMAT("""  
      CREATE OR REPLACE TABLE `%s.gks_scv_condition_sets`
      AS
      WITH scv_trait AS (
        -- build up each individually submitted condition records based on the normalized gks_trait.
        SELECT
          scm.scv_id,
          scm.cat_id as id,
          IFNULL(scm.cat_name, scm.trait_name) as name,
          scm.cat_type as conceptType,
          t.primaryCoding,
          t.mappings,
          ARRAY_CONCAT(
            ARRAY_CONCAT(
              ARRAY_CONCAT(
                ARRAY_CONCAT(
                  t.extensions,
                  IF(
                    ARRAY_LENGTH(scm.submitted_xrefs) > 0, 
                    [STRUCT(
                      'submitted xrefs' as name, 
                      CAST(null as string) as value_string,
                      scm.submitted_xrefs as value_array_codings
                    )], 
                    []
                  )
                ),       
                IF(
                  scm.cat_tm_match IS NOT NULL, 
                  [STRUCT(
                    'submitted trait assignment' as name, 
                    scm.cat_tm_match as value_string,
                    [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
                  )],
                  []
                )
              ),
              IF(
                scm.assign_type IS NOT NULL, 
                [STRUCT(
                  'clinvar trait assignment' as name, 
                  scm.assign_type as value_string,
                  [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
                )],
                []
              )
            ),
            IF(
              scm.mapping_type IS NOT NULL, 
              [STRUCT(
                'clinvar trait mapping type:ref(val)' as name, 
                FORMAT('%%s:%%s(%%s)', scm.mapping_type, scm.mapping_ref, scm.mapping_value) as value_string,
                [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
              )],
              []
            )
          ) as extensions
        FROM `%s.gks_scv_condition_mapping` scm
        LEFT JOIN `%s.gks_trait` t
        ON
          t.id = scm.trait_id
      ),
      scv_trait_set AS (
        -- now build the condition sets: any scvs that have more than one condition
        SELECT
          scm.scv_id,
          ARRAY_AGG(
            STRUCT(
              st.id,
              st.name,
              st.conceptType,
              st.primaryCoding,
              st.mappings,
              st.extensions
            )
          ) as conditions,
          IF(
            ANY_VALUE(scm.trait_relationship_type) IN ('Finding member','co-occurring condition'), 
            'AND', 
            'OR'
          ) as membershipOperator
        FROM `%s.gks_scv_condition_mapping` scm
        JOIN scv_trait st
        ON
          st.id = scm.cat_id
        GROUP BY
          scm.scv_id
        HAVING COUNT(*) > 1
      )
      SELECT 
        gsts.scv_id,
        IF(
          st.id IS NOT NULL,
          STRUCT(
            st.id,
            st.name,
            st.conceptType,
            st.primaryCoding,
            st.mappings,
            -- trait sets with single traits will be displayed as 'Condition' domain entities 
            -- but should share the wrapping trait set information from clinvar.
            ARRAY_CONCAT(
              ARRAY_CONCAT(
                st.extensions,
                gsts.extensions
              ),
              IF(
                gsts.cats_type IS NOT NULL 
                AND 
                gsts.cats_type IS DISTINCT FROM gsts.trait_set_type, 
                [STRUCT(
                  'submitted trait set type' as name, 
                  gsts.cats_type as value_string,
                  [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
                )],
                []
              )
            ) as extensions
          ),
          NULL   
        ) as condition,
        IF(
          sts.scv_id IS NOT NULL,
          STRUCT(
            sts.scv_id as id,
            sts.conditions,
            sts.membershipOperator,
            ARRAY_CONCAT(
              gsts.extensions,
              IF(
                gsts.cats_type IS NOT NULL 
                AND 
                gsts.cats_type IS DISTINCT FROM gsts.trait_set_type, 
                [STRUCT(
                  'submitted trait set type' as name, 
                  gsts.cats_type as value_string,
                  [STRUCT(CAST(null as STRING) as code, CAST(null as STRING) as system)] as value_array_codings
                )],
                []
              )
            ) as extensions
          ),
          NULL
        ) as conditionSet   
      FROM `%s.gks_scv_trait_sets` gsts
      LEFT JOIN scv_trait_set sts
      ON
        sts.scv_id = gsts.scv_id
      LEFT JOIN scv_trait st
      ON
        sts.scv_id is NULL AND st.scv_id = gsts.scv_id
    """, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name, 
    rec.schema_name
    );

  END FOR;

END;