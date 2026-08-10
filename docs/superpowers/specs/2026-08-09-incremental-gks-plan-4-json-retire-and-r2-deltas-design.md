# Plan 4 — `gks_json` retirement + R2 delta publishing + bundle JSON cleanup — Design

> **Status:** design (approved in brainstorming 2026-08-09). Fourth and final plan of the
> incremental-GKS initiative. Builds on the parent design
> `docs/superpowers/specs/2026-08-06-incremental-gks-downstream-and-deltas-design.md` (§4 delta
> product & R2, §5 version gate) and Plans 1–3 (PRs #74/#75/#76). All BigQuery work is on
> project **`clingen-dev`**; branch `feat/incremental-gks-json-r2delta-plan4` (off the Plan 3 branch).

## Context correction (supersedes the parent handoff's Plan-4 framing)

The parent handoff framed Plan 4-A as "make `gks_json_proc` incremental." Investigation of the
**live** publish path shows `gks_json_proc` is **vestigial**:

- The published bundle is assembled from the **`gks_dict_*` tables** by
  `export-gks-dicts.sh` → `assemble-gks-dicts.py` (`SECTIONS` = dict tables). Those dicts are
  already incremental (Plans 1–3) and already have `delta_<dict>` payloads (`gks_delta_build`).
- `gks_json_proc`'s four outputs (`gks_catvar`, `gks_scv_statement`, `gks_rcv_statement`,
  `gks_vcv_statement`) are referenced **only** by the archived `src/scripts/archive/export-gks-files-to-gcs.sh`.
  They are still built every release and tracked in `gks_change_log`, but never published and never
  given a delta payload (`gks_delta_build` excludes them). They are **fully-inlined** records (all
  `#/...` references resolved) — a form judged less useful than the compact, pointer-referenced bundle.
- Confirmed with the user (2026-08-09): **no live consumer** of the `gks_json` outputs.

