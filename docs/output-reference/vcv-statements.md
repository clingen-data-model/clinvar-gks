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
| `classification` | object | Aggregate classification label. See [Classification](#classification) |
| `proposition` | object | The aggregate proposition with variant, objectClassification, and qualifiers. See [Proposition](#proposition) |
| `extensions` | array | Aggregate metadata — `clinvarReviewStatus`. See [Extensions](#extensions) |
| `evidenceLines` | array | Contributing and non-contributing evidence from lower aggregation layers. See [Evidence Lines](#evidence-lines) |

</div>

---

## Classification

All VCV statements use a single `classification` attribute for the aggregate classification.

### classification

Used by all submission levels (PG, EP, CP, NOCP, NOCL, FLAG). Contains a single aggregate label with an optional `conflictingExplanation` extension when the classification is conflicting.

```json
{
  "classification": {
    "conceptType": "Classification",
    "name": "Pathogenic/Likely pathogenic",
    "extension": [
      {"name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)"}
    ]
  }
}
```

---

## Proposition

The `proposition` describes the aggregate classification claim. It uses a single `objectClassification` MappableConcept mirroring the statement-level classification (without the `conflictingExplanation` extension).

<div class="field-table" markdown>

| Field | Type | Description |
| --- | --- | --- |
| `type` | string | Always `VariantAggregateClassificationProposition` |
| `id` | string | Proposition ID — VCV accession without version, dash-separated (e.g., `VCV000012582-G-PATH-CP`) |
| `subjectVariant` | string | Reference to the categorical variant — `clinvar:{variation_id}` |
| `predicate` | string | Always `hasAggregateClassification` |
| `objectClassification` | object | A MappableConcept matching the statement-level classification (no `conflictingExplanation` extension) |
| `aggregateQualifiers` | array | Context qualifiers — AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier |

</div>

!!! note
    PG and EP are separate submission levels; PG outranks EP at the Aggregate Contribution Layer winner-takes-all.

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

At the top layer (the Aggregate Contribution Layer for both germline and somatic), evidence items contain fully inlined sub-statements with their own classification, proposition, extensions, and nested evidence lines. At the bottom layer (Base Grouping), evidence items are ID-only references to individual SCV submissions:

```json
{"id": "clinvar.submission:SCV001571657.2"}
```

These references resolve to full SCV records in `scv_by_ref.jsonl.gz`. See [ID References](id-references.md) for resolution details.

---

## Layer Hierarchy

VCV statements are built through a 2-layer aggregation hierarchy. The top-level record is the outermost layer; each nested evidence item is one layer deeper.

| Layer | ID Format | Aggregates By | Scope |
| --- | --- | --- | --- |
| Aggregate Contribution | `VCV000012582.63-G-PATH` | Proposition type | All |
| Tier Grouping | `VCV000012582.63-G-SCI-CP` | Submission level | Somatic only |
| Base Grouping | `VCV000012582.63-G-SCI-CP-PATHOGENIC` | Submission level + tier | All |

Both germline and somatic VCV statements use the Aggregate Contribution Layer as the top level. Tier Grouping tier components are uppercase (e.g., `PATHOGENIC`). Submission level ranking at the Aggregate Contribution Layer is `PG > EP > CP > NOCP > NOCL > FLAG`, with only matching submission levels aggregating together at Base Grouping.

See [Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) for detailed submission level logic and [VCV Procedures](../pipeline/vcv-statements/vcv-proc.md) for implementation details.
