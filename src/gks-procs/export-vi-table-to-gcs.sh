#!/bin/bash
bq extract \
  --destination_format NEWLINE_DELIMITED_JSON \
  --compression GZIP \
  'clinvar_2025_07_29_v2_3_1.variation_identity' \
  gs://clinvar-gks/2025-07-29/dev/vi.json.gz