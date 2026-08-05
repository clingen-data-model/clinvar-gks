# Incremental variation_identity v2 (UNION-CTAS) — Design Plan

> **Status:** design. Supersedes the abandoned `2026-08-03-incremental-variation-identity.md` (DELETE+INSERT, mappings bug). This v2 corrects the merge primitive and the mappings handling, and is justified by a cost analysis that the earlier attempt got wrong.

**Goal:** Rebuild `variation_identity` (+ `variation_loc`/`variation_hgvs`/`variation_xref`) incrementally — run the heavy per-variation parsing only for the variations that changed since the prior release, and carry the rest forward — cutting execution cost ~70× on a weekly release.

## Why this one (and why it was wrongly dismissed)

The first cut judged incremental by **wall-clock** (~2.5 min, which BigQuery parallelizes) and concluded "not worth it." The cost that actually scales with volume is **execution: bytes processed / slot-time**. Measured on clingen-dev:

| Proc | Compute (GB/run) | Output size (GB) | Incremental verdict |
|---|---|---|---|
| **variation_identity** | **124** (up to ~6 TB cold) | **0.83** | **~70× win** |
| gks_catvar_proc | 25 | 9.5 | marginal (~1.3×) |
| gks_scv_statement | 27 | 13.8 | ~break-even |
| gks_rcv/vcv_statement | 12.8 / 10.1 | 4.4 / 3.6 | modest (~1.4–1.5×) |

`variation_identity` parses 124 GB of ClinVar `content` blobs (`parseHGVS`, `parseSequenceLocations`, `parseXRefs`, SPDI) into an **0.83 GB** output. The cost model: **incremental wins ⟺ full-compute > ~2 × output size** (the carry-forward floor = read+write the unchanged output once). `variation_identity` clears that by ~70×; the output-heavy downstream procs don't (carrying their large JSON output forward ≈ recomputing it), so they stay full rebuilds for now.

## Architecture

Three ideas, all different from v1:

**1. Recompute only the changed set (heavy parse), same as v1's Step-1 filter.**
Changed variations = `diff_variation` (new/modified) ∪ copy-number cascade (any changed `clinical_assertion_variation` / `clinical_assertion` participating in the Step-1 `cn` join, resolved via **both** the compare `{S}` and baseline `{base}` snapshots). Materialize `{P}.changed_variation_ids` + `{P}.removed_variation_ids`. Step 1's `var` CTE is filtered to the changed set, so Steps 1–7 parse only those.

**2. Merge via UNION-CTAS, NOT DELETE+INSERT.**
For each of the four outputs `X`:
```sql
CREATE OR REPLACE TABLE `{S}.X` AS
  SELECT * FROM `{base}.X`
  WHERE variation_id NOT IN (SELECT variation_id FROM {P}.changed_variation_ids
                             UNION DISTINCT SELECT variation_id FROM {P}.removed_variation_ids)
  UNION ALL
  SELECT * FROM {P}.stg_X   -- freshly parsed changed rows
```
This avoids the scattered-row `DELETE` rewrite penalty that made v1 slower than a full rebuild. Floor cost = read+write the output once; for `variation_identity`'s 0.83 GB output that's negligible against the 124 GB parse it skips. (Use explicit column lists, not `SELECT *`, so a schema/column-order drift errors instead of silently corrupting — the version-invalidation signal.)

**3. Compute `mappings` GLOBALLY — this both fixes the v1 bug and keeps the win.**
The v1 oracle caught a real bug: `variation_identity.mappings` for variation X are sourced from `variation_xref` rows keyed on the **external** xref id (`x.id`), which may belong to *other* variations — a cross-variation dependency that per-variation staging drops. Resolution: **mappings is a cheap join (no UDFs), so compute it globally over the complete merged `{S}.variation_xref` for all variations, after the merge** — while the expensive per-variation parsing stays incremental. This solves the correctness trap without having to model a mappings cascade in the changed set, and adds negligible cost (a join, not a re-parse).

Concretely: Step 8 builds the per-variation `variation_identity` core (everything except `mappings`) into staging for the changed set; after the UNION merge of the core, a final global step recomputes `mappings` from `{S}.variation_xref` and attaches it to every row (cheap join over the small xref table).

