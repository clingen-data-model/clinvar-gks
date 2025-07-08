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
-- create the minimal vrs sequence reference annotated vrs structure
CALL `clinvar_ingest.gks_vrs_seqref_proc`(CURRENT_DATE());

-- create the minimal vrs sequence location annotated vrs structure
CALL `clinvar_ingest.gks_vrs_seqloc_proc`(CURRENT_DATE());

-- create the preliminary catvrs data
CALL `clinvar_ingest.gks_catvar_proc`(CURRENT_DATE());



```



