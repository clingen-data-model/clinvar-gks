# ACMGv4 Variant Pathogenicity Profile

!!! warning "Draft"
    This document and the accompanying example are actively being developed in conjunction with the SVC v4 (Sequence Variant Curation v4) working group at ClinGen. The model is not yet finalized and may change significantly.

## Overview

This project defines how ACMG/AMP v4 variant pathogenicity assessments can be represented using the GA4GH VA-Spec data model. The goal is to capture the full structure of an ACMG v4 classification — including the proposition, hierarchical evidence lines, numeric scoring, and contributing agents — in a machine-readable format that aligns with GA4GH standards.

The approach and requirements are informed by the SVC v4 working group at ClinGen (see [CCG25 - Harrison S.pptx](CCG25%20-%20Harrison%20S.pptx) presentation).

---

## Statement Structure

An ACMG v4 classification is represented as a VA-Spec `Statement` with a `VariantPathogenicityProposition`. The statement carries:

- A **proposition** asserting that a variant is causal for a condition, qualified by gene context, mode of inheritance, penetrance, and allele origin
- A **classification** (Pathogenic, Likely pathogenic, VUS, Likely benign, Benign) with a numeric **score** reflecting the total evidence weight
- **Evidence lines** organized in a hierarchy that mirrors the ACMG v4 scoring framework

---

## Proposition

The proposition uses the subject-predicate-object-qualifier (SPOQ) pattern:

| Field | Value | Description |
| --- | --- | --- |
| `type` | `VariantPathogenicityProposition` | Fixed proposition type |
| `subjectVariant` | CatVRS reference | The variant being classified (e.g., `clingen.ar:CA347424`) |
| `predicate` | `isCausalFor` | Fixed predicate for pathogenicity |
| `objectCondition` | Disease concept | The condition with MedGen/MONDO coding |
| `geneContextQualifier` | Gene concept | Gene context with NCBI Gene/HGNC identifiers |
| `modeOfInheritanceQualifier` | HPO concept | Mode of inheritance (e.g., `HP:0000006` Autosomal dominant) |
| `penetranceQualifier` | Concept | Penetrance level (high, moderate, low) |
| `alleleOriginQualifier` | Concept | Allele origin (germline, somatic) |

---

## Classification and Scoring

The top-level statement carries both a classification concept and a numeric score:

```json
{
  "classification": {
    "primaryCoding": {
      "code": "pathogenic",
      "system": "ACMG Guidelines v4"
    }
  },
  "score": 16.0,
  "direction": "supports",
  "strength": {
    "primaryCoding": {
      "code": "definitive",
      "system": "ACMG Guidelines v4"
    }
  }
}
```

The `score` is the final rolled-up numeric value from the evidence line hierarchy. Classification thresholds map scores to ACMG categories.

---

## Evidence Line Hierarchy

The ACMG v4 scoring framework is represented as nested evidence lines. Each level aggregates scores from its children using cap-and-sum rules.

```text
Statement (score: 16.0, classification: Pathogenic)
├── HO: Human Observation (score: 9.0)
│   ├── HO.ObsCnt: Observation Counting (score: 5.0)
│   │   ├── HO.ObsCnt.PopFreq: Population Frequency (score: 0.0)
│   │   │   └── HO.ObsCnt.PopFreq.MAF: MAF threshold evidence items
│   │   └── HO.ObsCnt.PopFreq.Homozygotes: (placeholder)
│   └── HO.ObsAff: Affected Observations (score: 5.5, capped at 5.0)
│       ├── Monoallelic observations (score: 2.5)
│       └── De novo observations (score: 3.0)
├── LS: Locus Specificity (score: 4.0)
└── FP: Functional & Predictive (score: 7.0)
    └── Functional data (score: 7.0)
```

### Evidence Line Fields

Each evidence line in the hierarchy carries:

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `EvidenceLine` |
| `id` | string | Unique identifier for this evidence line |
| `directionOfEvidenceProvided` | string | `supports`, `disputes`, or `neutral` |
| `strengthOfEvidenceProvided` | MappableConcept | Strength label (definitive, likely, uncertain) |
| `scoreOfEvidenceProvided` | number | Numeric score at this level |
| `evidenceLineCode` | string | Hierarchical code (e.g., `HO`, `HO.ObsCnt`, `FP`) |
| `specifiedBy` | Method | The scoring rule applied at this level |
| `hasEvidenceLines` | array | Child evidence lines (intermediate nodes) |
| `hasEvidenceItems` | array | Leaf-level evidence data (terminal nodes) |

### Scoring Rules

Each evidence line applies a scoring rule described in its `specifiedBy` method:

