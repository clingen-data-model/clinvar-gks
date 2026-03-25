CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_json_proc`(on_date DATE, output_type STRING, debug BOOL)
BEGIN

  DECLARE gks_catvar_query STRING;
  DECLARE query_statement_scv_by_ref STRING;
  DECLARE query_statement_scv_inline STRING;

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
        CREATE OR REPLACE TABLE `{S}.gks_statement_scv_by_ref`
        AS
        WITH json_draft AS (
          SELECT
            tv.id,
            JSON_STRIP_NULLS(
              TO_JSON(tv),
            remove_empty => TRUE
            ) AS rec
          FROM `{S}.gks_statement_scv_pre` AS tv
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
        CREATE OR REPLACE TABLE `{S}.gks_statement_scv_inline`
        AS
        WITH inline_proposition AS (
          SELECT
            scv.proposition.* EXCEPT (subjectVariation),
            var AS subjectVariation
          FROM `{S}.gks_statement_scv_pre` AS scv
          JOIN `clingen-dev.{S}.gks_catvar_pre` AS var
          ON
            scv.proposition.subjectVariation = var.id
        ),
        inline_scv AS (
          SELECT
            scv.* EXCEPT (proposition),
            inline_proposition AS proposition
          FROM inline_proposition
          JOIN `clingen-dev.{S}.gks_statement_scv_pre` AS scv
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
      """, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE query_statement_scv_inline;

    END IF;

  END FOR;

END;
