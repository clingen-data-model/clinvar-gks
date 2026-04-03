# VCV Statements

## Overview

The VCV statement output contains one JSON record per variant-level aggregate classification. Each record is a `Statement` that aggregates individual SCV submissions into a hierarchical summary — combining classifications across conditions and submission levels to produce a single variant-level result.

VCV statements are produced by the [VCV Procedures](../pipeline/vcv-statements/vcv-proc.md) and serialized via the [JSON proc](../pipeline/scv-statements/index.md). The output table is `gks_vcv_statement`.

---

## Record Structure

Each record is a `Statement` with the following top-level fields:

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `id` | string | VCV accession with version and aggregation path — e.g., `VCV000012582.63-G` |
| `type` | string | Always `Statement` |
| `direction` | string | Always `supports` |
| `strength` | string | Always `definitive` |
| `classification_mappableConcept` | object | Single aggregate classification label for non-PGEP. See [Classification](#classification) |
| `classification_conceptSet` | object | Single PGEP classification tuple as ConceptSet. See [Classification](#classification) |
| `classification_conceptSetSet` | object | Multiple PGEP classification tuples as nested ConceptSets. See [Classification](#classification) |
| `proposition` | object | The aggregate proposition with variant, objectClassification, and qualifiers. See [Proposition](#proposition) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus`. See [Extensions](#extensions) |
| `evidenceLines` | array | Contributing and non-contributing evidence from lower aggregation layers. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

VCV statements use three mutually exclusive classification attributes. Exactly one is populated; the others are null (omitted from JSON output via null stripping).

### classification_mappableConcept

Used for non-PGEP submission levels (CP, NOCP, NOCL, FLAG). Contains a single aggregate label with an optional `conflictingExplanation` extension when the classification is conflicting.

```json
{
  "classification_mappableConcept": {
    "conceptType": "Classification",
    "name": "Pathogenic/Likely pathogenic",
    "extension": [
      {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
    ]
  }
}
```

### classification_conceptSet

Used for PGEP submissions with a single classification tuple. An AND-group of Classification, Condition, and SubmissionLevel concepts with a `description` extension.

```json
{
  "classification_conceptSet": {
    "type": "ConceptSet",
    "concepts": [
      {"conceptType": "Classification", "name": "Likely Benign"},
      {"conceptType": "Condition", "name": "Immunodeficiency 14"},
      {"conceptType": "SubmissionLevel", "name": "expert panel"}
    ],
    "membershipOperator": "AND",
    "extensions": [
      {"name": "description", "value": "for Immunodeficiency 14\nClassification is based on the expert panel submission\nMar 2024 by GeneDx"}
    ]
  }
}
```

### classification_conceptSetSet

Used for PGEP submissions with two or more classification tuples. Nested ConceptSets, each inner group carrying its own `description` extension.

```json
{
  "classification_conceptSetSet": {
    "type": "ConceptSet",
    "concepts": [
      {
        "type": "ConceptSet",
        "concepts": [
          {"conceptType": "Classification", "name": "drug response"},
          {"conceptType": "Condition", "name": "ivacaftor response - Efficacy"},
          {"conceptType": "SubmissionLevel", "name": "expert panel"}
        ],
        "membershipOperator": "AND",
        "extensions": [{"name": "description", "value": "..."}]
      },
      {
        "type": "ConceptSet",
        "concepts": [
          {"conceptType": "Classification", "name": "drug response"},
          {"conceptType": "Condition", "name": "tezacaftor response - Efficacy"},
          {"conceptType": "SubmissionLevel", "name": "expert panel"}
        ],
        "membershipOperator": "AND",
        "extensions": [{"name": "description", "value": "..."}]
      }
    ],
    "membershipOperator": "AND"
  }
}
```

---

## Proposition

The `proposition` describes the aggregate classification claim. It uses the same 3-way `objectClassification` split as the classification, but **without extensions** and **deduplicated** across submitters.

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `VariantAggregateClassificationProposition` |
| `id` | string | Proposition ID — VCV accession without version, dash-separated (e.g., `VCV000012582-G-PATH-CP`) |
| `subjectVariant` | string | Reference to the categorical variant — `clinvar:{variation_id}` |
| `predicate` | string | Always `hasAggregateClassification` |
| `objectClassification_mappableConcept` | object | Single classification concept for non-PGEP |
| `objectClassification_conceptSet` | object | Single PGEP classification ConceptSet (no extensions, deduplicated) |
| `objectClassification_conceptSetSet` | object | Multiple PGEP classification ConceptSets (no extensions, deduplicated) |
| `aggregateQualifiers` | array | Context qualifiers — AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier |

</div>

---

## Extensions

VCV statements carry a single extension:

| Extension | Type | Description |
| --- | --- | --- |
| `clinvarReviewStatus` | string | The aggregate review status reflecting submission level and aggregation outcome. See [Aggregate Review Status](../pipeline/vcv-statements/vcv-aggregation-rules.md#aggregate-review-status) for the complete value table |

---

## Evidence Lines

Each VCV statement contains `evidenceLines` — an array of evidence line objects that reference the aggregation layer below:

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `EvidenceLine` |
| `directionOfEvidenceProvided` | string | Always `supports` |
| `strengthOfEvidenceProvided` | string | `contributing` or `non-contributing` — indicates whether this evidence contributed to the aggregate classification |
| `evidenceItems` | array | Array of referenced statements from the layer below — either full inlined sub-statements or leaf-level SCV ID references |

At the top layer (L4 for germline, L3 for somatic), evidence items contain fully inlined sub-statements with their own classification, proposition, extensions, and nested evidence lines. At the bottom layer (L1), evidence items are ID-only references to individual SCV submissions:

```json
{"id": "clinvar.submission:SCV001571657.2"}
```

These references resolve to full SCV records in `scv_by_ref.jsonl.gz`. See [ID References](id-references.md) for resolution details.

---

## Layer Hierarchy

VCV statements are built through a 4-layer aggregation hierarchy. The top-level record is the outermost layer; each nested evidence item is one layer deeper.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| L4 (Group) | `VCV000012582.63-G` | Statement group | Germline only |
| L3 (Submission Level) | `VCV000012582.63-G-PATH` | Proposition type | All |
| L2 (Tier) | `VCV000012582.63-G-SCI-CP` | Submission level | Somatic only |
| L1 (Base) | `VCV000012582.63-G-PATH-CP` | Submission level + tier | All |

Germline VCV statements use Layer 4 as the top level. Somatic VCV statements use Layer 3 as the top level (no Layer 4 for somatic).

See [Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) for detailed submission level logic and [VCV Procedures](../pipeline/vcv-statements/vcv-proc.md) for implementation details.
