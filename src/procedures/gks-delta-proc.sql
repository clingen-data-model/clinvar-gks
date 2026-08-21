-- ============================================================================
-- gks_delta_build — materialize per-table delta payloads from gks_change_log
-- ============================================================================
-- For each tracked table, writes {S}.delta_<table> = the FULL current rows whose pk
-- is A or U in {S}.gks_change_log (same schema as the target table — a consumer
-- upserts it by pk directly). D tombstones are NOT payload rows; they live in the
-- manifest (gks_change_log) only. Requires gks_change_log to have been built first.
--
-- `tables` mirrors the catvar+scv-output subset of gks_change_log's `tracked` array
-- (name + pk expression). Keep in sync.
-- ============================================================================
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_delta_build`(on_date DATE)
BEGIN
  DECLARE tables ARRAY<STRUCT<name STRING, pk STRING>> DEFAULT [
    STRUCT('gks_dict_variation'          AS name, 'id' AS pk),
    STRUCT('gks_dict_sequence_reference',     'key'),
    STRUCT('gks_dict_location',               'key'),
    STRUCT('gks_dict_allele',                 'key'),
    STRUCT('gks_dict_copy_number_count',      'key'),
    STRUCT('gks_dict_copy_number_change',     'key'),
    STRUCT('gks_dict_gene',                   'key'),
    -- scv condition/statement outputs (Plan 2)
    STRUCT('gks_dict_condition',              'id'),
    STRUCT('gks_dict_condition_set',          'id'),
    STRUCT('gks_scv_condition_sets',          'scv_id'),
    STRUCT('gks_dict_submitter',              'key'),
    STRUCT('gks_dict_proposition',            'key'),
    STRUCT('gks_dict_evidence_line',          'id'),
    STRUCT('gks_dict_scv',                    'id')
  ];
  DECLARE i INT64 DEFAULT 0;
  DECLARE t STRUCT<name STRING, pk STRING>;
  DECLARE q STRING;

  FOR rec IN (SELECT s.schema_name FROM `clinvar_ingest.schema_on`(on_date) AS s)
  DO
    SET i = 0;
    WHILE i < ARRAY_LENGTH(tables) DO
      SET t = tables[OFFSET(i)];
      SET i = i + 1;
      SET q = """
        CREATE OR REPLACE TABLE `{S}.delta_{T}` AS
        SELECT src.*
        FROM `{S}.{T}` src
        WHERE CAST({PK} AS STRING) IN (
          SELECT pk FROM `{S}.gks_change_log`
          WHERE table_name = '{T}' AND change_type IN ('A','U')
        )
      """;
      SET q = REPLACE(q, '{PK}', t.pk);
      SET q = REPLACE(q, '{T}', t.name);
      SET q = REPLACE(q, '{S}', rec.schema_name);
      EXECUTE IMMEDIATE q;
    END WHILE;
  END FOR;
END;
