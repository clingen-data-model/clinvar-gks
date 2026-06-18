# CLAUDE.md

## General Rules

- Only modify files explicitly requested by the user. Do not proactively edit test files, SQL files, or other files beyond the scope of the current request without asking first.
- Don't assume. Don't hide confusion. Surface tradeoffs.
- Minimum code that solves the problem. Nothing speculative.
- Touch only what you must. Clean up only your own mess.
- Define success criteria. Loop until verified.

## Project Context

ClinVar-GKS transforms ClinVar XML releases into GA4GH GKS format (VRS, Cat-VRS, VA-Spec). BigQuery SQL stored procedures in `src/procedures/` do the heavy lifting. Output is a single bundled JSON file distributed via Cloudflare R2. Documentation lives in `docs/` (MkDocs with Material theme).

## SQL Stored Procedure Conventions

### Dynamic SQL Pattern

All procedures use `DECLARE` / `SET` / `REPLACE` / `EXECUTE IMMEDIATE`:

```sql
DECLARE query STRING;
SET query = """
  CREATE OR REPLACE TABLE {S}.my_table AS
  SELECT * FROM {S}.source_table
""";
SET query = REPLACE(query, '{S}', rec.schema_name);
EXECUTE IMMEDIATE query;
```

- `{S}` = `rec.schema_name` (target dataset/schema)
- `{CT}` = `temp_create` (switches between `CREATE TEMP TABLE` and `CREATE OR REPLACE TABLE` based on debug flag)
- `{P}` = table prefix (`_SESSION` for temp tables, `rec.schema_name` for debug)
- One `DECLARE` per query variable at the top of the procedure body

### BigQuery Gotchas

- No DEFAULT parameter values in procedures
- Escape sequences in `EXECUTE IMMEDIATE` triple-quoted strings: `\\n`, `\\d`
- `ARRAY_CONCAT_AGG` cannot be used inside `UNNEST` — split into two layers
- `SELECT DISTINCT` cannot include JSON columns — use `GROUP BY` + `ANY_VALUE` instead
- `COALESCE` across subqueries returning different STRUCT types fails — use `UNION ALL` CTE instead
- Arrays cannot contain NULL elements — guard with `IF(val IS NOT NULL, [FORMAT(...)], [])`

## Naming Conventions

- VCV/RCV aggregation layers: **classification** (by classification label), **priority** (by tier), **aggregate** (by submission level)
- Proposition IDs: `{scv_id}-{PROP_CODE}` for SCVs, `{accession}-{group}-{PROP}-{level}` for VCV/RCV
- Bundle references use `#/{section}/{key}` JSON pointer format
- Use "Variant" or "Variation" in docs headers; introduce Cat-VRS types only in GKS context

## Git Conventions

- Default branch is `main`
- Do NOT include "Generated with Claude Code" or "Co-Authored-By: Claude" in commits
- Keep commit messages clean and focused on the changes

## Documentation

- Run `mkdocs build --strict` after any docs changes to validate before committing
- Use the `write-docs` skill for creating/editing MkDocs pages
- Use "bundle" (not "dictionary") when referring to the output format
