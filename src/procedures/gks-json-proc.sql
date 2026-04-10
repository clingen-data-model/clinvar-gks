CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_json_proc`(on_date DATE, output_type STRING, debug BOOL)
BEGIN

  DECLARE gks_catvar_query STRING;
  DECLARE query_statement_scv_by_ref STRING;
  DECLARE query_statement_scv_inline STRING;
  DECLARE query_statement_vcv STRING;
  DECLARE query_statement_rcv STRING;

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -------------------------------------------------------------------------
    -- Cat-VRS JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('catvar', 'all') THEN

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
          FROM `{S}.gks_catvar_pre` cv
        )
        SELECT
          x.id,
          `clinvar_ingest.normalizeAndKeyById`(x.json_data, true) as rec
        FROM x
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE gks_catvar_query;

    END IF;

    -------------------------------------------------------------------------
    -- SCV statement by-ref JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('scv_by_ref', 'all') THEN

      SET query_statement_scv_by_ref = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_scv_statement_by_ref`
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
        select
          json_draft.id,
          `clinvar_ingest.normalizeAndKeyById`(json_draft.rec, true) as rec
        from json_draft
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_scv_by_ref;

    END IF;

    -------------------------------------------------------------------------
    -- SCV statement inline JSON output
    -------------------------------------------------------------------------
    IF output_type IN ('scv_inline', 'all') THEN

      SET query_statement_scv_inline = REPLACE("""
        CREATE OR REPLACE TABLE `{S}.gks_scv_statement_inline`
        AS
        WITH inline_proposition AS (
          SELECT
            scv.proposition.* EXCEPT (subjectVariant),
            var AS subjectVariant
          FROM `{S}.gks_scv_statement_pre` AS scv
          JOIN `clingen-dev.{S}.gks_catvar_pre` AS var
          ON
            scv.proposition.subjectVariant = var.id
        ),
        inline_scv AS (
          SELECT
            scv.* EXCEPT (proposition),
            inline_proposition AS proposition
          FROM inline_proposition
          JOIN `clingen-dev.{S}.gks_scv_statement_pre` AS scv
          ON
            scv.proposition.id = inline_proposition.id
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
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_scv_inline;

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
