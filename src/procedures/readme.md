-- after a new clinvar release dataset is fully ingested do the 
-- following steps to get the GKS files created
-- 
-- 1. ask Kyle to vrsify the gs://clinvar-gks/YYYY-MM-DD/dev/vi.jsonl.gz file

-- 2. transform the vrs locations to vi compatible form for bigquery processing
--    below by running the gh:clinvar-gks/src/gks-procs/vrs-to-bq-table.sh
--    which will alter the location start/end arrays to denormalized columns
--    for inner/outer start/end attributes in order to be importable to BQ
--    and it will import them into the BQ dataset as table 'gks_vrs'

-- 3. run the following procedures below (change date arg if not the most recent release)
-- CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_scv_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_scv_proposition_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_statement_scv_proc`(CURRENT_DATE());

-- 4. export the gks files to gcs by runing gh:clinvar-gks/src/gks-procs/export-gks-files-to-gcs.sh
--    by default add these files to the gs://clingen-public/clinvar-gks/* bucket
--    with the new filename clinvar_gks_(*)_YYYY_MM_DD_v9_9_8.jsonl.gz where
--    (*) is the name of one of the 3 files.


-- Appendix. UNDER DEVELOPMENT
-- below is a work in progress to get the VCV gks data building
-- CALL `clinvar_ingest.gks_vcv_level_one_proc`(CURRENT_DATE());






# How to build the GKS SCV Statements from a ClinVar Dataset
The example steps below show how to build the GKS SCV Statements
for the `clinvar_2025_03_23_v2_3_1` dataset in the `ClinGen Dev` GCP project

## STEP 1
From BQ Console (NOTE: this example assumes CURRENT_DATE() will resolve to the 2025-03-23 clinvar release)

```
CALL `clinvar_ingest.variation_identity_proc`(CURRENT_DATE());
```

## STEP 2
From a terminal

```
bq extract \
  --destination_format NEWLINE_DELIMITED_JSON \
  --compression GZIP \
  'clinvar_2025_03_23_v2_3_1.variation_identity' \
  gs://clinvar-gks/2025-03-23/dev/vi.json.gz
```

## STEP 3

TODO: doc instructions on how to do this... for now
  ask TONeill to run vrs-python and put output back in same bucket

## STEP 4

run the bash script in the clinvar-ingest-bq-tools github project below
after editing it to ingest the correct bucket name and project

```
clinvar-ingest-bq-tools/gks-procs/create_gks_vrs_table.sh
``` 

This script will create the `gks_vrs` table in the `clinvar_2025_03_23_v2_3_1` dataset

verify in the bq console with the following:

```
select * from `clingen-dev.clinvar_2025_03_23_v2_3_1.gks_vrs` limit 100
```

## STEP 5 
From the BQ console

```
-- create the catvar entries and all the upstream supporting tables
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE());

-- create the condition mappings from the traits and rcv_mapping entries
CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());

-- create the gks_trait entries
CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());

-- create the condition set  entries
CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());

-- create the scv entries
CALL `clinvar_ingest.gks_scv_proc`(CURRENT_DATE());

-- create the scv proposition entries
CALL `clinvar_ingest.gks_scv_proposition_proc`(CURRENT_DATE());

-- complete the creation of all final GKS SCV Statements for the release
CALL `clinvar_ingest.gks_statement_scv_proc`(CURRENT_DATE());



```