Consequently Plan 4-A becomes **retire `gks_json` from the incremental hot path** (not "make it
incremental"), and the substantive work is the R2 delta product (Plan 4-B) plus a bundle
JSON-cleanup gap surfaced during the review (Plan 4-C).

## Scope — three coupled pieces

- **(A)** Retire `gks_json_proc` from the incremental hot path.
- **(B)** Publish per-release **delta** artifacts to R2 weekly; publish the **full** bundle only at
  month-end. Consumer model: *last monthly full + replay contiguous weekly deltas*.
- **(C)** Give the published JSON bundle the same null/empty cleanup `gks_json` performed
  (`JSON_STRIP_NULLS(remove_empty => TRUE)` parity) — done in the assemble layer.

---

## (A) Retire `gks_json` from the hot path

Mechanical and **internally coupled** (the two edits must land together):

1. Remove the `gks_json_proc` call from `src/scripts/vrs-to-bq-table.sh` (the step between the
   rcv/vcv procs and `gks_change_log`).
2. Remove the four JSON-render outputs — `gks_catvar`, `gks_scv_statement`, `gks_rcv_statement`,
   `gks_vcv_statement` — from `gks_change_log`'s `tracked` array
   (`src/procedures/gks-change-log-proc.sql`), and redeploy the proc.
   **Coupling rationale:** once `gks_json_proc` stops running, those four tables are not
   (re)created in the current release's dataset, so `gks_change_log` would error at analysis time
   trying to diff a non-existent `{S}.<table>`. They are already absent from `gks_delta_build`'s
   `tables` array, so no delta-side change is needed.
3. Leave `src/procedures/gks-json-proc.sql` on disk (the archived export still references its
   outputs). Correct the stale step-8 description in `docs/pipeline/index.md`
   (it currently claims `gks_json_proc` "Build dictionary tables → gks_dict_* tables", which it
   does not — the dicts are built by the upstream catvar/scv/rcv/vcv procs).

**Correctness gate:** a full pipeline run completes end-to-end, and `gks_change_log` no longer
references the four dropped tables (no missing-table analysis error).

---

## (B) R2 delta publishing

No new BigQuery compute: `gks_delta_build` already materializes `{S}.delta_<dict>` (A∪U rows, same
schema as each dict) and `gks_change_log` already holds the A/U/D manifest slice. Plan 4-B is an
**export + publish layer** over those tables.

### Section mapping (mirror the bundle)

Delta files use the **same sections** as the full bundle (`assemble-gks-dicts.py` `SECTIONS`), so a
consumer applies `delta[section]` onto `bundle[section]` by key with an identical contract. The two
merged sections union their per-table deltas:

| Bundle section | Delta source table(s) | key |
|---|---|---|
| `sequenceReference` | `delta_gks_dict_sequence_reference` | key |
| `location` | `delta_gks_dict_location` | key |
| `allele` | `delta_gks_dict_allele` | key |
| `copyNumberCount` | `delta_gks_dict_copy_number_count` | key |
| `copyNumberChange` | `delta_gks_dict_copy_number_change` | key |
| `gene` | `delta_gks_dict_gene` | key |
| `variation` | `delta_gks_dict_variation` | id |
| `condition` | `delta_gks_dict_condition` | id |
| `conditionSet` | `delta_gks_dict_condition_set` | id |
| `submitter` | `delta_gks_dict_submitter` | key |
| `proposition` | `delta_gks_dict_proposition` ∪ `delta_gks_dict_vcv_proposition` ∪ `delta_gks_dict_rcv_proposition` | key |
| `evidenceLine` | `delta_gks_dict_evidence_line` ∪ `delta_gks_dict_vcv_evidence_line` ∪ `delta_gks_dict_rcv_evidence_line` | id |
| `scv` | `delta_gks_dict_scv` | id |
| `vcv` | `delta_gks_dict_vcv` | id |
| `rcv` | `delta_gks_dict_rcv` | id |

The merged sections are already handled at assemble time — `assemble-gks-dicts.py` lists
`proposition`/`evidenceLine` as a list of globs — so the delta export just needs to write each
delta table's shards under the **same section basename** the full export uses.

### Weekly run (every release) — delta only

1. **Export** `delta_<table>` → GCS as NDJSON + Parquet, sharded under the section basename. A
   `--delta` mode added to `export-gks-dicts.sh`. The typed-Parquet path (`parquet-schemas/*.sql`,
   run via `EXPORT DATA`) must be parameterizable by **table name** (currently only `{DATASET}` is
   substituted) so it can target `delta_<table>` instead of `<table>` while keeping the same typed
   columns/section basename.
2. **Assemble** the delta NDJSON → one `clinvar-gks-delta_YYYY-MMDD.json.gz` (reuse
   `assemble-gks-dicts.py` unchanged apart from the (C) cleanup — same section structure, A∪U rows).
3. **Merge** delta Parquet shards → per-section `{section}.parquet` (same shard-merge as
   `release-gks.sh` step 3).
4. **Build `manifest.json`** from the `gks_change_log` slice (new small builder — a `bq query` →
   JSON, or a Python step reading the exported change-log rows).
5. **Upload** the delta bundle + per-section Parquet + `manifest.json` to `deltas/YYYY-MMDD/` and
   refresh `deltas/00-latest/`; extend `index.json` with a `deltas` list.

### Month-end run (last release of the month) — full

On the last release of the month, assemble the **full** bundle from that release's always-built
dicts and upload it directly to the monthly slot (`datasets/` + `datasets/00-latest`). This replaces
the current `promote_monthly` (which copied a weekly full file — there is no weekly full file any
more). Weekly releases publish **no** full bundle and do **not** write `datasets/weekly/`.

The full table is still **built in BigQuery every release** (next release's carry-forward baseline);
only the R2 *publish* cadence changes. "Last release of the month" is detected the same way
`upload-gks-to-r2.sh` already detects month boundaries (compare the release month against the most
recent published release's month).

### R2 layout

```
datasets/                                   # monthly full bundles (unchanged) + 00-latest
datasets/parquet/<section>.parquet          # monthly full Parquet (unchanged)
archives/<yyyy>/                            # prior-year monthly (unchanged)
deltas/<YYYY-MMDD>/
    clinvar-gks-delta_<YYYY-MMDD>.json.gz   # assembled delta bundle (A∪U rows)
    manifest.json
    parquet/<section>.parquet               # per-section delta Parquet
deltas/00-latest/                           # copy of the newest delta dir
index.json                                  # extended: datasets + archives + deltas
```

`datasets/weekly/` is retired for full bundles (deltas take its weekly role). Any existing
`datasets/weekly/*` handling in `upload-gks-to-r2.sh` (promotion source, cleanup) is removed or
repointed as part of the cadence change.

### `manifest.json` shape

```json
{
  "release": "2026-07-20",
  "baseline_release": "2026-07-15",
  "compare_release": "2026-07-20",
  "pipeline_version": "<audit stamp from {S}.gks_pipeline_version>",
  "checkpoint_full": { "path": "datasets/clinvar-gks_2026-07.json.gz", "release": "2026-07-27" },
  "sections": {
    "variation": { "added": 13975, "updated": 3273, "deleted": ["clinvar:12345", "..."] },
    "vcv":       { "added": 42,    "updated": 1180, "deleted": [] }
  },
  "counts": { "A": 0, "U": 0, "D": 0 }
}
```

- `baseline_release` is `null` on the first release (everything is `A`; the delta equals the full
  set — a consumer bootstraps from a monthly full and does not need the first-ever delta).
- Deletes (`D`) are pk lists per section and live **only** in the manifest (they are not payload
  rows). A∪U keys are the payload; the manifest carries per-section **counts**, not the full A/U key
  lists (those are derivable from the payload files).
- `checkpoint_full` names the monthly full this delta chain roots at, so a fallen-behind consumer
  knows which full to re-bootstrap from.

### Consumer model & chain integrity

Take the **last monthly full**, then **replay the contiguous weekly deltas since**, applying each:
delete the section's `deleted` keys, then upsert every key present in the section payload. A gap is
detected when `delta[i].baseline_release != delta[i-1].compare_release` (or the earliest delta's
`baseline_release` predates the checkpoint full's release) → the consumer must re-bootstrap from a
monthly full. The `baseline_release`/`compare_release` stamps make the chain self-verifying.

### Orchestration wiring

- `export-gks-dicts.sh` — `--delta` mode (export `delta_<table>` with table-parameterized typed
  Parquet).
- `assemble-gks-dicts.py` — reused for the delta bundle (different output name / source dir); gains
  the (C) cleanup.
- New manifest builder — `gks_change_log` slice → `manifest.json`.
- `upload-gks-to-r2.sh` (or a delta-specific companion) — delta tree + `index.json` `deltas` list +
  the cadence change (full only at month-end; no weekly full).
- `release-gks.sh` — cadence-aware: weekly → delta path; month-end → full path. `run-release.sh`
  Stage 5 calls it as today.

### Correctness gate — delta-reconstruction oracle (THE gate for the delta product)

For a tested release pair, prove `baseline dicts − D + upsert(delta A∪U) == current full dicts`,
per section, via the canonical-row multiset compare (`clinvar_ingest.gks_oracle_compare`, the
3-arg dup-safe compare used throughout the initiative). Concretely: materialize a reconstructed
dict = `(baseline_dict WHERE key NOT IN manifest.deleted[section]) UNION ALL delta_<table>`, then
`gks_oracle_compare(reconstructed, current_full_dict)` must be `(0,0,0)`. Run on the standard test
pair (baseline `2026-07-15`, compare `2026-07-20`). Clean up `*_recon` scratch datasets when done.

---

## (C) Bundle JSON cleanup (parity with `gks_json`)

**Gap (confirmed empirically 2026-08-09):** the bundle already drops NULL scalar fields (BQ NDJSON
export omits them), but the structured id-passthrough sections (`variation`, `scv`, `vcv`, `rcv`,
`condition`, `conditionSet`, `evidenceLine`) retain **empty arrays/objects** that `gks_json`'s
`JSON_STRIP_NULLS(remove_empty => TRUE)` strips. Example real `gks_dict_vcv` row:
`"classification":{"conceptType":"Classification","name":"Benign","extensions":[]}` — the
`"extensions":[]` survives. The KV-dict sections are already fully clean (their build applies
`JSON_STRIP_NULLS(remove_empty => TRUE)`).

**Fix:** add a recursive strip in `assemble-gks-dicts.py` that removes `null`, empty array `[]`, and
empty object `{}` values (recursively, so an object that becomes empty after stripping is itself
removed), applied to **both** the full and delta JSON bundles. Semantics match
`JSON_STRIP_NULLS(remove_empty => TRUE)`.

- Applies to the passthrough sections; **idempotent** on the already-clean KV sections.
- **JSON bundle only** — the typed Parquet exports keep their columnar form (empty repeated fields
  are schema-valid there).
- The cost lands on the **monthly** full assembly (weekly is delta-only), so the extra per-record
  parse/strip/re-serialize is affordable. This does mean `stream_passthrough`'s current
  raw-line-passthrough optimization is replaced by parse → strip → re-serialize for passthrough
  sections.
- Purely a publish-layer transform — the BQ tables, change-log, deltas, and the (B)
  reconstruction oracle all operate on the pre-cleanup tables, so cleanup is **orthogonal** to
  incremental correctness. Expect a **one-time content change** in the first cleaned bundle.

**Correctness gate:** unit-test the strip (drop null, `[]`, `{}`, nested-becomes-empty, idempotence
on clean input, and that non-empty values/`0`/`false`/`""` are preserved); scan a cleaned bundle for
residual null/empty values.

---

## Build order (phasing) — oracle each phase

1. **(A) retire** — remove the call + change-log tracking; redeploy `gks_change_log`; verify a full
   run and change-log build succeed.
2. **(C) cleanup** — recursive strip in `assemble-gks-dicts.py` + unit tests (independent of BQ;
   land early so both the full and delta assembly use it).
3. **(B) delta export + assemble + manifest** — `--delta` export mode, delta assembly, manifest
   builder; gate on the delta-reconstruction oracle `(0,0,0)`.
4. **(B) cadence + upload + index** — month-end-only full, delta tree upload, `index.json` `deltas`
   list; `release-gks.sh`/`run-release.sh` wiring; dry-run against R2.
5. **Docs** — update `docs/` (mkdocs) for the delta product and the retired `gks_json` step;
   `mkdocs build --strict`; use the `write-docs` skill.

---

## Out of scope

- Deleting `gks-json-proc.sql` (kept for the archived export).
- Parquet empty-value cleanup (typed columnar form retained).
- The `variation_archive_classification` `dataset_diff` SKIP and the config-data-only gate residuals
  (parent handoff "Known residuals"; unchanged here).

## Open items to resolve during planning

- **Typed-Parquet table parameterization:** confirm the cleanest way to point `parquet-schemas/*.sql`
  at `delta_<table>` (a `{TABLE}`/prefix substitution vs a per-delta schema variant).
- **Manifest builder host:** `bq query` → JSON vs a Python step over the exported change-log NDJSON.
- **Delta `00-latest` shape:** a full copy of the newest delta dir vs a pointer file; decide during
  planning for `index.json` ergonomics.
- **`upload-gks-to-r2.sh` refactor extent:** parameterize the existing script for the delta tree +
  cadence vs a delta-specific companion script — pick the lower-risk option given the weekly-full
  removal touches its promotion/cleanup paths.
