# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClinVar-GKS is a data transformation pipeline that converts ClinVar release data to GA4GH GKS (Global Alliance for Genomics and Health - Genomic Knowledge Standards) format. The project is BigQuery-centric and relies heavily on SQL stored procedures for data processing.

## Core Architecture

### Data Processing Pipeline
The system follows a multi-step ETL process:
1. **Variation Identity Extraction** (`variation-identity-proc.sql`) - Extract core variant data from ClinVar
2. **External VRS Processing** - Convert variants to VRS format using external Python tools
3. **BigQuery Integration** - Load VRS data back into BigQuery tables
4. **Cat-VRS Generation** (`gks-catvar-proc.sql`) - Create categorical variant representations  
5. **Statement Generation** (`gks-statement-scv-proc.sql`, etc.) - Generate clinical statements
6. **Export and Distribution** - Output to Google Cloud Storage

### Key Technologies
- **BigQuery SQL**: Primary data transformation language
- **Bash Scripts**: Pipeline automation and deployment
- **JSON/JSONC**: Data schemas and examples
- **Google Cloud Platform**: Infrastructure (BigQuery, Cloud Storage)

## Directory Structure

- `/src/procedures/` - BigQuery SQL stored procedures
- `/src/scripts/` - Shell scripts for pipeline operations (export, import)
- `/src/vrs-location-transformer/` - Cloud Run service for VRS location transformation
- `/src/gks-registry/` - Python tool for aggregating GA4GH GKS schema metadata
- `/examples/` - Example data organized by type (cat-vrs/, scv/, vcv/)
- `/schemas/` - VRS output JSON schemas
- `/docs/` - MkDocs documentation source
- `/notes/` - Working development documentation
- `/archive/` - Historical/WIP material preserved for reference

## Development Commands

### BigQuery Procedure Execution
```sql
-- Step 1: Extract variation identity
CALL `clinvar_ingest.variation_identity_proc`(CURRENT_DATE());

-- Step 2: Generate Cat-VRS canonical alleles
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE());

-- Step 3: Generate SCV statements
CALL `clinvar_ingest.gks_statement_scv_proc`(CURRENT_DATE());
```

### Data Export Commands
```bash
# Export variation identity for VRS processing
bq extract --destination_format NEWLINE_DELIMITED_JSON \
  'dataset.variation_identity' gs://bucket/vi.json.gz

# Create VRS tables
./src/scripts/vrs-to-bq-table.sh
```

## Standards Compliance

The project implements multiple GA4GH specifications:
- **VRS (Variation Representation Specification)** - Genomic variation representation
- **Cat-VRS (Categorical VRS)** - Categorical variant representations
- **VA-Spec (Variant Annotation Specification)** - Clinical variant statements

## Infrastructure Dependencies

- **Google Cloud Platform** with BigQuery and Cloud Storage access
- **ClinGen Dev GCP Project** for development environment
- **VRS-Python** external dependency for variant representation processing

## Data Processing Notes

- Processing operates on full ClinVar datasets (2.8M+ variations, 4.1M+ SCVs)
- Pipeline is designed for periodic batch processing (typically weekly with ClinVar releases)
- Manual coordination required between BigQuery processing and external VRS Python tools
- No automated testing framework - validation done through manual data review

## Example Data Structure

Check `/examples/` directory for data structure examples organized by type:
- `cat-vrs/` - Cat-VRS canonical allele examples
- `scv/` - SCV statement examples (pathogenicity, oncogenicity, somatic, etc.)
- `vcv/` - VCV aggregate statement examples

## SQL Stored Procedure Conventions

### Dynamic SQL with REPLACE Pattern

All stored procedures use a `DECLARE` / `SET` / `REPLACE` / `EXECUTE IMMEDIATE` pattern for dynamic SQL. This replaces the older `FORMAT("""...""", schema, ...)` approach.

```sql
DECLARE query STRING;

SET query = """
  CREATE OR REPLACE TABLE {S}.my_table AS
  SELECT * FROM {S}.source_table
""";
SET query = REPLACE(query, '{S}', rec.schema_name);
EXECUTE IMMEDIATE query;
```

**Why REPLACE over FORMAT:**

- Eliminates positional `%s` parameter counting — schema references use a named `{S}` placeholder
- Eliminates `%%` double-escaping — inner `FORMAT()` calls within the SQL template use normal `%s`/`%i` syntax
- Easier to read, maintain, and debug

**Conventions:**

- Use `{S}` as the placeholder for `rec.schema_name` (the target dataset/schema)
- One `DECLARE` per query variable at the top of the procedure body
- `SET` the query string, then `REPLACE`, then `EXECUTE IMMEDIATE` — three separate statements
- For procedures that use a variable other than `rec.schema_name` (e.g., `target_schema`), adjust the REPLACE call accordingly

## Git Commit Conventions

When creating git commits or pull requests:

- Do NOT include "Generated with Claude Code" attribution lines
- Do NOT include "Co-Authored-By: Claude" lines
- Keep commit messages clean and focused on the changes
