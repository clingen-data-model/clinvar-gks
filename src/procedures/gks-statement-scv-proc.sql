CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_statement_scv_proc`(on_date DATE) 
BEGIN FOR rec IN (
    select s.schema_name
    FROM clinvar_ingest.schema_on(on_date) as s
  ) DO EXECUTE IMMEDIATE FORMAT(
    """
      CREATE OR REPLACE TABLE `%s.gks_statement_scv_pre`
      as
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
              FORMAT('https://pubmed.ncbi.nlm.nih.gov/%%s',cid.id)
            WHEN LOWER(cid.source) = 'pmc' THEN 
              FORMAT('https://europepmc.org/article/PMC/%%s',cid.id)
            WHEN LOWER(cid.source) = 'doi' THEN 
              FORMAT('https://doi.org/%%s',cid.id)
            WHEN LOWER(cid.source) = 'bookshelf' THEN 
              FORMAT('https://www.ncbi.nlm.nih.gov/books/%%s',cid.id)
            ELSE
              cid.curie
            END] as urls
          ) as doc
        FROM `%s.gks_scv` scv
        CROSS JOIN UNNEST(scv.scvCitations) as c
        CROSS JOIN UNNEST(c.id) as cid
        WHERE 
          cid.source IS NOT NULL
        UNION ALL
        SELECT
          scv.id,
          STRUCT(
            'Document' as type,
            IF(LOWER(cid.source) = 'pubmed', cid.id, null) as pmid,
            IF(LOWER(cid.source) = 'doi', cid.id, null) as doi,
            [CASE 
            WHEN c.url IS NOT NULL THEN 
              c.url
            WHEN LOWER(cid.source) = 'pubmed' THEN 
              FORMAT('https://pubmed.ncbi.nlm.nih.gov/%%s',cid.id)
            WHEN LOWER(cid.source) = 'pmc' THEN 
              FORMAT('https://europepmc.org/article/PMC/%%s',cid.id)
            WHEN LOWER(cid.source) = 'doi' THEN 
              FORMAT('https://doi.org/%%s',cid.id)
            WHEN LOWER(cid.source) = 'bookshelf' THEN 
              FORMAT('https://www.ncbi.nlm.nih.gov/books/%%s',cid.id)
            ELSE
              cid.curie
            END] as urls
          ) as doc
        FROM `%s.gks_scv` scv
        CROSS JOIN UNNEST(scv.scvCitations) as c
        CROSS JOIN UNNEST(c.id) as cid
        WHERE 
          cid.source is null 
          AND 
          c.url is not null
      ),
      scv_citations as (
        SELECT
          id,
          ARRAY_AGG(doc) as reportedIn
        FROM scv_citation
        GROUP BY id
      ),
      contrib AS (
        SELECT
          scv.id,
          [
            STRUCT(
              'Contribution' as type,
              scv.submitter as contributor,
              scv.date_last_updated as date,
              'submitted' as activityType
            ),
            STRUCT(
              'Contribution' as type,
              scv.submitter as contributor,
              scv.date_created as date,
              'created' as activityType
            ),
            STRUCT(
              'Contribution' as type,
              scv.submitter as contributor,
              scv.last_evaluated as date,
              'evaluated' as activityType
            )
          ] as contributions
        FROM `%s.gks_scv` scv
      ),
      scv_method as (
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
                    FORMAT('https://pubmed.ncbi.nlm.nih.gov/%%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'pmc' THEN 
                    FORMAT('https://europepmc.org/article/PMC/%%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'doi' THEN 
                    FORMAT('https://doi.org/%%s',STRING_AGG(cid.id))
                  WHEN LOWER(cid.source) = 'bookshelf' THEN 
                    FORMAT('https://www.ncbi.nlm.nih.gov/books/%%s',STRING_AGG(cid.id))
                  ELSE
                    FORMAT('%%s:%%s', cid.source, STRING_AGG(cid.id))
                  END
                ] as urls
              ),
              null
            ) as reportedIn
          ) as specifiedBy
        FROM `%s.gks_scv` scv
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
      ),
      scv_ext as (
        SELECT
          scv.id,
          ARRAY_CONCAT(
            ARRAY_CONCAT(
              ARRAY_CONCAT(
                [
                  STRUCT('clinvarScvId' as name, scv.id as value_string),
                  STRUCT('clinvarScvVersion' as name, CAST(scv.version AS STRING) as value_string)
                ],
                IF(
                  scv.review_status IS NULL,
                  [],
                  [STRUCT('clinvarScvReviewStatus' as name, scv.review_status as value_string)]
                )
              ),
              IF(
                scv.submitted_classification IS NOT DISTINCT FROM scv.classification_name,
                [],
                [STRUCT('submittedScvClassification' as name, scv.submitted_classification as value_string)]
              )  
            ),
            IF(
              scv.local_key IS NULL,
              [],
              [STRUCT('submittedScvLocalKey' as name, scv.local_key as value_string)]
            )
          ) extensions
        FROM `%s.gks_scv` scv
      )
      -- final output before it is normalized into json
      SELECT 
        FORMAT('%%s.%%i', scv.id, scv.version) as id,
        'Statement' as type,
        sp as proposition,
        STRUCT(
          scv.submitted_classification as name,
          IF(
            scv.classification_code IS NOT NULL,
            STRUCT(scv.classification_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding
        ) as classification,
         STRUCT(
          scv.strength_name as name,
          IF(
            scv.strength_code IS NOT NULL,
            STRUCT(scv.strength_code as code, scv.classif_and_strength_code_system as system),
            null
          ) as primaryCoding
        ) as strength,
        scv.direction,
        scv.classification_comment as description,
        contrib.contributions,
        sm.specifiedBy,
        scit.reportedIn,
        sext.extensions,
        IF (
          stp.id is not null,
          [
            STRUCT(
              FORMAT('%%s.%%i', scv.id, scv.version) as id,
              'EvidenceLine' as type,
              stp as proposition,
              'supports' as directionOfEvidenceProvided,
              CASE scv.classification_code
                WHEN 'tier 1' THEN
                  STRUCT('Level A/B' as name)
                WHEN 'tier 2' THEN
                  STRUCT('Level C/D' as name)
                ELSE
                  STRUCT(scv.classification_code as name)
              END as evidenceOutcome
            )
          ],
          []
        ) as hasEvidenceLines
      FROM `%s.gks_scv` scv
      JOIN `%s.gks_scv_proposition` sp
      ON
        sp.id = scv.id
      LEFT JOIN `%s.gks_scv_target_proposition` stp
      ON
        stp.id = scv.id
      LEFT JOIN scv_method sm
      ON
        sm.id = scv.id
      LEFT JOIN contrib
      ON
        contrib.id = scv.id
      LEFT JOIN scv_ext sext
      ON
        sext.id = scv.id
      LEFT JOIN scv_citations scit
      ON
        scit.id = scv.id
    """,
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
    CREATE OR REPLACE TABLE `%s.gks_statement_scv_by_ref`
    AS
    WITH json_draft AS (
      SELECT 
        tv.id,
        JSON_STRIP_NULLS(
          TO_JSON(tv),
        remove_empty => TRUE
        ) AS rec
      FROM `%s.gks_statement_scv_pre` AS tv
    )
    select 
      json_draft.id, 
      `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec 
    from json_draft  
  """,
  rec.schema_name,
  rec.schema_name
  );

  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE TABLE `%s.gks_statement_scv_inline`
    AS
    -- this will create the inlined subjectVariation.
    WITH inline_proposition AS (
      SELECT 
        scv.proposition.* EXCEPT (subjectVariation),
        var AS subjectVariation
      FROM `%s.gks_statement_scv_pre` AS scv 
      JOIN `clingen-dev.%s.gks_catvar_pre` AS var
      ON 
        scv.proposition.subjectVariation = var.id
    ),
    inline_scv AS (
      SELECT
        scv.* EXCEPT (proposition),
        inline_proposition AS proposition
      FROM inline_proposition
      JOIN `clingen-dev.%s.gks_statement_scv_pre` AS scv
      ON
        SPLIT(scv.id,'.')[SAFE_OFFSET(0)] = inline_proposition.id
    ),
    json_draft AS (
      SELECT 
        tv.id,
        JSON_STRIP_NULLS(
          TO_JSON(tv),
        remove_empty => TRUE
        ) AS rec
      FROM inline_scv tv
    )
    select 
      json_draft.id, 
      `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec 
    from json_draft
  """,
  rec.schema_name,
  rec.schema_name,
  rec.schema_name,
  rec.schema_name
  );

  END FOR;
END;