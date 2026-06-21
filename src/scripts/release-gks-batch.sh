#!/bin/bash

# Batch release: run release-gks.sh for multiple dates with the same version.
#
# Usage:
#   ./release-gks-batch.sh <dataset_version> [release-gks flags...]
#
# Examples:
#   ./release-gks-batch.sh v2_5_0
#   ./release-gks-batch.sh v2_5_0 --keep-source
#   ./release-gks-batch.sh v2_5_0 --dry-run

set -e

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <dataset_version> [release-gks flags...]"
  exit 1
fi

DATASET_VERSION="$1"
shift

DATES=(
  2026-05-30
  2026-06-06
  2026-06-14
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL=${#DATES[@]}
FAILED=()

for i in "${!DATES[@]}"; do
  date="${DATES[$i]}"
  n=$((i + 1))
  echo ""
  echo "######################################################"
  echo "# Release ${n}/${TOTAL}: ${date}  (${DATASET_VERSION})"
  echo "######################################################"
  echo ""

  if "${SCRIPT_DIR}/release-gks.sh" "${date}" "${DATASET_VERSION}" "$@"; then
    echo ""
    echo ">>> ${date} completed successfully."
  else
    echo ""
    echo ">>> ${date} FAILED."
    FAILED+=("${date}")
  fi
done

echo ""
echo "======================================================"
echo "Batch complete: ${TOTAL} releases processed."
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED (${#FAILED[@]}): ${FAILED[*]}"
  exit 1
else
  echo "All releases succeeded."
fi
