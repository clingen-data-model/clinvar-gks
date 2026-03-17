CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_vcv_statement_proc`(on_date DATE)
BEGIN
  DECLARE query_layer1 STRING;
  DECLARE query_layer2 STRING;
  DECLARE query_layer3 STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    
-------------------------------------------------------------------------
    -- LAYER 1: DOMAIN-DRIVEN AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer1 = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_layer1_statements` AS
      SELECT
        agg.id, 
        
        -- The pure GKS Payload
        STRUCT(
          'Statement' AS type,
          agg.id AS id, 
          'supports' AS direction,
          'definitive' AS strength,
          
          STRUCT(
            agg.actual_agg_classif_label AS name,
            IF(
              agg.agg_label_conflicting_explanation IS NOT NULL AND agg.agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, agg.agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ) AS classification,
          
          STRUCT(
            'AggregateStatementProposition' AS type,
            agg.prop_id AS id, 
            CAST(agg.variation_id AS STRING) AS subjectVariant,
            'hasAggregateClassification' AS predicate,
            
            CASE agg.statement_code
              WHEN 'O' THEN [
                STRUCT('DomainCategory' AS name, CAST(agg.statement_type AS STRING) AS value), 
                STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
              ]
              WHEN 'S' THEN [
                STRUCT('DomainCategory' AS name, CAST(agg.statement_type AS STRING) AS value), 
                STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value), 
                STRUCT('DomainGroupingKey' AS name, COALESCE(CAST(cct.label AS STRING), CAST(agg.domain_grouping_key AS STRING)) AS value)
              ]
              WHEN 'G' THEN [
                STRUCT('DomainCategory' AS name, CAST(agg.statement_type AS STRING) AS value), 
                STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value), 
                STRUCT('PropositionType' AS name, COALESCE(CAST(cpt.label AS STRING), CAST(agg.proposition_type AS STRING)) AS value)
              ]
            END AS aggregateQualifier
          ) AS proposition,
          
          -- NEW: Pointing to the full_scv_ids array!
          [
            STRUCT(
              'EvidenceLine' AS type,
              'supports' AS directionOfEvidenceProvided,
              'contributing' AS strengthOfEvidenceProvided,
              ARRAY(
                SELECT TO_JSON(STRUCT(scv_id AS id)) 
                FROM UNNEST(agg.full_scv_ids) AS scv_id
              ) AS evidenceItems
            )
          ] AS evidenceLines
          
        ) AS statement
        
      FROM `%s.gks_vcv_domain_agg` agg
      LEFT JOIN `clinvar_ingest.submission_level` sl ON agg.submission_level = sl.code
      LEFT JOIN `clinvar_ingest.clinvar_clinsig_types` cct ON agg.domain_grouping_key = cct.code AND agg.statement_type = cct.statement_type
      LEFT JOIN `clinvar_ingest.clinvar_proposition_types` cpt ON agg.proposition_type = cpt.code
        
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_layer1;


    -------------------------------------------------------------------------
    -- LAYER 2: STATEMENT LEVEL AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer2 = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_layer2_statements` AS
      SELECT
        l2.id,
        l2.contributing_statement_ids,
        l2.non_contributing_statement_ids,
        
        -- The pure GKS Payload
        STRUCT(
          'Statement' AS type,
          l2.id AS id,
          'supports' AS direction,
          'definitive' AS strength,
          
          STRUCT(
            l2.agg_label AS name,
            IF(
              l2.agg_label_conflicting_explanation IS NOT NULL AND l2.agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, l2.agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ) AS classification,
          
          STRUCT(
            'AggregateStatementProposition' AS type,
            l2.prop_id AS id,
            CAST(l2.variation_id AS STRING) AS subjectVariant,
            'hasAggregateClassification' AS predicate,
            
            -- Flat Qualifiers
            [
              STRUCT('DomainCategory' AS name, CAST(l2.statement_type AS STRING) AS value), 
              STRUCT('SubmissionLevel' AS name, CAST(sl.label AS STRING) AS value)
            ] AS aggregateQualifier
          ) AS proposition
        ) AS statement
        
      FROM `%s.gks_vcv_statement_level_agg` l2
      LEFT JOIN `clinvar_ingest.submission_level` sl ON l2.submission_level = sl.code
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_layer2;


    -------------------------------------------------------------------------
    -- LAYER 3: FINAL STATEMENT AGGREGATOR
    -------------------------------------------------------------------------
    SET query_layer3 = FORMAT("""
      CREATE OR REPLACE TABLE `%s.gks_layer3_statements` AS
      SELECT
        l3.id,
        [l3.contributing_layer2_id] AS contributing_statement_ids,
        ARRAY(SELECT nc.layer2_id FROM UNNEST(l3.non_contributing_details) AS nc) AS non_contributing_statement_ids,
        
        -- The pure GKS Payload
        STRUCT(
          'Statement' AS type,
          l3.id AS id,
          'supports' AS direction,
          'definitive' AS strength,
          
          STRUCT(
            l3.contributing_agg_label AS name,
            IF(
              l3.contributing_agg_label_conflicting_explanation IS NOT NULL AND l3.contributing_agg_label_conflicting_explanation != '',
              [STRUCT('conflictingExplanation' AS name, l3.contributing_agg_label_conflicting_explanation AS value)],
              CAST(NULL AS ARRAY<STRUCT<name STRING, value STRING>>)
            ) AS extension
          ) AS classification,
          
          STRUCT(
            'AggregateStatementProposition' AS type,
            l3.prop_id AS id,
            CAST(l3.variation_id AS STRING) AS subjectVariant,
            'hasAggregateClassification' AS predicate,
            
            -- Flat Qualifiers
            [
              STRUCT('DomainCategory' AS name, CAST(l3.statement_type AS STRING) AS value)
            ] AS aggregateQualifier
          ) AS proposition
        ) AS statement
        
      FROM `%s.gks_vcv_statement_final` l3
    """, rec.schema_name, rec.schema_name);

    EXECUTE IMMEDIATE query_layer3;

  END FOR;
END;