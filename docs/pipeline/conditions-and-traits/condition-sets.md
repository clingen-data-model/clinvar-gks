# Condition Sets (gks_scv_condition_sets_proc)

## Overview

The `clinvar_ingest.gks_scv_condition_sets_proc` stored procedure assembles individual conditions into structured domain entities for each SCV. SCVs with a single condition produce a `Condition` record; SCVs with multiple conditions produce a `ConditionSet` containing a `conditions` array and a `membershipOperator`. The resulting `gks_scv_condition_sets` table feeds directly into the SCV record assembly procedure (`gks_scv_proc`), where it becomes the condition component of the full SCV statement.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes as a single query with two CTEs within a loop over the target schema(s) identified by the `on_date` parameter.

### Step 1: Build Individual Condition Records

The `scv_trait` CTE joins each SCV trait from `gks_scv_condition_mapping` with its normalized trait record from `gks_trait`. For each condition, the output includes:

- **`id`** — the clinical assertion trait ID (`cat_id`)
- **`name`** — the CA trait name, falling back to the submitted trait name if the CA name is null
- **`conceptType`** — the CA trait type
- **`primaryCoding`** — from the normalized `gks_trait` record (MedGen coding)
- **`mappings`** — from the normalized `gks_trait` record (non-MedGen cross-references)
- **`extensions`** — a concatenation of trait extensions plus condition-specific extensions (see [Condition Extensions](condition-extensions.md) for full field documentation)

### Step 2: Build Condition Sets for Multi-Condition SCVs

The `scv_trait_set` CTE groups conditions by SCV ID for SCVs that have more than one condition. The grouping produces:

- **`conditions`** — an array of condition structs (id, name, conceptType, primaryCoding, mappings, extensions)
- **`membershipOperator`** — determines how multiple conditions relate to each other:
  - `AND` — when the trait relationship type is `Finding member` or `co-occurring condition`
  - `OR` — for all other relationship types

### Step 3: Assemble Final Output

The final query joins `gks_scv_trait_sets` with the condition and condition set CTEs to produce one row per SCV with two mutually exclusive fields:

**Single-condition SCVs** populate the `condition` field:

- A `Condition` struct with id, name, conceptType, primaryCoding, mappings, and extensions
- Extensions include both the individual trait extensions and the trait set extensions
- If the SCV's submitted trait set type (`cats_type`) differs from the RCV trait set type, a `submittedScvTraitSetType` extension is appended

**Multi-condition SCVs** populate the `conditionSet` field:

- A `ConditionSet` struct with the conditions array, membershipOperator, and extensions
- Extensions include the trait set extensions and the optional `submittedScvTraitSetType`

**Output:** `gks_scv_condition_sets` — one row per SCV with either a `condition` or `conditionSet` field populated. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Extensions

See [Condition Extensions](condition-extensions.md) for the complete extension reference, including all individual condition extensions and wrapper-level extensions with examples and custom structure documentation.

---

## Output Tables

| Table | Description | Role |
| --- | --- | --- |
| `gks_scv_condition_sets` | Per-SCV condition or condition set with structured codings, mappings, and extensions | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Dependencies

- **UDFs**: `clinvar_ingest.schema_on`
- **Source Tables**: `gks_scv_condition_mapping`, `gks_trait`, `gks_scv_trait_sets`
- **Upstream Procedures**: `gks_scv_condition_mapping_proc`, `gks_trait_proc`
- **Downstream Consumers**: `gks_scv_proc`
