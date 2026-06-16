# Aggregation Layer Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Layer 4 (group aggregator) from VCV/RCV pipelines, rebrand the remaining layers as a two-layer conceptual model: "Grouping Layer" (L1+L2) and "Aggregate Contribution Layer" (L3).

**Architecture:** The current 4-layer hierarchy (L1 Base → L2 Tier → L3 Submission Level → L4 Group) becomes a 2-conceptual-layer model. L1 and L2 are unified under "Grouping Layer" (separate SQL steps, single conceptual layer). L3 becomes the "Aggregate Contribution Layer" — the terminal layer for both germline and somatic. L4 is deleted entirely. Germline variants with multiple proposition types will now produce separate final statements per proposition type instead of one combined statement.

**Tech Stack:** BigQuery SQL stored procedures, MkDocs documentation (Markdown), JSONC example files

---

## Summary of Changes

### What's Removed
- **Layer 4 aggregation** (`gks_vcv_layer4_group_agg`, `gks_rcv_layer4_group_agg`) — the germline-only cross-proposition-type aggregation is eliminated
- **Layer 4 statement generation** (BASE + PRE) in both VCV and RCV statement procs
- The FINAL union changes from "germline L4 + somatic L3" to just "all L3" (no filtering needed)

### What's Renamed
| Old Name | New Conceptual Name | Table Name Change |
|----------|-------------------|-------------------|
| Layer 1 (Base Aggregator) | Grouping Layer — Base Grouping | `gks_{x}cv_layer1_base_agg` → `gks_{x}cv_grouping_base_agg` |
| Layer 2 (Tier Aggregator) | Grouping Layer — Tier Grouping | `gks_{x}cv_layer2_tier_agg` → `gks_{x}cv_grouping_tier_agg` |
| Layer 3 (Submission Level Aggregator) | Aggregate Contribution Layer | `gks_{x}cv_layer3_prop_agg` → `gks_{x}cv_aggregate_contribution` |

### Behavioral Changes
- **Germline output**: Instead of one VCV/RCV statement per `(variation, statement_group)` combining all prop types, there will be one statement per `(variation, statement_group, prop_type)` — e.g., `VCV000012582.63-G-PATH`, `VCV000012582.63-G-ASSOC`, `VCV000012582.63-G-NP` as separate final statements
- **Somatic output**: No change — somatic already terminated at L3
- **JSON nesting depth**: Drops from 4 levels to 3 levels for germline statements
- **Statement IDs**: The shortest ID format changes from `VCV.ver-G` (L4) to `VCV.ver-G-PROP` (new terminal). No more IDs without a proposition type component
- **Proposition aggregateQualifiers**: The terminal layer now always has `[AssertionGroup, PropositionType]` instead of just `[AssertionGroup]`

---

## Files Affected

### SQL Procedures (core implementation)
| File | Changes |
|------|---------|
| `src/procedures/gks-vcv-proc.sql` | Remove L4 block, rename L1/L2/L3 variables and table names, update comments |
| `src/procedures/gks-vcv-statement-proc.sql` | Remove L4 BASE+PRE blocks, rename L1/L2/L3 variables and table names, simplify FINAL union, update cleanup |
| `src/procedures/gks-rcv-proc.sql` | Remove L4 block, rename L1/L2/L3 variables and table names, update comments |
| `src/procedures/gks-rcv-statement-proc.sql` | Remove L4 BASE+PRE blocks, rename L1/L2/L3 variables and table names, simplify FINAL union, update cleanup |

### Documentation
| File | Changes |
|------|---------|
| `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` | Rewrite Layer Hierarchy section with new 2-layer model |
| `docs/pipeline/vcv-statements/vcv-proc.md` | Remove L4 steps, rename all layer references, update output tables |
| `docs/pipeline/vcv-statements/index.md` | Update pipeline flow diagram and key concepts |
| `docs/pipeline/rcv-statements/rcv-proc.md` | Remove L4 steps, rename all layer references, update output tables |
| `docs/pipeline/rcv-statements/index.md` | Update pipeline flow diagram and key concepts |
| `docs/reference/glossary.md` | Update VCV Aggregation section with new layer names |
| `docs/data-access/examples.md` | Update VCV examples table (descriptions reference layer counts) |
| `docs/output-reference/vcv-statements.md` | Rewrite Layer Hierarchy section, remove L4, update all layer references |
| `docs/output-reference/rcv-statements.md` | Rewrite Layer Hierarchy section, remove L4, update all layer references |
| `docs/pipeline/vcv-statements/vcv-extensions.md` | Rename "Layer 1" reference to "Base Grouping" |
| `docs/pipeline/rcv-statements/rcv-extensions.md` | Rename "Layer 1" and "four layers" references to new naming |