```json
{
  "specifiedBy": {
    "type": "Method",
    "name": "ACMG v4 evidence cap score summation method",
    "methodType": "algorithm",
    "description": "Scores from child evidence lines are summed, capped at the level maximum, and rounded down if fractional."
  }
}
```

The cap-and-sum pattern at each level:

1. **Sums** the `scoreOfEvidenceProvided` from child evidence lines
2. **Caps** the result if it exceeds the level-specific maximum (e.g., HO max cap = 25)
3. **Rounds down** fractional scores

### Evidence Items

At the leaf level, evidence lines contain `hasEvidenceItems` with raw data values:

```json
{
  "hasEvidenceItems": [
    {
      "type": "EvidenceItem",
      "itemType": "DAF",
      "id": "daf-threshold-for-this-case",
      "value": 0.0001
    },
    {
      "type": "EvidenceItem",
      "itemType": "CohortAlleleFrequenceFAF",
      "id": "caf-001",
      "value": 0.000000034
    }
  ]
}
```

---

## Contributions

The statement tracks evaluator and submitter roles:

```json
{
  "contributions": [
    {
      "type": "Contribution",
      "contributor": {
        "id": "clinvar.submitter/500139",
        "type": "Agent",
        "name": "ClinVar Staff, NCBI"
      },
      "activityType": "evaluator role",
      "date": "2015-08-20"
    },
    {
      "type": "Contribution",
      "contributor": { "..." : "..." },
      "activityType": "submitter role",
      "date": "2018-06-12"
    }
  ]
}
```

---

## Example

The full annotated example is available as a JSON file:

- [acmgv4-working-in-progress.json](acmgv4-working-in-progress.json) — A pathogenic classification for `NM_004700.4:c.803CCT[1]` (ClinGen allele `CA347424`) as causal for autosomal dominant nonsyndromic hearing loss 2A, with scores rolling up through Human Observation, Locus Specificity, and Functional & Predictive evidence lines to a total score of 16.0

---

## Human Observation Case Data Model

Working documents for the case data structures used in the ACMGv4 Human Observation evidence framework:

- [Case Data Model (Notes)](ACMGv4-Case-DM.md) — Annotated JSON examples for each CLN case group (UAF, ALT, AFF, DNV), showing the attributes and controlled values used in each workflow grouping
- [Case Schema & Attribute Matrix](ACMGv4-Case-DM-Schema.md) — Superset case schema derived from all examples, with an attribute-by-group matrix and reference tables for acronyms and controlled values

---

## Open Questions

These design questions are being discussed with the SVC v4 working group:

### Evidence Line Codes

Should `evidenceLineCode` fields (e.g., `HO`, `HO.ObsCnt`, `FP`) be formalized as part of the VA-Spec model? These codes define the position in the ACMG v4 evidence hierarchy and are essential for interpreting which scoring rule applies at each level.

### Scoring Rule Representation

How should specific scoring rules (cap, sum, round) be represented? Options under consideration:

- A controlled vocabulary of rule types in `specifiedBy.methodType`
- Structured rule parameters (min cap, max cap, rounding behavior) as extensions
- IRIs pointing to CSpec rule definitions (e.g., `cspec:HO-Rule`)

### Strength at Sub-Levels

Is `strengthOfEvidenceProvided` meaningful at all evidence line levels, or only at the top-level categories (HO, LS, FP)? The ACMG framework assigns strength labels at category level but the semantics at sub-levels are unclear.

### Edited Scores

Should the model distinguish between raw computed scores and user-edited scores? The current draft includes both `rawScoreOfEvidenceProvided` and `finalScoreOfEvidenceProvided` at the observation counting level, but this pattern needs standardization.

### Code Systems

The ACMG guidelines do not publish formal code systems for classification terms, strength levels, penetrance, or allele origin. Placeholder systems are used in the example:

| Placeholder | Used For |
| --- | --- |
| `ACMG Guidelines v4` | Classification codes, strength levels |
| `ga4gh-gks-term:pathogenicity-penetrance-qualifier` | Penetrance values |
| `ga4gh-gks-term:pathogenicity-allele-origin-qualifier` | Allele origin values |

These need formalization as part of the VA-Spec terminological standards.

---

## Related Resources

- [Statement Types](../../profiles/statement-types.md) — ClinVar-GKS statement type mappings
- [Classifications](../../profiles/classifications.md) — classification values with direction/strength
- [Propositions](../../profiles/propositions.md) — proposition type mappings
- [VA-Spec](https://va-spec.readthedocs.io/) — GA4GH Variant Annotation Specification
