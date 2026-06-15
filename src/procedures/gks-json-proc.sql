CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_json_proc`(on_date DATE, output_type STRING)
BEGIN

  DECLARE gks_catvar_query STRING;
  DECLARE query_statement_scv STRING;
  DECLARE query_statement_vcv STRING;
  DECLARE query_statement_rcv STRING;

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -------------------------------------------------------------------------
    -- Cat-VRS JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('catvar', 'all') THEN

      -- Dict: variations (per-row NDJSON export)
      -- The gks_dict_* tables (sequence_reference, location, allele, gene)
      -- are already created by gks_catvar_proc as per-row key/value tables.
      -- Assembly into keyed JSON dictionaries happens at export time.
      SET gks_catvar_query = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_catvar`
        AS
        WITH x as (
          SELECT
            cv.id,
            JSON_STRIP_NULLS(
              TO_JSON(cv),
              remove_empty => TRUE
            ) AS json_data
          FROM `{S}.gks_dict_variation` cv
        )
        SELECT
          x.id,
          `clinvar_ingest.normalizeAndKeyById`(x.json_data, true) as rec
        FROM x
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE gks_catvar_query;

    END IF;

    -------------------------------------------------------------------------
    -- SCV statement JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('scv', 'all') THEN

      SET query_statement_scv = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_scv_statement`
        AS
        WITH json_draft AS (
          SELECT
            tv.id,
            JSON_STRIP_NULLS(
              TO_JSON(tv),
            remove_empty => TRUE
            ) AS rec
          FROM `{S}.gks_scv_statement_pre` AS tv
        )
        SELECT
          json_draft.id,
          `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec
        FROM json_draft
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_scv;

    END IF;

    -------------------------------------------------------------------------
    -- VCV statement JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('vcv', 'all') THEN

      SET query_statement_vcv = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_vcv_statement`
        AS
        WITH json_draft AS (
          SELECT
            tv.id,
            JSON_STRIP_NULLS(
              TO_JSON(tv),
            remove_empty => TRUE
            ) AS rec
          FROM `{S}.gks_vcv_statement_pre` AS tv
        )
        SELECT
          json_draft.id,
          `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec
        FROM json_draft
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_vcv;

    END IF;

    -------------------------------------------------------------------------
    -- RCV statement JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('rcv', 'all') THEN

      SET query_statement_rcv = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_rcv_statement`
        AS
        WITH json_draft AS (
          SELECT
            tv.id,
            JSON_STRIP_NULLS(
              TO_JSON(tv),
            remove_empty => TRUE
            ) AS rec
          FROM `{S}.gks_rcv_statement_pre` AS tv
        )
        SELECT
          json_draft.id,
          `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec
        FROM json_draft
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_rcv;

    END IF;

  END FOR;

END;