### Example Files
| File | Changes |
|------|---------|
| `examples/vcv/VCV000012582.63-G.jsonc` | **Rename to `VCV000012582.63-G-PATH.jsonc`** and replace with Aggregate Contribution terminal format |
| `examples/vcv/VCV-PG-example.jsonc` | Update layer comments |
| `examples/vcv/VCV-EP-example.jsonc` | Update layer comments |
| `examples/rcv/RCV001781420.1-G-PATH.jsonc` | **Replace entirely** with Aggregate Contribution layer terminal format |
| `examples/rcv/RCV006254391.1-S-SCI.jsonc` | Update layer comments |

---

## Chunk 1: VCV Aggregation Procedure

### Task 1: Remove Layer 4 from gks-vcv-proc.sql

**Files:**
- Modify: `src/procedures/gks-vcv-proc.sql`

- [ ] **Step 1: Remove Layer 4 DECLARE and the Layer 4 SQL block**

Remove the `DECLARE query_layer4 STRING;` declaration (line 7) and the entire Layer 4 block (lines 283-331: from `-- LAYER 4: FINAL GROUP AGGREGATOR` through `EXECUTE IMMEDIATE query_layer4;`).

- [ ] **Step 2: Rename Layer 1-3 variables and table names**

Rename throughout the file:
- `query_layer1` → `query_grouping_base`
- `query_layer2` → `query_grouping_tier`
- `query_layer3` → `query_agg_contribution`
- `gks_vcv_layer1_base_agg` → `gks_vcv_grouping_base_agg`
- `gks_vcv_layer2_tier_agg` → `gks_vcv_grouping_tier_agg`
- `gks_vcv_layer3_prop_agg` → `gks_vcv_aggregate_contribution`

- [ ] **Step 3: Update SQL comments**

Replace the section comment headers:
- `LAYER 1: MATERIALIZE BASE DATA` → `GROUPING LAYER: MATERIALIZE BASE DATA`
- `LAYER 1: BASE AGGREGATION` → `GROUPING LAYER: BASE GROUPING`
- `LAYER 2: TIER AGGREGATOR` → `GROUPING LAYER: TIER GROUPING (Somatic only)`
- `LAYER 3: SUBMISSION LEVEL AGGREGATOR` → `AGGREGATE CONTRIBUTION LAYER`

References to Layer 1/Layer 2 within the Aggregate Contribution Layer SQL (the `unified_input` CTE that unions L2 and L1) should reference the new table names only — the SQL logic itself doesn't change.

- [ ] **Step 4: Commit**

```bash
git add src/procedures/gks-vcv-proc.sql
git commit -m "Remove Layer 4 and rename layers in gks_vcv_proc"
```

---

### Task 2: Remove Layer 4 from gks-vcv-statement-proc.sql

**Files:**
- Modify: `src/procedures/gks-vcv-statement-proc.sql`

- [ ] **Step 1: Remove Layer 4 DECLARE variables**

Remove:
- `DECLARE query_layer4 STRING;` (line 6)
- `DECLARE query_l4_pre STRING;` (line 10)

- [ ] **Step 2: Remove Layer 4 from cleanup_temp_tables call**

Remove `'temp_vcv_layer4_statements'` and `'temp_vcv_layer4_pre'` from the cleanup array (lines 27-30).

- [ ] **Step 3: Remove Layer 4 BASE block**

Delete the entire Layer 4 BASE section (lines 254-325: from `-- LAYER 4: FINAL GROUP AGGREGATOR` through `EXECUTE IMMEDIATE query_layer4;`).

- [ ] **Step 4: Remove Layer 4 PRE block**

Delete the entire Layer 4 PRE section (lines 478-531: from `-- LAYER 4 PRE:` through `EXECUTE IMMEDIATE query_l4_pre;`).

- [ ] **Step 5: Simplify the FINAL union**

Replace the FINAL block. The old logic was:
```sql
SELECT * FROM temp_vcv_layer4_pre
UNION ALL
SELECT * FROM temp_vcv_layer3_pre WHERE id LIKE '%-S-%'
```

