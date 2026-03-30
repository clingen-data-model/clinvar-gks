# Merge Condition Procedures Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `gks_trait_proc`, `gks_scv_condition_mapping_proc`, and `gks_scv_condition_sets_proc` into a single procedure `gks_scv_condition_proc` in a new file `gks-scv-condition-proc.sql`.

**Architecture:** The three procedures execute sequentially and share intermediate tables. Merging them eliminates inter-procedure persistent tables (`gks_trait` and `gks_scv_trait_sets`) by converting them to temp tables. Two output tables must remain persistent: `gks_scv_condition_mapping` (consumed by `gks_vcv_proc`) and `gks_scv_condition_sets` (consumed by `gks_scv_proposition_proc`). The merged procedure reorders so traits run first (needed by condition sets), then condition mapping (13 steps), then condition sets.

**Tech Stack:** BigQuery SQL stored procedures, dynamic SQL with `DECLARE`/`SET`/`REPLACE`/`EXECUTE IMMEDIATE` pattern.

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `src/procedures/gks-scv-condition-proc.sql` | Merged procedure combining all three |
| Delete | `src/procedures/gks-trait-proc.sql` | Replaced by merged procedure |
| Delete | `src/procedures/gks-scv-condition-mapping-proc.sql` | Replaced by merged procedure |
| Delete | `src/procedures/gks-scv-condition-set-proc.sql` | Replaced by merged procedure |
| Modify | `src/procedures/readme.md` | Update CALL statements |
| Modify | `src/scripts/vrs-to-bq-table.sh` | Update CALL statements |
| Modify | `docs/pipeline/index.md` | Consolidate steps 4/5/6 into one step |
| Modify | `docs/pipeline/conditions-and-traits/index.md` | Update procedure references |
| Modify | `docs/pipeline/conditions-and-traits/condition-mapping.md` | Update procedure name and step numbers |
| Modify | `docs/pipeline/conditions-and-traits/traits.md` | Update procedure name, table role, dependencies |
| Modify | `docs/pipeline/conditions-and-traits/condition-sets.md` | Update procedure name, table roles, dependencies |

---

## Chunk 1: Create the Merged Procedure

### Task 1: Create `gks-scv-condition-proc.sql` with merged content

**Files:**
- Create: `src/procedures/gks-scv-condition-proc.sql`

The merged procedure has 15 steps total:
- Step 1: `gks_trait` (from `gks_trait_proc`) — now a temp table `_SESSION.temp_gks_trait`
- Steps 2-3: Prepare trait mappings and RCV mapping traits (old steps 1-2 from condition mapping)
- Step 4: `gks_scv_trait_sets` — now a temp table `_SESSION.temp_gks_scv_trait_sets`
- Steps 5-14: Remaining condition mapping steps (old steps 4-13)
- Step 15: `gks_scv_condition_sets` (from `gks_scv_condition_sets_proc`) — remains persistent

**Key changes from the source procedures:**

1. **`gks_trait` becomes `_SESSION.temp_gks_trait`** — only consumed within this procedure now (by the condition sets step)
2. **`gks_scv_trait_sets` becomes `_SESSION.temp_gks_scv_trait_sets`** — only consumed within this procedure now (by condition sets step and internal condition mapping steps)
3. **`gks_scv_condition_mapping` stays persistent** — consumed downstream by `gks_vcv_proc`
4. **`gks_scv_condition_sets` stays persistent** — consumed downstream by `gks_scv_proposition_proc`
5. **New DECLARE variables:** `temp_gks_trait_query` and `query_condition_sets`
6. **All `_SESSION.temp_*` tables get explicit DROP statements** before `END FOR`
7. **References to `{S}.gks_trait`** in the condition sets query become `_SESSION.temp_gks_trait`
8. **References to `{S}.gks_scv_trait_sets`** become `_SESSION.temp_gks_scv_trait_sets` throughout

- [ ] **Step 1: Create the merged procedure file**

Create `src/procedures/gks-scv-condition-proc.sql` with the following structure:

