CREATE OR REPLACE PROCEDURE `clinvar_ingest.cleanup_temp_tables`(schema_name STRING, table_names ARRAY<STRING>)
BEGIN
  DECLARE i INT64 DEFAULT 0;
  DECLARE drop_query STRING;

  WHILE i < ARRAY_LENGTH(table_names) DO
    SET drop_query = FORMAT('DROP TABLE IF EXISTS `%s.%s`', schema_name, table_names[OFFSET(i)]);
    EXECUTE IMMEDIATE drop_query;
    SET i = i + 1;
  END WHILE;
END;