The new logic is simply:
```sql
SELECT * FROM {P}.temp_vcv_agg_contribution_pre
```

No UNION needed — the Aggregate Contribution Layer is now terminal for both germline and somatic.

- [ ] **Step 6: Remove Layer 4 DROP TABLE statements**

Remove:
- `DROP TABLE _SESSION.temp_vcv_layer4_statements;`
- `DROP TABLE _SESSION.temp_vcv_layer4_pre;`

- [ ] **Step 7: Rename all Layer 1-3 variables and table references**

Rename throughout the file:
- `query_layer1` → `query_grouping_base`
- `query_layer2` → `query_grouping_tier`
- `query_layer3` → `query_agg_contribution`
- `query_l1_pre` → `query_grouping_base_pre`
- `query_l2_pre` → `query_grouping_tier_pre`
- `query_l3_pre` → `query_agg_contribution_pre`
- `temp_vcv_layer1_statements` → `temp_vcv_grouping_base_statements`
- `temp_vcv_layer2_statements` → `temp_vcv_grouping_tier_statements`
- `temp_vcv_layer3_statements` → `temp_vcv_agg_contribution_statements`
- `temp_vcv_layer1_pre` → `temp_vcv_grouping_base_pre`
- `temp_vcv_layer2_pre` → `temp_vcv_grouping_tier_pre`
- `temp_vcv_layer3_pre` → `temp_vcv_agg_contribution_pre`
- `gks_vcv_layer1_base_agg` → `gks_vcv_grouping_base_agg`
- `gks_vcv_layer2_tier_agg` → `gks_vcv_grouping_tier_agg`
- `gks_vcv_layer3_prop_agg` → `gks_vcv_aggregate_contribution`

- [ ] **Step 8: Update SQL comment headers**

Replace section comments to match the new naming convention (same pattern as Task 1 Step 3), plus:
- `LAYER 1 PRE:` → `GROUPING BASE PRE:`
- `LAYER 2 PRE:` → `GROUPING TIER PRE:`
- `LAYER 3 PRE:` → `AGGREGATE CONTRIBUTION PRE:`
- `FINAL: Combined VCV statement pre (germline L4 + somatic L3)` → `FINAL: VCV statement pre (all Aggregate Contribution statements)`

- [ ] **Step 9: Commit**

```bash
git add src/procedures/gks-vcv-statement-proc.sql
git commit -m "Remove Layer 4 and rename layers in gks_vcv_statement_proc"
```

---

## Chunk 2: RCV Aggregation Procedure

### Task 3: Remove Layer 4 from gks-rcv-proc.sql

**Files:**
- Modify: `src/procedures/gks-rcv-proc.sql`

Same pattern as Task 1, with RCV-specific names:

- [ ] **Step 1: Remove Layer 4 DECLARE and the Layer 4 SQL block**

Remove `DECLARE query_layer4 STRING;` and the entire Layer 4 block (lines 290-338).

- [ ] **Step 2: Rename Layer 1-3 variables and table names**

- `query_layer1` → `query_grouping_base`
- `query_layer2` → `query_grouping_tier`
- `query_layer3` → `query_agg_contribution`
- `gks_rcv_layer1_base_agg` → `gks_rcv_grouping_base_agg`
- `gks_rcv_layer2_tier_agg` → `gks_rcv_grouping_tier_agg`
- `gks_rcv_layer3_prop_agg` → `gks_rcv_aggregate_contribution`

- [ ] **Step 3: Update SQL comments**

Same comment header pattern as Task 1 Step 3.

- [ ] **Step 4: Commit**

```bash
git add src/procedures/gks-rcv-proc.sql
git commit -m "Remove Layer 4 and rename layers in gks_rcv_proc"
```

---

### Task 4: Remove Layer 4 from gks-rcv-statement-proc.sql

**Files:**
- Modify: `src/procedures/gks-rcv-statement-proc.sql`

Same pattern as Task 2, with RCV-specific names:

- [ ] **Step 1: Remove Layer 4 DECLARE variables**

Remove `DECLARE query_layer4 STRING;` and `DECLARE query_l4_pre STRING;`.

- [ ] **Step 2: Remove Layer 4 from cleanup_temp_tables call**

Remove `'temp_rcv_layer4_statements'` and `'temp_rcv_layer4_pre'` from the cleanup array.

- [ ] **Step 3: Remove Layer 4 BASE block**

