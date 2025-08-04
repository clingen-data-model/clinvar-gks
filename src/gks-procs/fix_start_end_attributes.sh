#!/bin/bash

# JSON Location Attribute Converter
# This script converts 2-element "start" and "end" arrays to separate inner/outer attributes

# Parse command line arguments
OVERWRITE=false

while getopts "o" opt; do
    case $opt in
        o)
            OVERWRITE=true
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

# Check if input file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 [-o] <input_file> [output_file]"
    echo "  -o: Overwrite output file if it exists (default: append)"
    echo "If output_file is not specified, results will be written to stdout"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    echo "Please install jq: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

# jq filter to convert 2-element start and end arrays to separate attributes
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

# Determine input command based on file extension
if [[ "$INPUT_FILE" == *.gz ]]; then
    INPUT_CMD="gunzip -c \"$INPUT_FILE\""
else
    INPUT_CMD="cat \"$INPUT_FILE\""
fi

# Process the file
if [ -n "$OUTPUT_FILE" ]; then
    # Check if output file exists
    if [ -f "$OUTPUT_FILE" ]; then
        if [ "$OVERWRITE" = true ]; then
            # Overwrite output file
            eval "$INPUT_CMD" | jq -c "$JQ_FILTER" > "$OUTPUT_FILE"
            echo "Processing complete. Output written to '$OUTPUT_FILE'"
        else
            # Append to output file (default)
            eval "$INPUT_CMD" | jq -c "$JQ_FILTER" >> "$OUTPUT_FILE"
            echo "Processing complete. Output appended to '$OUTPUT_FILE'"
        fi
    else
        # Write to new output file
        eval "$INPUT_CMD" | jq -c "$JQ_FILTER" > "$OUTPUT_FILE"
        echo "Processing complete. Output written to '$OUTPUT_FILE'"
    fi
else
    # Write to stdout
    eval "$INPUT_CMD" | jq -c "$JQ_FILTER"
fi