# VCV Statements

## Overview

VCV statement generation aggregates individual SCV (submission-level) classifications into variant-level summary statements. The process combines submissions across conditions and submission levels to produce a hierarchical set of aggregate classification statements for each variant.

The pipeline is implemented across two stored procedures:

1. **`gks_vcv_proc`** — builds the aggregation tables through a two-layer aggregation hierarchy
2. **`gks_vcv_statement_proc`** — transforms the aggregation tables into GKS-formatted VCV statements with nested evidence lines, written to `gks_dict_vcv`

`gks_dict_vcv` is the published product for VCV statements. Null/empty field stripping is applied during bundle assembly at export time (`assemble-gks-dicts.py`).

---

## Key Concepts

- **Submission levels** — PG, EP, CP, NOCP, NOCL, and FLAG — determine how classifications are combined and whether conflicts are detected. Each submission level aggregates independently; only matching levels can combine. Submission levels are ranked `PG > EP > CP > NOCP > NOCL > FLAG`, with PG always winning at the top
- **Two-layer hierarchy** — the Grouping Layer (Classification Grouping and Priority Grouping steps) aggregates individual SCVs, and the Aggregate Contribution Layer applies winner-takes-all across submission levels to produce final variant-level summaries
- **Single classification format** — all VCV statements use `classification` as the aggregate classification attribute, with an optional `conflictingExplanation` extension when contributing SCVs disagree. The same single-attribute pattern applies to `objectClassification` within the proposition

---

## Pipeline Flow

```text
SCV Statements (gks_dict_scv)
         │
         ▼
┌──────────────────────────────────┐
│  gks_vcv_proc                    │
│  Classification Grouping         │  Group by variation + group + prop + level [+ tier]
│  Priority Grouping               │  Aggregate tiers within level (somatic only)
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
         gks_dict_vcv
```

---

## Section Contents

- [Aggregation Rules](vcv-aggregation-rules.md) — submission level logic, classification output formats, review status derivation, and layer hierarchy
- [VCV Procedures](vcv-proc.md) — detailed documentation of `gks_vcv_proc` and `gks_vcv_statement_proc`

---

## Examples

See [VCV statement examples](https://github.com/clingen-data-model/clinvar-gks/tree/main/examples/vcv) in the repository for annotated JSONC examples of germline and somatic aggregate classification statements.
