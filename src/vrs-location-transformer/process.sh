#!/bin/bash

# Exit on error and on pipeline failure
set -e -o pipefail

# --- Argument Check ---
if [ "$#" -ne 2 ];
    then
    echo "Usage: $0 <input_gcs_uri> <output_gcs_uri>"
    exit 1
fi

INPUT_GCS_URI="$1"
OUTPUT_GCS_URI="$2"

# --- JQ Filter ---
JQ_FILTER='
if (.out.location.start | type == "array") and (.out.location.start | length == 2) then
    .out.location.start_outer = .out.location.start[0] |
    .out.location.start_inner = .out.location.start[1] |
    del(.out.location.start)
else
    .
end |
if (.out.location.end | type == "array") and (.out.location.end | length == 2) then
    .out.location.end_inner = .out.location.end[0] |
    .out.location.end_outer = .out.location.end[1] |
    del(.out.location.end)
else
    .
end
'

# --- Execution ---
echo "➡️  Starting processing..."
echo "    Input:  $INPUT_GCS_URI"
echo "    Output: $OUTPUT_GCS_URI"

gcloud storage cat "$INPUT_GCS_URI" | \
    gunzip -c | \
    jq -c "$JQ_FILTER" | \
    gzip -c | \
    gcloud storage cp - "$OUTPUT_GCS_URI"

echo "✅ Success! Output written to '$OUTPUT_GCS_URI'"