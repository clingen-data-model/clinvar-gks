# Condition Sets (Step 15 of gks_scv_condition_proc)

## Overview

Step 15 of the `clinvar_ingest.gks_scv_condition_proc` procedure assembles individual conditions into structured domain entities for each SCV. SCVs with a single condition produce a `Condition` record; SCVs with multiple conditions produce a `ConditionSet` containing a `conditions` array and a `membershipOperator`. The resulting `gks_scv_condition_sets` table feeds directly into the SCV statement assembly procedure (`gks_scv_statement_proc`), where it becomes the condition component of the full SCV statement.

---

## Workflow

This step executes as a single query with two CTEs.

### Build Individual Condition Records

The `enriched_conditions` CTE joins each SCV trait from `gks_scv_condition_mapping` with its normalized trait record from `temp_gks_trait`, and uses a `COUNT(*) OVER` window function to classify single vs multi-condition SCVs in one pass. For each condition, the output includes:

- **`id`** — the clinical assertion trait ID (`cat_id`)
- **`name`** — the CA trait name, falling back to the submitted trait name if the CA name is null
- **`conceptType`** — the CA trait type
- **`primaryCoding`** — from the normalized `gks_trait` record (MedGen coding)
- **`mappings`** — from the normalized `gks_trait` record (non-MedGen cross-references)
- **`extensions`** — a concatenation of trait extensions plus condition-specific extensions (see [Condition Extensions](condition-extensions.md) for full field documentation)

### Build Condition Sets for Multi-Condition SCVs

The `multi_sets` CTE filters to only multi-condition SCVs (where `trait_count > 1`) and aggregates. The grouping produces:

- **`conditions`** — an array of condition structs (id, name, conceptType, primaryCoding, mappings, extensions)
- **`membershipOperator`** — determines how multiple conditions relate to each other:
  - `AND` — when the trait relationship type is `Finding member` or `co-occurring condition`
  - `OR` — for all other relationship types

### Assemble Final Output

The final query joins `temp_gks_scv_trait_sets` with the condition and condition set CTEs to produce one row per SCV with two mutually exclusive fields:

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

- **Source Tables**: `gks_scv_condition_mapping` (persistent), `temp_gks_trait` (internal), `temp_gks_scv_trait_sets` (internal)
- **Upstream Steps**: Step 1 (Traits), Steps 2–14 (Condition Mapping)
- **Downstream Consumers**: `gks_scv_statement_proc`