Delete the entire Layer 4 BASE section (lines 325-404).

- [ ] **Step 4: Remove Layer 4 PRE block**

Delete the entire Layer 4 PRE section (lines 557-610).

- [ ] **Step 5: Simplify the FINAL union**

Replace:
```sql
SELECT * FROM temp_rcv_layer4_pre
UNION ALL
SELECT * FROM temp_rcv_layer3_pre WHERE id LIKE '%-S-%'
```

With:
```sql
SELECT * FROM {P}.temp_rcv_agg_contribution_pre
```

- [ ] **Step 6: Remove Layer 4 DROP TABLE statements**

Remove:
- `DROP TABLE _SESSION.temp_rcv_layer4_statements;`
- `DROP TABLE _SESSION.temp_rcv_layer4_pre;`

- [ ] **Step 7: Rename all Layer 1-3 variables and table references**

Same pattern as Task 2 Step 7 but with `rcv` prefix.

- [ ] **Step 8: Update SQL comment headers**

Same pattern as Task 2 Step 8.

- [ ] **Step 9: Commit**

```bash
git add src/procedures/gks-rcv-statement-proc.sql
git commit -m "Remove Layer 4 and rename layers in gks_rcv_statement_proc"
```

---

## Chunk 3: Documentation Updates

### Task 5: Update VCV aggregation rules doc

**Files:**
- Modify: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md`

- [ ] **Step 1: Rewrite the Layer Hierarchy section (lines 153-169)**

Replace the "Layer Hierarchy" section with the new 2-layer model:

```markdown
## Aggregation Hierarchy

VCV aggregation builds statements through a two-layer hierarchy. Each layer may consist of multiple SQL steps, but conceptually there are two aggregation layers.

### Grouping Layer

The Grouping Layer produces the initial aggregation of individual SCVs into groups. It consists of two steps that run as separate SQL operations but form a single conceptual layer:

| Step | Name | Aggregates By | Description |
| --- | --- | --- | --- |
| Base Grouping | `gks_vcv_grouping_base_agg` | Variation + Statement Group + Proposition Type + Submission Level (+ Tier) | Lowest-level aggregation of individual SCVs. Applies submission-level-specific classification and conflict detection logic |
| Tier Grouping | `gks_vcv_grouping_tier_agg` | Variation + Statement Group + Proposition Type + Submission Level | Combines tier-level groups (somatic sci only). Ranks tiers by priority, designates top tier as contributing |

Tier Grouping applies only to somatic tiered records (`tier_grouping IS NOT NULL`). Non-tiered records (all germline and non-sci somatic) flow directly from Base Grouping to the Aggregate Contribution Layer.

### Aggregate Contribution Layer

| Step | Name | Aggregates By | Description |
| --- | --- | --- | --- |
| Aggregate Contribution | `gks_vcv_aggregate_contribution` | Variation + Statement Group + Proposition Type | Winner-takes-all across submission levels. This is the terminal layer for both germline and somatic statements |

Submission levels are ranked `PG > EP > CP > NOCP > NOCL > FLAG`. The highest-ranked submission level becomes the "contributing" result; all others become "non-contributing" evidence.

