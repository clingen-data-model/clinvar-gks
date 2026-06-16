# Replace temp_normalized_traits with gks_traits Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the `temp_normalized_traits` temp table by using the already-computed persistent `gks_traits` table directly in the downstream assignment stages.

**Architecture:** `gks_traits` (Step 1) and `temp_normalized_traits` (Step 5) both represent the same canonical trait data — trait IDs, names, types, MedGen IDs, and cross-reference IDs — but structured differently. `gks_traits` stores xrefs as a structured `mappings` array (`ARRAY<STRUCT<coding STRUCT<code, system, ...>, relation>>`) with MedGen in `primaryCoding`, while `temp_normalized_traits` uses flat arrays (`omim_ids`, `hp_ids`, etc.). The downstream consumers (Steps 10 and 11) can use `gks_traits` directly by UNNEST-ing the `mappings` array with system filters, eliminating the intermediate temp table and its deduplication logic.

**Tech Stack:** BigQuery SQL stored procedures

---

## Analysis: Schema Mapping

### temp_normalized_traits columns → gks_traits equivalents

| temp_normalized_traits | gks_traits equivalent |
|---|---|
| `trait_id` | `trait_id` |
| `trait_name` | `name` |
| `trait_type` | `conceptType` |
| `medgen_id` | `primaryCoding.code` |
| `omim_ids` (ARRAY) | `UNNEST(mappings) WHERE coding.system = 'OMIM'` → `.coding.code` |
| `hp_ids` (ARRAY) | `UNNEST(mappings) WHERE coding.system = 'Human Phenotype Ontology'` → `.coding.code` |
| `mondo_ids` (ARRAY) | `UNNEST(mappings) WHERE coding.system = 'MONDO'` → `.coding.code` |
| `orphanet_ids` (ARRAY) | `UNNEST(mappings) WHERE coding.system = 'Orphanet'` → `.coding.code` |
| `mesh_ids` (ARRAY) | `UNNEST(mappings) WHERE coding.system IN ('MeSH', 'MSH')` → `.coding.code` |
| `alternate_names` (ARRAY) | `SPLIT((SELECT e.value_string FROM UNNEST(extensions) e WHERE e.name = 'aliases'), ', ')` |

### Key differences to be aware of

1. **Data source**: `gks_traits` reads from `{S}.trait` (canonical). `temp_normalized_traits` reads from `temp_all_rcv_traits` (parsed RCV mapping XML). Same underlying traits, different parsing paths.

2. **Scope**: `gks_traits` includes ALL traits. `temp_normalized_traits` only includes traits referenced by at least one RCV mapping. For rogue matching (Step 11), this means `gks_traits` may match against additional traits — which is acceptable and potentially improves coverage.

3. **Deduplication**: `temp_normalized_traits` has complex dedup logic (keeping the record with more lookup values per `trait_id`). `gks_traits` already has one canonical record per `trait_id` via GROUP BY — no dedup needed.

4. **IRI template filter**: `gks_traits` xrefs only include entries that have matching IRI templates in `clinvar_ingest.gks_xref_iri_templates`. All standard systems (MedGen, OMIM MIM, HP primary, MONDO, Orphanet, MeSH) have templates, so coverage is equivalent. `gks_traits` actually includes additional systems (EFO, GeneReviews, SNOMED CT, etc.).

5. **Alternate names**: Stored as comma-separated string in `gks_traits.extensions` vs proper ARRAY in `temp_normalized_traits`. The round-trip SPLIT on `, ` is safe for medical condition names.

---

## Chunk 1: Rewrite downstream consumers and remove temp_normalized_traits

### Task 1: Rewrite Step 10 (rcv_trait_assignment_stage3) to use gks_traits

**Files:**
- Modify: `src/procedures/gks-scv-condition-proc.sql` (Step 10, the `rcv_trait_direct_assignment` CTE)

