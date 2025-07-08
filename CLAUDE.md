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

- `/src/gks-procs/` - Core BigQuery stored procedures and shell scripts
- `/examples/` - JSONC files showing target data structures (Cat-VRS, VA-Spec)
- `/notes/` and `/scratch/` - Development documentation and experimental work

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
./src/gks-procs/create_gks_vrs_table.sh
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

Check `/examples/` directory for JSONC files demonstrating:
- Cat-VRS canonical allele format (`cat-vrs-canonical-allele-ex01.jsonc`)
- VA-Spec statement structures
- Custom clinical profiles (drug response, etc.)