Each layer's output includes `evidenceLines` that reference the layer below, creating a nested structure in the final JSON output.
```

- [ ] **Step 2: Update any other references in the file**

Check for and update any mentions of "four-layer", "Layer 4", "L4", "Group Aggregator" elsewhere in the document.

- [ ] **Step 3: Run mkdocs build --strict to validate**

```bash
cd /Users/lbabb/Development/gks/clinvar-gks && mkdocs build --strict
```

- [ ] **Step 4: Commit**

```bash
git add docs/pipeline/vcv-statements/vcv-aggregation-rules.md
git commit -m "Update VCV aggregation rules for 2-layer model"
```

---

### Task 6: Update VCV procedures doc

**Files:**
- Modify: `docs/pipeline/vcv-statements/vcv-proc.md`

- [ ] **Step 1: Update gks_vcv_proc section**

- Change "builds aggregation tables through a four-layer hierarchy" → "builds aggregation tables through a two-layer aggregation hierarchy"
- Rename Step 2 header: "Build gks_vcv_layer1_base_agg" → "Build gks_vcv_grouping_base_agg"
- Rename Step 3 header: "Build gks_vcv_layer2_tier_agg" → "Build gks_vcv_grouping_tier_agg"
- Rename Step 4 header: "Build gks_vcv_layer3_prop_agg" → "Build gks_vcv_aggregate_contribution"
- Delete Step 5 entirely (Layer 4 section)
- Update all table name references throughout

- [ ] **Step 2: Update gks_vcv_statement_proc section**

- Change "9 sections: four BASE layers, four PRE layers" → "7 sections: three BASE steps, three PRE steps"
- Rename "Layers 1--4 BASE" → "BASE Statement Steps"
- Remove Layer 4 BASE description
- Rename Layer 1/2/3 BASE descriptions with new names
- Remove "Layer 4 PRE" section entirely
- Rename Layer 1/2/3 PRE sections with new names
- Update FINAL section: "Combines Layer 4 PRE (germline) and Layer 3 PRE (somatic)" → "Selects all Aggregate Contribution PRE statements"

- [ ] **Step 3: Update Output Tables table**

Replace all table names with new names and remove Layer 4 rows.

- [ ] **Step 4: Update Dependencies section**

Replace aggregation table references in the `gks_vcv_statement_proc` dependencies with new names.

- [ ] **Step 5: Run mkdocs build --strict**

- [ ] **Step 6: Commit**

```bash
git add docs/pipeline/vcv-statements/vcv-proc.md
git commit -m "Update VCV procedures doc for 2-layer model"
```

---

### Task 7: Update VCV index page

**Files:**
- Modify: `docs/pipeline/vcv-statements/index.md`

- [ ] **Step 1: Update key concepts and pipeline flow diagram**

Replace "Four-layer hierarchy — L1 (base) through L4 (group)" with description of the two-layer model.

Update the pipeline flow diagram:
```text
SCV Statements (gks_scv_statement_pre)
         │
         ▼
┌──────────────────────────────────┐
│  gks_vcv_proc                    │
│  Grouping: Base                  │  Group by variation + group + prop + level [+ tier]
│  Grouping: Tier                  │  Aggregate tiers within level (somatic only)
│  Aggregate Contribution          │  Winner-takes-all across submission levels
└───────────────┬──────────────────┘
                │
                ▼
┌──────────────────────────────────┐
│  gks_vcv_statement_proc          │
│  BASE statements (3 steps)       │  Build statement structures from agg tables
│  PRE: inline evidence (3 steps)  │  Propagate evidence through layers
│  FINAL: select all               │  All Aggregate Contribution statements
└───────────────┬──────────────────┘
                │
                ▼
         gks_vcv_statement_pre
```

- [ ] **Step 2: Run mkdocs build --strict**

- [ ] **Step 3: Commit**

```bash
git add docs/pipeline/vcv-statements/index.md
git commit -m "Update VCV index page for 2-layer model"
```

---

### Task 8: Update RCV procedures doc

**Files:**
- Modify: `docs/pipeline/rcv-statements/rcv-proc.md`

- [ ] **Step 1: Apply same changes as Task 6 but for RCV**

Same pattern as Task 6. Key differences:
- Table names use `rcv` prefix
- Partition key is `rcv_accession` not `variation_id`
- RCV has condition data resolution step (unchanged, but step numbering may shift)
- Layer 4 PRE and Layer 4 BASE sections reference `rcv_accession` and `trait_set_id`

Delete the entire Step 5 (Layer 4 group aggregator for RCV).

- [ ] **Step 2: Update output tables**

Replace table names and remove Layer 4 rows.

- [ ] **Step 3: Run mkdocs build --strict**

- [ ] **Step 4: Commit**

```bash
git add docs/pipeline/rcv-statements/rcv-proc.md
git commit -m "Update RCV procedures doc for 2-layer model"
```

---

### Task 9: Update RCV index page

**Files:**
- Modify: `docs/pipeline/rcv-statements/index.md`

- [ ] **Step 1: Apply same changes as Task 7 but for RCV**

Update the pipeline flow diagram and key concepts to match the 2-layer model.

- [ ] **Step 2: Run mkdocs build --strict**

- [ ] **Step 3: Commit**

```bash
git add docs/pipeline/rcv-statements/index.md
git commit -m "Update RCV index page for 2-layer model"
```

---

### Task 10: Update glossary

**Files:**
- Modify: `docs/reference/glossary.md`

- [ ] **Step 1: Rewrite the VCV Aggregation section (lines 173-203)**

Replace Layer 1-4 definitions with:

```markdown
**Grouping Layer**
:   First conceptual aggregation layer. Consists of Base Grouping and Tier Grouping steps. Produces initial aggregation of SCVs into groups by submission level.

