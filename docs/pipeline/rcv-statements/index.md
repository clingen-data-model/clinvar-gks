# RCV Statements

## Overview

RCV statement generation aggregates individual SCV (submission-level) classifications into condition-specific aggregate statements. Unlike VCV statements, which aggregate all submissions for a given variation regardless of condition, RCV statements aggregate submissions per (variation, condition) pair, using `trait_set_id` as the condition grouping key. Each RCV accession represents a unique combination of a variation and a condition set.

The pipeline is implemented across two stored procedures:

1. **`gks_rcv_proc`** -- builds the aggregation tables through a two-layer aggregation hierarchy
2. **`gks_rcv_statement_proc`** -- transforms the aggregation tables into GKS-formatted RCV statements with nested evidence lines and condition data, written to `gks_dict_rcv`

`gks_dict_rcv` is the published product for RCV statements. Null/empty field stripping is applied during bundle assembly at export time (`assemble-gks-dicts.py`).

---

## Key Concepts

- **Condition-specific aggregation** -- RCV groups SCVs by (variation, condition) pair via `trait_set_id`, producing one aggregate statement per RCV accession rather than one per variation
- **Submission levels** -- PG, EP, CP, NOCP, NOCL, and FLAG -- same as VCV. PG and EP are separate top-tier submission levels with PG outranking EP at the Aggregate Contribution Layer winner-takes-all
- **Two-layer hierarchy** -- the Grouping Layer (Classification Grouping and Priority Grouping steps) aggregates individual SCVs, and the Aggregate Contribution Layer applies winner-takes-all across submission levels to produce final RCV-level summaries
- **objectCondition** -- RCV propositions use `objectCondition` to carry the condition from `gks_scv_condition_sets` -- either a `Condition` MappableConcept or a `ConditionSet` ConceptSet (extensions excluded). The classification lives on the statement, not in the proposition
- **Proposition type** -- uses the same SCV-matching proposition types from `clinvar_proposition_types` (e.g., `VariantPathogenicityProposition` with `isCausalFor`)
- **Single classification form** -- RCV uses only `classification` at every layer, consistent with VCV

---

## Pipeline Flow

```text
SCV Statements (gks_dict_scv)
         |
         v
+---------------------------------+
|  gks_rcv_proc                   |
|  Condition data: rcv_mapping    |  Resolve RCV -> SCV -> condition mappings
|    + rcv_accession              |
|  Classification Grouping        |  Group by rcv_accession + group + prop + level [+ tier]
|  Priority Grouping              |  Aggregate tiers within level (somatic only)
|  Aggregate Contribution         |  Winner-takes-all across submission levels
+--------------+------------------+
               |
               v
+---------------------------------+
|  gks_rcv_statement_proc         |
|  Condition data resolution      |  Build temp_rcv_condition_data from
|    via rcv_mapping +            |    rcv_mapping + gks_scv_condition_sets
|    gks_scv_condition_sets       |
|  BASE statements (3 steps)     |  Build statement structures from agg tables
|  PRE: inline evidence (3 steps)|  Inline lower layers as evidence items
|  FINAL: select all             |  All Aggregate Contribution statements
+--------------+------------------+
               |
               v
        gks_dict_rcv
```

---

## Section Contents

- [RCV Procedures](rcv-proc.md) -- detailed documentation of `gks_rcv_proc` and `gks_rcv_statement_proc`
- [RCV Extensions](rcv-extensions.md) -- extensions and aggregate qualifiers on RCV statements

---

## Examples

See [RCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/rcv) in the repository for annotated JSONC examples of germline and somatic aggregate condition classification statements.