The 6 UNION ALL branches in `rcv_trait_direct_assignment` each join `temp_normalized_traits nt ON nt.trait_id = art.trait_id` then UNNEST a specific xref array. Replace each with a join to `gks_traits` and UNNEST of `mappings` filtered by system.

- [ ] **Step 1: Replace the medgen_id branch**

Current:
```sql
JOIN {P}.temp_normalized_traits nt
  ON nt.trait_id = art.trait_id
WHERE
  ust.medgen_id = art.medgen_id
```

Replace with:
```sql
JOIN `{S}.gks_traits` gt
  ON gt.trait_id = art.trait_id
WHERE
  ust.medgen_id = art.medgen_id
```

And update the SELECT to use `gt.trait_id`, `gt.name as trait_name`, `gt.conceptType as trait_type`, `gt.primaryCoding.code as trait_medgen_id`.

- [ ] **Step 2: Replace the omim_id branch**

Current:
```sql
JOIN {P}.temp_normalized_traits nt ON nt.trait_id = art.trait_id
CROSS JOIN UNNEST(nt.omim_ids) as omim_id
WHERE ust.omim_id = omim_id
```

Replace with:
```sql
JOIN `{S}.gks_traits` gt ON gt.trait_id = art.trait_id
CROSS JOIN UNNEST(gt.mappings) as m
WHERE m.coding.system = 'OMIM' AND ust.omim_id = m.coding.code
```

And update SELECT: `gt.trait_id`, `gt.name`, `gt.conceptType`, `gt.primaryCoding.code`.

- [ ] **Step 3: Replace the hp_id branch**

Same pattern. Filter: `m.coding.system = 'Human Phenotype Ontology'`. Match: `ust.hp_id = m.coding.code`.

- [ ] **Step 4: Replace the mondo_id branch**

Filter: `m.coding.system = 'MONDO'`. Match: `ust.mondo_id = m.coding.code`.

- [ ] **Step 5: Replace the orphanet_id branch**

Filter: `m.coding.system = 'Orphanet'`. Match: `ust.orphanet_id = m.coding.code`.

- [ ] **Step 6: Replace the mesh_id branch**

Filter: `m.coding.system IN ('MeSH', 'MSH')`. Match: `ust.mesh_id = m.coding.code`.

---

### Task 2: Rewrite Step 11 (rcv_trait_assignment_stage4) nt_lookup CTE to use gks_traits

**Files:**
- Modify: `src/procedures/gks-scv-condition-proc.sql` (Step 11, the `nt_lookup` CTE)

The `nt_lookup` CTE explodes `temp_normalized_traits` into 8 priority-based rows per trait. Rewrite each UNION ALL branch to source from `gks_traits`.

- [ ] **Step 1: Replace priority 1 (omim_ids)**

Current:
```sql
SELECT trait_id, trait_name, trait_type, medgen_id as trait_medgen_id,
  'rcv-scv rogue trait omim_id' as assign_type, 1 as priority, LOWER(xref_val) as match_value
FROM {P}.temp_normalized_traits, UNNEST(omim_ids) as xref_val
```

Replace with:
```sql
SELECT gt.trait_id, gt.name as trait_name, gt.conceptType as trait_type, gt.primaryCoding.code as trait_medgen_id,
  'rcv-scv rogue trait omim_id' as assign_type, 1 as priority, LOWER(m.coding.code) as match_value
FROM `{S}.gks_traits` gt, UNNEST(gt.mappings) as m
WHERE m.coding.system = 'OMIM'
```

- [ ] **Step 2: Replace priority 2 (hp_ids)**

Same pattern. Filter: `m.coding.system = 'Human Phenotype Ontology'`. Assign type: `'rcv-scv rogue trait hp_id'`.

- [ ] **Step 3: Replace priority 3 (orphanet_ids)**

Filter: `m.coding.system = 'Orphanet'`. Assign type: `'rcv-scv rogue trait orphanet_id'`.

- [ ] **Step 4: Replace priority 4 (mondo_ids)**