**Base Grouping** (Grouping Layer)
:   First step of the Grouping Layer. Groups SCVs by variation + statement group + proposition type + submission level [+ tier]. Applies submission-level-specific classification and conflict detection logic.

**Tier Grouping** (Grouping Layer)
:   Second step of the Grouping Layer (somatic sci only). Aggregates tier-level groups within each submission level.

**Aggregate Contribution Layer**
:   Second and final aggregation layer. Applies winner-takes-all ranking across submission levels. Terminal layer for both germline and somatic statements.
```

Remove definitions for "Layer 4 (Statement Group)" and "Tier Grouping" (replaced by the above).

- [ ] **Step 2: Run mkdocs build --strict**

- [ ] **Step 3: Commit**

```bash
git add docs/reference/glossary.md
git commit -m "Update glossary for 2-layer aggregation model"
```

---

### Task 11: Update output reference docs

**Files:**
- Modify: `docs/output-reference/vcv-statements.md`
- Modify: `docs/output-reference/rcv-statements.md`
- Modify: `docs/pipeline/vcv-statements/vcv-extensions.md`
- Modify: `docs/pipeline/rcv-statements/rcv-extensions.md`

- [ ] **Step 1: Rewrite Layer Hierarchy in vcv-statements.md (output-reference)**

Replace the "Layer Hierarchy" section (lines 107-120) with the new 2-layer model:
- Remove L4 row from the table
- Change "4-layer aggregation hierarchy" to "2-layer"
- Update "L4 for germline, L3 for somatic" (line 97) to "Aggregate Contribution Layer is the top level for both germline and somatic"
- Rename L1/L2/L3 references to new names

- [ ] **Step 2: Rewrite Layer Hierarchy in rcv-statements.md (output-reference)**

Same changes as Step 1, applied to the RCV version (lines 176-187):
- Remove L4 row, update "same 4-layer" to "same 2-layer"
- Remove "Germline RCV statements use Layer 4 as the top level"

- [ ] **Step 3: Update vcv-extensions.md**

Change "Present only at Layer 1 for somatic clinical impact propositions" (line 108) to "Present only at the Base Grouping step for somatic clinical impact propositions".

- [ ] **Step 4: Update rcv-extensions.md**

Change "Present only at Layer 1 for somatic clinical impact propositions" (line 141) to "Present only at the Base Grouping step for somatic clinical impact propositions".
Change "all four layers" (line 102) to "all aggregation steps".

- [ ] **Step 5: Run mkdocs build --strict**

- [ ] **Step 6: Commit**

```bash
git add docs/output-reference/ docs/pipeline/vcv-statements/vcv-extensions.md docs/pipeline/rcv-statements/rcv-extensions.md
git commit -m "Update output reference and extension docs for 2-layer model"
```

---

## Chunk 4: Example File Updates

### Task 12: Rename and rewrite VCV germline example

**Files:**
- Delete: `examples/vcv/VCV000012582.63-G.jsonc`
- Create: `examples/vcv/VCV000012582.63-G-PATH.jsonc`

- [ ] **Step 1: Rename VCV000012582.63-G.jsonc to VCV000012582.63-G-PATH.jsonc**

```bash
git mv examples/vcv/VCV000012582.63-G.jsonc examples/vcv/VCV000012582.63-G-PATH.jsonc
```

The old filename (`-G`) matched the L4 group aggregator ID format which no longer exists. The new filename (`-G-PATH`) matches the Aggregate Contribution Layer ID format.

- [ ] **Step 2: Replace file content with Aggregate Contribution Layer format**

The new structure is the content of what is currently the first nested evidence item (the L3 PATH statement) extracted as the top-level object. It should have:
- ID: `VCV000012582.63-G-PATH`
- `aggregateQualifiers: [AssertionGroup: "Germline", PropositionType: "Pathogenicity"]`
- Contributing evidence: the CP-level Base Grouping statement (`VCV000012582.63-G-PATH-CP`)
- Non-contributing evidence: the NOCP-level Base Grouping statement (`VCV000012582.63-G-PATH-NOCP`)
- Top comment: `// Aggregate Contribution Layer — Germline Pathogenicity`

The JSON structure is already present in the current file as the first `evidenceItems[0]` of the first `evidenceLines[0]`. Extract it and update comments.

