# VCV Statements

## Overview

VCV statement generation aggregates individual SCV (submission-level) classifications into variant-level summary statements. The process combines submissions across conditions and submission levels to produce a hierarchical set of aggregate classification statements for each variant.

The pipeline is implemented across three stored procedures:

1. **`gks_vcv_proc`** — builds the aggregation tables through four layers of progressively broader aggregation
2. **`gks_vcv_statement_proc`** — transforms the aggregation tables into GKS-formatted VCV statements with nested evidence lines
3. **`gks_json_proc`** — serializes the final statements to JSON with null/empty field stripping

---

## Key Concepts

- **Submission levels** — PG, EP, CP, NOCP, NOCL, and FLAG — determine how classifications are combined and whether conflicts are detected
- **Four-layer hierarchy** — L1 (base) through L4 (group) progressively aggregate from individual SCVs to variant-level summaries
- **Two classification formats** — `aggregate_classification_single` for standard aggregation and `aggregate_classification_array` for combined PG+EP (PGEP) submissions

---

## Section Contents

- [Aggregation Rules](vcv-aggregation-rules.md) — submission level logic, classification output formats, review status derivation, and layer hierarchy
- [VCV Procedures](vcv-proc.md) — stored procedure documentation (under construction)