Filter: `m.coding.system = 'MONDO'`. Assign type: `'rcv-scv rogue trait mondo_id'`.

- [ ] **Step 5: Replace priority 5 (mesh_ids)**

Filter: `m.coding.system IN ('MeSH', 'MSH')`. Assign type: `'rcv-scv rogue trait mesh_id'`.

- [ ] **Step 6: Replace priority 6 (trait name)**

Current:
```sql
SELECT trait_id, trait_name, trait_type, medgen_id,
  'rcv-scv rogue trait name', 6, LOWER(trait_name)
FROM {P}.temp_normalized_traits
WHERE NOT (trait_name = 'not provided' AND trait_id IN ('54780', '76440','76481','78165','78166','78167'))
```

Replace with:
```sql
SELECT gt.trait_id, gt.name, gt.conceptType, gt.primaryCoding.code,
  'rcv-scv rogue trait name', 6, LOWER(gt.name)
FROM `{S}.gks_traits` gt
WHERE NOT (gt.name = 'not provided' AND gt.trait_id IN ('54780', '76440','76481','78165','78166','78167'))
```

- [ ] **Step 7: Replace priority 7 (alternate names)**

Current:
```sql
SELECT trait_id, trait_name, trait_type, medgen_id,
  'rcv-scv rogue alternate trait name', 7, LOWER(alt_name)
FROM {P}.temp_normalized_traits, UNNEST(alternate_names) as alt_name
WHERE NOT (alt_name = 'not provided' AND trait_id IN ('54780', '76440','76481','78165','78166','78167'))
```

Replace with:
```sql
SELECT gt.trait_id, gt.name, gt.conceptType, gt.primaryCoding.code,
  'rcv-scv rogue alternate trait name', 7, LOWER(alt_name)
FROM `{S}.gks_traits` gt,
  UNNEST(
    SPLIT((SELECT e.value_string FROM UNNEST(gt.extensions) e WHERE e.name = 'aliases'), ', ')
  ) as alt_name
WHERE alt_name IS NOT NULL AND alt_name != ''
  AND NOT (alt_name = 'not provided' AND gt.trait_id IN ('54780', '76440','76481','78165','78166','78167'))
```

- [ ] **Step 8: Replace priority 8 (medgen_id fallback)**

Current:
```sql
SELECT trait_id, trait_name, trait_type, medgen_id,
  'rcv-scv rogue trait name', 8, LOWER(medgen_id)
FROM {P}.temp_normalized_traits
```

Replace with:
```sql
SELECT gt.trait_id, gt.name, gt.conceptType, gt.primaryCoding.code,
  'rcv-scv rogue trait name', 8, LOWER(gt.primaryCoding.code)
FROM `{S}.gks_traits` gt
WHERE gt.primaryCoding IS NOT NULL
```

---

### Task 3: Remove Step 5 (temp_normalized_traits) and clean up references

**Files:**
- Modify: `src/procedures/gks-scv-condition-proc.sql`

- [ ] **Step 1: Remove the DECLARE statement**

Delete: `DECLARE temp_normalized_traits_query STRING;`

- [ ] **Step 2: Remove from cleanup list**

Remove `'temp_normalized_traits'` from the `cleanup_temp_tables` call array.

- [ ] **Step 3: Remove Step 5 entirely**

Delete the entire block from `-- STEP 5: Create temp_normalized_traits` through `EXECUTE IMMEDIATE temp_normalized_traits_query;`.

- [ ] **Step 4: Remove from DROP TABLE section**

Delete: `DROP TABLE IF EXISTS _SESSION.temp_normalized_traits;`

- [ ] **Step 5: Renumber subsequent steps**

Update step comments:
- Step 6 → Step 5
- Step 7 → Step 6
- Steps 8-13 → Steps 7-12

- [ ] **Step 6: Verify no remaining references**

Run: `grep -n 'temp_normalized_traits' src/procedures/gks-scv-condition-proc.sql`

Expected: No matches.