- [ ] **Step 3: Commit**

```bash
git add examples/vcv/
git commit -m "Rename and rewrite VCV germline example for 2-layer model"
```

---

### Task 13: Update VCV PG/EP example comments

**Files:**
- Modify: `examples/vcv/VCV-PG-example.jsonc`
- Modify: `examples/vcv/VCV-EP-example.jsonc`

- [ ] **Step 1: Update layer comments in PG/EP examples**

In each file, update comment references:
- "Layer 1 Base" → "Grouping Layer — Base Grouping"
- "Layer 3" → "Aggregate Contribution Layer"

- [ ] **Step 2: Commit**

```bash
git add examples/vcv/VCV-PG-example.jsonc examples/vcv/VCV-EP-example.jsonc
git commit -m "Update VCV PG/EP example comments for 2-layer model"
```

---

### Task 14: Update RCV example files

**Files:**
- Modify: `examples/rcv/RCV001781420.1-G-PATH.jsonc` (structural rewrite)
- Modify: `examples/rcv/RCV006254391.1-S-SCI.jsonc` (comment updates)

- [ ] **Step 1: Rewrite RCV001781420.1-G-PATH.jsonc**

This file currently shows the L4 group aggregator output (comment says "RCV Layer 4 (Terminal for germline)"). Replace with the Aggregate Contribution Layer terminal format — the content of what is currently the L3 statement nested inside it.

The new top-level should have `aggregateQualifiers: [AssertionGroup, PropositionType]` and ID format `RCV001781420.1-G-PATH`. Top comment: `// Aggregate Contribution Layer — Germline Pathogenicity`.

- [ ] **Step 2: Update layer comments in somatic example**

In `RCV006254391.1-S-SCI.jsonc`, update:
- "RCV Layer 3 (Terminal for somatic)" → "Aggregate Contribution Layer"
- "Layer 2 (tier aggregator)" → "Grouping Layer — Tier Grouping"
- "Layer 1" → "Grouping Layer — Base Grouping"

- [ ] **Step 3: Commit**

```bash
git add examples/rcv/
git commit -m "Update RCV example files for 2-layer model"
```

---

### Task 15: Update examples doc references

**Files:**
- Modify: `docs/data-access/examples.md`

- [ ] **Step 1: Update VCV examples table**

Update descriptions that reference layer counts:
- Germline row: update filename reference from `VCV000012582.63-G.jsonc` to `VCV000012582.63-G-PATH.jsonc`, change description from "Full 4-layer germline hierarchy (L4→L3→L1)" to describe the new Aggregate Contribution terminal format
- `VCV000012582.63-S-sci.jsonc`: Change "3-layer somatic hierarchy (L3→L2→L1)" to use new naming (Aggregate Contribution → Grouping Tier → Grouping Base)
- `VCV000012582.63-S-onco.jsonc`: Change "(L3→L1)" to use new naming
- Update PG/EP descriptions that mention "Layer 1" or "Layer 3"

- [ ] **Step 2: Run mkdocs build --strict**

- [ ] **Step 3: Commit**

```bash
git add docs/data-access/examples.md
git commit -m "Update examples doc for 2-layer model"
```

---

## Chunk 5: Validation

### Task 16: Final validation

- [ ] **Step 1: Run mkdocs build --strict**

```bash
cd /Users/lbabb/Development/gks/clinvar-gks && mkdocs build --strict
```

Verify no broken links or build errors.

- [ ] **Step 2: Grep for stale references**

Search entire codebase for any remaining references to old names:

```bash
grep -rn -E "layer[1-4]|Layer [1-4]|\bL[1-4]\b|four.layer|4.layer|layer1_base_agg|layer2_tier_agg|layer3_prop_agg|layer4_group_agg" \
  --include="*.sql" --include="*.md" --include="*.jsonc" \
  src/ docs/ examples/
```

Any hits (excluding `archive/` and `docs/superpowers/plans/`) indicate missed renames.

- [ ] **Step 3: Verify SQL consistency**

For each of the 4 SQL procedures, verify:

1. All DECLARE'd variables are used
2. All table names in CREATE match table names in subsequent references
3. No dangling references to removed Layer 4 tables
4. The cleanup_temp_tables arrays match the temp tables actually created

- [ ] **Step 4: Commit any fixes and final commit**

```bash
git add -A
git commit -m "Final validation fixes for aggregation layer refactor"
```