```sql
CREATE OR REPLACE PROCEDURE `clinvar_ingest.gks_scv_condition_proc`(on_date DATE)
BEGIN
  -- DECLARE all query variables (15 + drops)
  DECLARE temp_gks_trait_query STRING;
  DECLARE temp_normalized_trait_mappings_query STRING;
  DECLARE temp_rcv_mapping_traits_query STRING;
  DECLARE temp_gks_scv_trait_sets_query STRING;
  DECLARE temp_all_rcv_traits_query STRING;
  DECLARE temp_normalized_traits_query STRING;
  DECLARE temp_scv_trait_name_xrefs_query STRING;
  DECLARE temp_all_scv_traits_query STRING;
  DECLARE temp_all_mapped_scv_traits_query STRING;
  DECLARE temp_rcv_trait_assignment_stage1_query STRING;
  DECLARE temp_rcv_trait_assignment_stage2_query STRING;
  DECLARE temp_rcv_trait_assignment_stage3_query STRING;
  DECLARE temp_rcv_trait_assignment_stage4_query STRING;
  DECLARE gks_scv_condition_mapping_query STRING;
  DECLARE query_condition_sets STRING;

  FOR rec IN (select s.schema_name FROM clinvar_ingest.schema_on(on_date) as s)
  DO

    -- Step 1: Create temp_gks_trait (from gks_trait_proc)
    -- ... gks_trait query body, but CREATE TEMP TABLE _SESSION.temp_gks_trait ...

    -- Step 2: Create temp_normalized_trait_mappings (old step 1)
    -- ... unchanged from condition mapping proc ...

    -- Step 3: Create temp_rcv_mapping_traits (old step 2)
    -- ... unchanged ...

    -- Step 4: Create temp_gks_scv_trait_sets (old step 3 — was gks_scv_trait_sets)
    -- ... same query but CREATE TEMP TABLE _SESSION.temp_gks_scv_trait_sets ...

    -- Steps 5-14: (old steps 4-13 from condition mapping)
    -- ... all unchanged except:
    --   - References to `{S}.gks_scv_trait_sets` → `_SESSION.temp_gks_scv_trait_sets`
    --   - Step 14 (gks_scv_condition_mapping) stays as CREATE OR REPLACE TABLE `{S}.gks_scv_condition_mapping`

    -- Step 15: Create gks_scv_condition_sets (from condition sets proc)
    -- ... same query but:
    --   - `{S}.gks_trait` → `_SESSION.temp_gks_trait`
    --   - `{S}.gks_scv_trait_sets` → `_SESSION.temp_gks_scv_trait_sets`
    --   - `{S}.gks_scv_condition_mapping` stays as-is (persistent)

    -- DROP all temp tables
    DROP TABLE IF EXISTS _SESSION.temp_gks_trait;
    DROP TABLE IF EXISTS _SESSION.temp_normalized_trait_mappings;
    DROP TABLE IF EXISTS _SESSION.temp_rcv_mapping_traits;
    DROP TABLE IF EXISTS _SESSION.temp_gks_scv_trait_sets;
    DROP TABLE IF EXISTS _SESSION.temp_all_rcv_traits;
    DROP TABLE IF EXISTS _SESSION.temp_normalized_traits;
    DROP TABLE IF EXISTS _SESSION.temp_scv_trait_name_xrefs;
    DROP TABLE IF EXISTS _SESSION.temp_all_scv_traits;
    DROP TABLE IF EXISTS _SESSION.temp_all_mapped_scv_traits;
    DROP TABLE IF EXISTS _SESSION.temp_rcv_trait_assignment_stage1;
    DROP TABLE IF EXISTS _SESSION.temp_rcv_trait_assignment_stage2;
    DROP TABLE IF EXISTS _SESSION.temp_rcv_trait_assignment_stage3;
    DROP TABLE IF EXISTS _SESSION.temp_rcv_trait_assignment_stage4;

  END FOR;

END;
```

Specific changes to copy from source files:

**Step 1 (trait):** Copy the query from `gks-trait-proc.sql` lines 11-134. Change:
- `CREATE OR REPLACE TABLE \`{S}.gks_trait\`` → `CREATE TEMP TABLE _SESSION.temp_gks_trait`
- Variable name: `gks_trait_query` → `temp_gks_trait_query`

**Step 4 (trait sets):** In the condition mapping proc's step 3 query. Change:
- `CREATE OR REPLACE TABLE \`{S}.gks_scv_trait_sets\`` → `CREATE TEMP TABLE _SESSION.temp_gks_scv_trait_sets`
- Variable name: `gks_scv_trait_sets_query` → `temp_gks_scv_trait_sets_query`

**Steps 5-14:** Copy from condition mapping proc steps 4-13. In all queries that reference `{S}.gks_scv_trait_sets`, replace with `_SESSION.temp_gks_scv_trait_sets`. This affects:
- Step 5 (temp_all_rcv_traits) — references `gks_scv_trait_sets`
- Step 8 (temp_all_scv_traits) — references `gks_scv_trait_sets`

