# Conditions & Traits

## Overview

ClinVar submissions (SCVs) reference conditions — diseases, phenotypes, or findings — that a submitter associates with a variant. Internally, ClinVar uses the term "trait" for these condition records, and each submission's traits may differ from the normalized traits that ClinVar assigns at the RCV (aggregate review) level. The three procedures documented in this section bridge that gap: they map each SCV's submitted traits to ClinVar's normalized trait records, build GKS-compliant condition structures with standardized codings and cross-references, and assemble multi-condition submissions into condition sets.

The conditions and traits pipeline spans three stored procedures that execute in sequence:

1. **Condition Mapping** (`gks_scv_condition_mapping_proc`) — resolves each SCV's submitted traits to ClinVar's normalized RCV traits through a multi-stage matching strategy
2. **Traits** (`gks_trait_proc`) — builds GKS-compliant trait records with standardized codings (MedGen, OMIM, MONDO, HPO, Orphanet, MeSH, EFO)
3. **Condition Sets** (`gks_scv_condition_sets_proc`) — assembles individual conditions into `Condition` or `ConditionSet` domain entities for each SCV

These steps do not produce a standalone output file. Instead, the resulting `gks_scv_condition_sets` table feeds directly into the SCV record assembly (Step 7), where conditions become part of the full SCV statement output. The same condition structures will also be critical for RCV accession output when that is added to the pipeline.

---

## ClinVar Trait Terminology

ClinVar's XML schema uses "trait" where the GKS output uses "condition." The mapping between the two terminologies is:

| ClinVar Term | GKS Term | Description |
| --- | --- | --- |
| Trait | Condition | A single disease, phenotype, or finding |
| TraitSet | ConditionSet | A group of traits with a membership operator |
| TraitMapping | — | ClinVar's internal record linking an SCV's submitted trait text to a normalized trait |
| ClinicalAssertionTrait | — | The submitter's original trait record as submitted to ClinVar |

---

## Pipeline Flow

```text
┌──────────────────────────────────────────────────────────────────┐
│  Step 4: Condition Mapping                                       │
│  gks_scv_condition_mapping_proc                                  │
│                                                                  │
│  Inputs:  trait_mapping, rcv_mapping, clinical_assertion_trait,   │
│           clinical_assertion_trait_set                            │
│                                                                  │
│  Outputs: gks_scv_trait_sets, gks_normalized_traits,             │
│           gks_all_scv_traits, gks_all_mapped_scv_traits,         │
│           gks_scv_condition_mapping                               │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│  Step 5: Traits                                                  │
│  gks_trait_proc                                                  │
│                                                                  │
│  Inputs:  trait                                                  │
│                                                                  │
│  Outputs: gks_trait                                              │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│  Step 6: Condition Sets                                          │
│  gks_scv_condition_sets_proc                                     │
│                                                                  │
│  Inputs:  gks_scv_condition_mapping, gks_trait,                  │
│           gks_scv_trait_sets                                     │
│                                                                  │
│  Outputs: gks_scv_condition_sets                                 │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           ▼
                  SCV Record Assembly (Step 7)
```

---

## Why Condition Mapping Is Complex

Submitters to ClinVar provide their own trait text and cross-references, which frequently differ from the normalized trait records that ClinVar curators assign at the RCV level. The condition mapping procedure exists to reconcile these differences through a progressive matching strategy:

- **Trait mappings** — ClinVar provides explicit mapping records that link an SCV's submitted trait to a normalized trait via name or cross-reference. These are the highest-confidence matches
- **Direct xref matching** — when trait mappings are insufficient, the procedure matches SCV traits to RCV traits by comparing submitted cross-references (MedGen, OMIM, MONDO, HPO, Orphanet, MeSH) directly
- **Singleton inference** — when only one unmatched SCV trait and one unmatched RCV trait remain for a submission, they are paired by elimination
- **Rogue trait matching** — for SCV traits that do not appear in the expected RCV trait set, the procedure searches across all normalized traits by xref IDs, preferred name, and alternate names

See [Condition Mapping](condition-mapping.md) for the full procedure documentation.

---

## Detailed Documentation

- [Condition Mapping](condition-mapping.md) — multi-stage SCV-to-RCV trait resolution
- [Traits](traits.md) — GKS trait record generation with standardized codings
- [Condition Sets](condition-sets.md) — condition and condition set assembly for SCV output
- [Condition Extensions](condition-extensions.md) — extension reference for condition and condition set records
