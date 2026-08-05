#!/bin/bash
#
# vrsify.sh — run ClinVar VRS-ification for a release date, from this repo.
#
# Vendored + adapted from clinvar-gk-python `misc/clinvar-vrsification`. The heavy
# engine (the `clinvar_gk_pilot` package that wraps vrs-python + variation-normalizer)
# is installed as a PINNED dependency (see requirements.txt), not forked here.
#
# This is the one pipeline stage that cannot run in BigQuery: it resolves each
# variation's expression into a GA4GH VRS object against local SeqRepo / UTA /
# gene-normalizer services. It reads the export produced by
# export-vi-table-to-gcs.sh and writes the VRS output back to GCS for
# vrs-to-bq-table.sh to load.
#
#   in :  gs://clinvar-gks/<date>/dev/vi.jsonl.gz
#   out:  gs://clinvar-gks/<date>/dev/vi-normalized-no-liftover.jsonl.gz
#
# PREREQUISITES (see README.md for full setup): a Python env with the pinned
# requirements installed, the variation-normalizer service topology running, and
# these environment variables exported:
#   SEQREPO_ROOT_DIR, SEQREPO_DATAPROXY_URL, HGVS_SEQREPO_DIR, GENE_NORM_DB_URL
#   (UTA_DB_URL only when running with liftover — not the default path)
#
# USAGE:
#   ./src/vrsify/vrsify.sh YYYY-MM-DD
#
# ENV OVERRIDES:
#   PARALLELISM   worker parallelism passed to the resolver (default 2)
#   VRSIFY_CMD    resolver invocation (default "clinvar-gk-pilot"); set to
#                 e.g. "uv run python clinvar_gk_pilot/main.py" to run from a checkout
#   PROJECT_ID    GCP project (default clingen-dev) — only used for logging parity
#   BUCKET_NAME   GCS bucket (default clinvar-gks)

set -o errexit
set -o nounset
set -o pipefail

PROJECT_ID="${PROJECT_ID:-clingen-dev}"
BUCKET_NAME="${BUCKET_NAME:-clinvar-gks}"
PARALLELISM="${PARALLELISM:-2}"
VRSIFY_CMD="${VRSIFY_CMD:-clinvar-gk-pilot}"

DATE="${1:?Usage: $0 YYYY-MM-DD}"

# Fake AWS credentials so boto3 targets the local endpoint instead of real AWS.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-DUMMYIDEXAMPLE}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-DUMMYEXAMPLEKEY}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

# Fail fast if the SeqRepo / gene-norm service contract is not configured, rather
# than letting the resolver silently fall back to slow NCBI eutils lookups.
missing=()
for v in SEQREPO_ROOT_DIR SEQREPO_DATAPROXY_URL HGVS_SEQREPO_DIR GENE_NORM_DB_URL; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done
if (( ${#missing[@]} > 0 )); then
  echo "ERROR: required environment variables are not set: ${missing[*]}" >&2
  echo "       See src/vrsify/README.md for the SeqRepo/UTA/gene-norm setup." >&2
  exit 1
fi

bucket_root="${BUCKET_NAME}/${DATE}/dev"
gs_prefix="gs://${bucket_root}"
input_file="${gs_prefix}/vi.jsonl.gz"
log_file="${DATE}-noliftover.log"

echo "vrsify: project=${PROJECT_ID} input=${input_file} parallelism=${PARALLELISM}"

# shellcheck disable=SC2086  # VRSIFY_CMD may intentionally be a multi-word command
${VRSIFY_CMD} \
  --filename "${input_file}" \
  --parallelism "${PARALLELISM}" 2>&1 \
  | tee "${log_file}"

# The resolver writes its output under output/buckets/<gs-path-without-scheme>/.
outfile="output/buckets/${bucket_root}/vi.jsonl.gz"
dest_path="${gs_prefix}/vi-normalized-no-liftover.jsonl.gz"

if [[ ! -f "${outfile}" ]]; then
  echo "ERROR: expected resolver output not found: ${outfile}" >&2
  exit 1
fi

gcloud storage cp "${outfile}" "${dest_path}"
echo "vrsify: wrote ${dest_path}"