**Step 15 (condition sets):** Copy from `gks-scv-condition-set-proc.sql` lines 10-161. Change:
- `\`{S}.gks_trait\`` → `_SESSION.temp_gks_trait`
- `\`{S}.gks_scv_trait_sets\`` → `_SESSION.temp_gks_scv_trait_sets`
- `\`{S}.gks_scv_condition_mapping\`` stays unchanged (persistent table)

- [ ] **Step 2: Verify the file structure**

Manually review the new file to confirm:
- 15 DECLARE statements (one per step query variable)
- Correct step numbering in comments (1-15)
- `_SESSION.temp_gks_trait` and `_SESSION.temp_gks_scv_trait_sets` used consistently
- `gks_scv_condition_mapping` and `gks_scv_condition_sets` remain as persistent `{S}.` tables
- All 13 DROP statements present before `END FOR`
- No references to the old procedure names

- [ ] **Step 3: Commit**

```bash
git add src/procedures/gks-scv-condition-proc.sql
git commit -m "Add merged gks_scv_condition_proc combining trait, condition mapping, and condition set procedures"
```

---

## Chunk 2: Delete Old Procedure Files

### Task 2: Remove the three source procedure files

**Files:**
- Delete: `src/procedures/gks-trait-proc.sql`
- Delete: `src/procedures/gks-scv-condition-mapping-proc.sql`
- Delete: `src/procedures/gks-scv-condition-set-proc.sql`

- [ ] **Step 1: Delete the three files**

```bash
git rm src/procedures/gks-trait-proc.sql
git rm src/procedures/gks-scv-condition-mapping-proc.sql
git rm src/procedures/gks-scv-condition-set-proc.sql
```

- [ ] **Step 2: Commit**

```bash
git commit -m "Remove individual condition procedure files replaced by gks_scv_condition_proc"
```

---

## Chunk 3: Update Script and Readme References

### Task 3: Update `readme.md` and `vrs-to-bq-table.sh`

**Files:**
- Modify: `src/procedures/readme.md`
- Modify: `src/scripts/vrs-to-bq-table.sh`

- [ ] **Step 1: Update `src/procedures/readme.md`**

Replace the three separate CALL statements (lines 88-94):
```sql
-- create the condition mappings from the traits and rcv_mapping entries
CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());

-- create the gks_trait entries
CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());

-- create the condition set  entries
CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());
```

With:
```sql
-- create the conditions, traits, condition mappings, and condition sets
CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE());
```

Also update the comment block near line 14-16 (the original 3 CALL lines):
```sql
-- CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());
-- CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());
```
Replace with:
```sql
-- CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE());
```

- [ ] **Step 2: Update `src/scripts/vrs-to-bq-table.sh`**

Replace the three procedure names (lines 54-56):
```bash
  'clinvar_ingest.gks_scv_condition_mapping_proc'
  'clinvar_ingest.gks_trait_proc'
  'clinvar_ingest.gks_scv_condition_sets_proc'
```

With single entry:
```bash
  'clinvar_ingest.gks_scv_condition_proc'
```

- [ ] **Step 3: Commit**

```bash
git add src/procedures/readme.md src/scripts/vrs-to-bq-table.sh
git commit -m "Update procedure references to use merged gks_scv_condition_proc"
```

---

## Chunk 4: Update Documentation

### Task 4: Update pipeline docs to reflect the merged procedure

**Files:**
- Modify: `docs/pipeline/index.md`
- Modify: `docs/pipeline/conditions-and-traits/index.md`
- Modify: `docs/pipeline/conditions-and-traits/condition-mapping.md`
- Modify: `docs/pipeline/conditions-and-traits/traits.md`
- Modify: `docs/pipeline/conditions-and-traits/condition-sets.md`

- [ ] **Step 1: Update `docs/pipeline/index.md`**

Consolidate steps 4/5/6 in the ASCII diagram into a single step 4. Renumber subsequent steps (7→5, 8→6, 9→7). Update the CALL statements block.

Replace the three separate boxes (lines 28-44):
```
┌──────────────▼───────────────┐
│ 4. Condition Mapping         │  gks_scv_condition_mapping_proc
│    Map traits & conditions   │  → condition mapping tables
│    between SCVs and RCVs     │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 5. Traits                    │  gks_trait_proc
│    Generate normalized       │  → gks_trait table
│    trait records              │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ 6. Condition Sets            │  gks_scv_condition_sets_proc
│    Build submitted           │  → condition set tables
│    condition sets            │
└──────────────┬───────────────┘
```

