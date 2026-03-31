# VCV Statements

## Overview

VCV statement generation aggregates individual SCV (submission-level) classifications into variant-level summary statements. The process combines submissions across conditions and submission levels to produce a hierarchical set of aggregate classification statements for each variant.

The pipeline is implemented across two stored procedures plus a JSON serialization step:

1. **`gks_vcv_proc`** — builds the aggregation tables through four layers of progressively broader aggregation
2. **`gks_vcv_statement_proc`** — transforms the aggregation tables into GKS-formatted VCV statements with nested evidence lines
3. **`gks_json_proc`** — serializes the final statements to JSON with null/empty field stripping

---

## Key Concepts

- **Submission levels** — PG, EP, CP, NOCP, NOCL, and FLAG — determine how classifications are combined and whether conflicts are detected. PG and EP are combined into a single PGEP grouping for aggregation
- **Four-layer hierarchy** — L1 (base) through L4 (group) progressively aggregate from individual SCVs to variant-level summaries
- **Three classification formats** — `classification_mappableConcept` for standard single-label aggregation, `classification_conceptSet` for a single PGEP classification tuple, and `classification_conceptSetSet` for multiple PGEP classification tuples. The same 3-way split applies to `objectClassification` within the proposition

---

## Pipeline Flow

```text
SCV Statements (gks_statement_scv_pre)
         │
         ▼
┌─────────────────────────┐
│  gks_vcv_proc           │
│  Layer 1: Base          │  Group by variation + group + prop + level [+ tier]
│  Layer 2: Tier          │  Aggregate tiers within level (somatic only)
│  Layer 3: Submission    │  Winner-takes-all across submission levels
│  Layer 4: Group         │  Winner-takes-all across proposition types (germline)
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│  gks_vcv_statement_proc │
│  L1–L4 BASE statements  │  Build statement structures from agg tables
│  L1 PRE: inline SCVs    │  Populate PGEP ConceptSet classification
│  L2–L4 PRE: inline      │  Propagate classification through layers
│  FINAL: union            │  Combine germline L4 + somatic L3
└────────────┬────────────┘
             │
             ▼
      gks_vcv_statement_pre
```

---

## Section Contents

- [Aggregation Rules](vcv-aggregation-rules.md) — submission level logic, classification output formats, review status derivation, and layer hierarchy
- [VCV Procedures](vcv-proc.md) — detailed documentation of `gks_vcv_proc` and `gks_vcv_statement_proc`