## Correctness gates (non-negotiable)
- **Full-vs-incremental oracle** on the clean same-version 7-15/7-20 pair: keyed by `variation_id` + `TO_JSON_STRING` compared with `clinvar_ingest.canonicalize_json` (arrays are non-groupable and the transform has `ROW_NUMBER` tie-break non-determinism, so raw `EXCEPT *` gives false positives). Must be 0 semantic diffs. This is the check that caught the v1 mappings bug.
- **id-set validation** already exists downstream (`gks_catvar_proc`) and will catch any dropped/duplicated variation that reaches catvar.
- **Version-invalidation gate:** carry-forward assumes the prior release was built by the same `variation_identity` transform. If the proc changed, full rebuild. Exposed as a non-breaking wrapper (`variation_identity` full + `variation_identity_incremental`), since BQ has no overloading/default-params.

## Tasks
1. Baseline resolution + full-rebuild fallback guard (baseline exists, four `{base}` tables present, `diff_*` present + `baseline_release`/`compare_release` consistent). Non-breaking wrapper structure.
2. Changed / removed set builder (variation + copy-number CAV/CA cascade, both snapshots). Verify counts against the diff tables.
3. Step-1 changed-set filter; Steps 2–8 write per-variation results to `{P}.stg_*` (parse only the changed set).
4. UNION-CTAS merge of the four outputs (explicit column lists).
5. Global `mappings` recompute from the merged `{S}.variation_xref`.
6. **Oracle**: rebuild 7-20 both ways (full vs incremental from the fresh 7-15), assert 0 canonical diffs across all four tables; also confirm the id-set validation passes.
7. Measure the actual execution-cost delta (bytes/slot) full vs incremental to confirm the ~70× on real data.

## Out of scope
The downstream output-heavy procs (`gks_catvar`, SCV/RCV/VCV statements) — the cost analysis shows they're break-even-to-modest, so they stay full rebuilds unless a future need (or a cheaper carry-forward) changes the math.

## Future enhancement considerations

**Realized result (2026-08-05):** the incremental measured **~9× slot-time** (23,005 → 2,533 slot-sec) and **~2.1× bytes** (115.5 → 54.5 GB), with a modest **~17% wall-clock** improvement (2m49s → 2m20s) — a strong cost win and a small speed win, but **not the ~70×** the estimate projected. The 70× counted only `variation_identity`'s 0.83 GB output; the incremental must also carry forward `variation_loc` (9M rows) and especially **`variation_hgvs` (41.8M rows)**, so the UNION-CTAS floor is 2× the sum of all four outputs, dominated by hgvs. The combined benefit metric should weight slot-cost highest but keep wall-clock (faster is better) in the qualified conclusion.

### 1. Cluster the output tables by `variation_id` (the real lever past ~9×)

UNION-CTAS is the optimal *merge primitive* for the current storage layout — it reads+writes each table exactly once, which beats DELETE+INSERT (scattered-row rewrite of ~every block for a 0.38% random change set, the penalty that made v1 slower). But its floor is a **full read+write of every carried-forward table**, and `variation_hgvs` (41.8M rows) is the dominant residual cost.

The lever to go below that floor: **cluster the four output tables by `variation_id`**. With changed rows co-located in a few blocks, a zero-copy `CLONE` of the baseline + a *targeted* merge (delete/insert only the changed keys) could rewrite only the blocks that actually contain changed rows instead of the whole table — potentially turning the hgvs floor from "full rewrite" into "touch a handful of blocks." This is a schema/storage change (and shifts the merge primitive from UNION-CTAS to CLONE-then-targeted-DML, which only pays off *because* of the clustering), so it was out of scope for the initial build. It is the main path to a materially bigger multiple.

### 2. Filter Step 1's copy-number `cn` scan to the changed set

Step 1 still scans `clinical_assertion_variation` (6.9M rows) with `content LIKE '%CopyNumber%'` unfiltered, even though only the changed variations survive downstream. Restricting the `cn` join to the changed set would trim part of the 54.5 GB residual. Smaller lever than clustering, but cheap and correctness-neutral.