With:
```
┌──────────────▼───────────────┐
│ 4. Conditions & Traits       │  gks_scv_condition_proc
│    Map traits, build         │  → condition mapping & set tables
│    conditions & condition    │
│    sets                      │
└──────────────┬───────────────┘
```

Renumber remaining steps: SCV Records (5), SCV Propositions (6), SCV Statements (7), Export (8).

Replace the CALL statements (lines 91-93):
```sql
CALL `clinvar_ingest.gks_scv_condition_mapping_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_trait_proc`(CURRENT_DATE());
CALL `clinvar_ingest.gks_scv_condition_sets_proc`(CURRENT_DATE());
```

With:
```sql
CALL `clinvar_ingest.gks_scv_condition_proc`(CURRENT_DATE());
```

- [ ] **Step 2: Update `docs/pipeline/conditions-and-traits/index.md`**

Update the overview to reference the single procedure. Replace the three-procedure description (lines 7-11):
```
1. **Condition Mapping** (`gks_scv_condition_mapping_proc`) — ...
2. **Traits** (`gks_trait_proc`) — ...
3. **Condition Sets** (`gks_scv_condition_sets_proc`) — ...
```

With description of the single merged procedure `gks_scv_condition_proc` that executes traits first, then condition mapping, then condition sets.

Update the Pipeline Flow diagram to show a single procedure box. Update internal table references:
- `gks_trait` → `temp_gks_trait` (Internal)
- `gks_scv_trait_sets` → `temp_gks_scv_trait_sets` (Internal)

- [ ] **Step 3: Update `docs/pipeline/conditions-and-traits/traits.md`**

- Change procedure name in title and overview from `gks_trait_proc` to `gks_scv_condition_proc`
- Note this is now Step 1 of the merged procedure
- Change output table role from `Pipeline table` to `Internal` (now `_SESSION.temp_gks_trait`)
- Update Output Tables section: `gks_trait` → `temp_gks_trait` with Internal badge
- Update downstream consumer: `gks_scv_condition_sets_proc` → `gks_scv_condition_proc` (internal)

- [ ] **Step 4: Update `docs/pipeline/conditions-and-traits/condition-mapping.md`**

- Change procedure name in title and overview from `gks_scv_condition_mapping_proc` to `gks_scv_condition_proc`
- Note these are Steps 2-14 of the merged procedure
- Update step numbers (old 1-13 → new 2-14)
- In Output Tables: `gks_scv_trait_sets` → `temp_gks_scv_trait_sets` with Internal badge
- Update dependencies: add `trait` to source tables (via the trait step), update downstream consumers

- [ ] **Step 5: Update `docs/pipeline/conditions-and-traits/condition-sets.md`**

- Change procedure name from `gks_scv_condition_sets_proc` to `gks_scv_condition_proc`
- Note this is Step 15 of the merged procedure
- Update source table references: `gks_trait` → `temp_gks_trait`, `gks_scv_trait_sets` → `temp_gks_scv_trait_sets`
- Update upstream procedures: `gks_scv_condition_mapping_proc, gks_trait_proc` → `gks_scv_condition_proc` (internal steps)

- [ ] **Step 6: Commit**

```bash
git add docs/pipeline/index.md docs/pipeline/conditions-and-traits/index.md \
  docs/pipeline/conditions-and-traits/condition-mapping.md \
  docs/pipeline/conditions-and-traits/traits.md \
  docs/pipeline/conditions-and-traits/condition-sets.md
git commit -m "Update documentation for merged gks_scv_condition_proc procedure"
```

---

## Summary of Table Changes

| Old Table | New Table | Old Role | New Role | Reason |
|-----------|-----------|----------|----------|--------|
| `gks_trait` | `_SESSION.temp_gks_trait` | Pipeline | Internal | Only consumed by condition sets (now internal step) |
| `gks_scv_trait_sets` | `_SESSION.temp_gks_scv_trait_sets` | Pipeline | Internal | Only consumed by condition mapping/sets (now internal steps) |
| `gks_scv_condition_mapping` | `gks_scv_condition_mapping` | Pipeline | Pipeline | Consumed by `gks_vcv_proc` — must stay persistent |
| `gks_scv_condition_sets` | `gks_scv_condition_sets` | Pipeline | Pipeline | Consumed by `gks_scv_proposition_proc` — must stay persistent |
