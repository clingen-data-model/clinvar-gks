# VRS-ification (`src/vrsify/`)

The one ClinVar-GKS pipeline stage that does not run in BigQuery. It resolves each
variation's selected expression (SPDI / HGVS / gnomAD) into a GA4GH VRS object using
[vrs-python](https://github.com/ga4gh/vrs-python) + the
[variation-normalizer](https://github.com/cancervariants/variation-normalization),
against local SeqRepo / UTA / gene-normalizer services.

It sits between `export-vi-table-to-gcs.sh` (which produces the input) and
`vrs-to-bq-table.sh` (which loads the output), and is invoked as step 3 of
`src/scripts/run-release.sh`.

```
gs://clinvar-gks/<date>/dev/vi.jsonl.gz
        │  vrsify.sh
        ▼
gs://clinvar-gks/<date>/dev/vi-normalized-no-liftover.jsonl.gz
```

## What is vendored here

- **`vrsify.sh`** — the driver (adapted from clinvar-gk-python `misc/clinvar-vrsification`).
- **`requirements.txt`** — the resolver engine (`clinvar_gk_pilot`) pinned to an exact commit.

The heavy engine is installed as a **pinned dependency**, not forked into this repo — so
the resolver stack (`ga4gh.vrs`, `variation-normalizer`, `gene-normalizer`, `cool-seq-tool`)
stays authoritative upstream while the pin makes the version explicit and reproducible.

## Prerequisites (one-time)

The resolver needs a Python environment and a running service topology. These are heavy
local dependencies (multi-GB sequence data, a Postgres UTA instance); they are **not**
provisioned by this repo.

1. **Python env** (Python ≥ 3.11):

   ```bash
   python3 -m venv .venv-vrsify && source .venv-vrsify/bin/activate
   pip install -r src/vrsify/requirements.txt
   ```

2. **SeqRepo** — a local SeqRepo snapshot (the pin was validated against `2024-12-20`).

3. **variation-normalizer services** — UTA (Postgres) and gene-normalizer, typically via the
   upstream `variation-normalizer-compose.yaml`:

   ```bash
   podman compose -f variation-normalizer-compose.yaml up -d   # or: docker compose ...
   ```

   See the [clinvar-gk-python README](https://github.com/clingen-data-model/clinvar-gk-python)
   for first-time UTA volume initialization.

4. **Environment variables** (exported in the shell that runs `vrsify.sh`):

   ```bash
   export SEQREPO_ROOT_DIR=/usr/local/share/seqrepo/2024-12-20
   export SEQREPO_DATAPROXY_URL="seqrepo+file://${SEQREPO_ROOT_DIR}"
   export HGVS_SEQREPO_DIR="${SEQREPO_ROOT_DIR}"   # keeps hgvs off slow NCBI eutils
   export GENE_NORM_DB_URL=http://localhost:8000
   # only for the liftover path (not the default):
   # export UTA_DB_URL=postgresql://anonymous:anonymous@localhost:5434/uta/uta_20241220
   ```

   `vrsify.sh` fails fast if the first four are unset.

## Run

```bash
./src/vrsify/vrsify.sh YYYY-MM-DD
```

Env overrides: `PARALLELISM` (default 2); `VRSIFY_CMD` (default `clinvar-gk-pilot`; set to
`"uv run python clinvar_gk_pilot/main.py"` to run from an upstream checkout instead of the
installed console script).

## Version-invalidation

The resolver version is an input to the incremental pipeline: `gks_vrs` carry-forward assumes
unchanged variations were vrsified by the **same** resolver. **After bumping the pin in
`requirements.txt`, run the next release with `run-release.sh … --full`** so every variation is
re-resolved and `gks_vrs` is fully reseeded. See
[docs/pipeline/vrs-processing.md](../../docs/pipeline/vrs-processing.md).
