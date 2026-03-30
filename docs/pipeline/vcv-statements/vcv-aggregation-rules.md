# VCV Aggregation Rules

## Overview

VCV (Variant-level Classification) aggregation combines individual SCV (Submission-level Classification) submissions into aggregate variant-level classification statements. Each SCV represents a single submitter's classification of a variant; VCV aggregation produces a summary classification that reflects the consensus (or conflict) across all submissions for the same variant and statement type.

The aggregation process is governed by **submission levels** — categories that reflect the authority and review rigor behind each submission. Submission levels determine how classifications are combined, whether conflicts are detected, and what review status label the aggregate statement receives.

---

## Submission Levels

Every SCV is assigned a submission level based on its ClinVar review status:

| Code | Label | Stars | Description |
| --- | --- | --- | --- |
| PG | practice guideline | 4 | Published practice guidelines from authoritative bodies |
| EP | expert panel | 3 | Classifications reviewed and approved by expert panels |
| CP | assertion criteria provided | 1 | Submitter provided criteria for their classification |
| NOCP | no assertion criteria provided | 0 | Classification submitted without documented criteria |
| NOCL | no classification provided | -1 | Submission present but no classification given |
| FLAG | flagged submission | -3 | Submission flagged by ClinVar for quality concerns |

During aggregation, PG and EP are combined into a single **PGEP** grouping. All other levels are aggregated independently.

---

## SCV Description Extension

Every SCV classification includes a formatted `description` extension that summarizes the submission context:

```
for <condition_name>
Classification is based on the <submission_level_label> submission
<evaluated_date> by <submitter_name>
```

Where:

- **condition_name** — the condition name from the SCV, or "`N` conditions" for submissions with multiple conditions
- **submission_level_label** — the full label of the submission level (e.g., "expert panel", "assertion criteria provided")
- **evaluated_date** — formatted as `Mon YYYY`, or `(-)` if not provided
- **submitter_name** — the submitting organization name

This description is carried forward into VCV `aggregate_classification_array` entries for PGEP submissions.

---

## Aggregation by Submission Level

### PGEP (Practice Guideline + Expert Panel)

PG and EP submissions are combined into a single group. There is **no conflict detection** — each contributing SCV's classification is preserved individually.

- **Output attribute:** `aggregate_classification_array` — an array of per-SCV classification entries, each with `conceptType`, `name`, and `description`
- **Proposition:** Uses `objectClassification_conceptSet` containing the unique combinations of (classification, condition, submissionLevel) from contributing SCVs, deduplicated across submitters
- **Strength derivation:** "PG" if only practice guideline SCVs contribute, "EP" if only expert panel, "PGEP" if both

### CP (Assertion Criteria Provided)

Standard aggregation with concordance and conflict detection.

- **Output attribute:** `aggregate_classification_single` — a single aggregate label
- **Concordant** — all contributing SCVs share the same classification: the label is the shared classification name
- **Conflicting** — contributing SCVs have different classifications: the label becomes "Conflicting classifications of `<proposition_type>`" with a `conflictingExplanation` extension showing the breakdown (e.g., "Pathogenic(3); Likely pathogenic(2)")
- **Review status upgrades:** CP submissions may receive upgraded review status based on submitter count and concordance (see [Aggregate Review Status](#aggregate-review-status))

### NOCP (No Assertion Criteria Provided)

Same aggregation logic as CP — concordance/conflict detection produces a single label.

- **Output attribute:** `aggregate_classification_single`
- **No review status upgrade** — always "no assertion criteria provided" regardless of submitter count or concordance

### FLAG (Flagged Submissions)

No aggregation logic. Flagged submissions always produce a fixed result.

- **Output attribute:** `aggregate_classification_single`
- **Label:** always "no classifications from unflagged records"
- **No conflict detection**

### NOCL (No Classification Provided)

Passthrough with no aggregation logic.

- **Output attribute:** `aggregate_classification_single`
- **Label:** always "not provided"

---

## Aggregate Classification Output

VCV statements use two mutually exclusive attributes for the aggregate classification. Exactly one is present on any given statement; the other is omitted from the JSON output.

### `aggregate_classification_single`

Used by CP, NOCP, NOCL, and FLAG submission levels. Contains a single aggregate label.

```json
{
  "aggregate_classification_single": {
    "conceptType": "AggregateClassification",
    "name": "Pathogenic/Likely pathogenic",
    "extension": [
      {
        "name": "conflictingExplanation",
        "value": "Pathogenic(3); Likely pathogenic(2)"
      }
    ]
  }
}
```

The `extension` array is only present when the classification is conflicting.

### `aggregate_classification_array`

Used exclusively by PGEP submissions. Contains one entry per contributing SCV.

```json
{
  "aggregate_classification_array": [
    {
      "conceptType": "AggregateClassification",
      "name": "Pathogenic",
      "description": "for Breast cancer\nClassification is based on the expert panel submission\nMar 2024 by GeneDx"
    },
    {
      "conceptType": "AggregateClassification",
      "name": "Pathogenic",
      "description": "for Hereditary cancer\nClassification is based on the practice guideline submission\nJan 2023 by NCCN"
    }
  ]
}
```

---

## Aggregate Review Status

Every VCV statement includes a `clinvarReviewStatus` extension indicating the aggregate review confidence level. The value depends on the submission level and aggregation outcome.

| Submission Level | Condition | Review Status |
| --- | --- | --- |
| PGEP (mixed PG + EP) | Both PG and EP contribute | `practice guideline and expert panel mix` |
| PGEP (PG only) | Only PG SCVs contribute | `practice guideline` |
| PGEP (EP only) | Only EP SCVs contribute | `reviewed by expert panel` |
| CP | Single submitter | `criteria provided, single submitter` |
| CP | Multiple submitters, concordant | `criteria provided, multiple submitters, no conflicts` |
| CP | Multiple submitters, conflicting | `criteria provided, conflicting classifications` |
| NOCP | Any | `no assertion criteria provided` |
| NOCL | Any | `no classification provided` |
| FLAG | Any | `flagged submission` |

The review status appears in the statement-level `extensions` array:

```json
{
  "extensions": [
    {"name": "clinvarReviewStatus", "value": "criteria provided, multiple submitters, no conflicts"}
  ]
}
```

---

## Layer Hierarchy

VCV aggregation builds statements through a four-layer hierarchy. Each layer aggregates the results of the layer below it.

| Layer | Name | Aggregates By | Description |
| --- | --- | --- | --- |
| L1 | Base Aggregator | Variation + Statement Group + Proposition Type + Submission Level (+ Tier) | Lowest-level aggregation of individual SCVs |
| L2 | Tier Aggregator | Variation + Statement Group + Proposition Type + Submission Level | Combines tier-level groups (somatic only) |
| L3 | Submission Level Aggregator | Variation + Statement Group + Proposition Type | Winner-takes-all across submission levels |
| L4 | Group Aggregator | Variation + Statement Group | Winner-takes-all across proposition types (germline only) |

Key behaviors:

- **PGEP bypasses Layer 2** — PGEP is germline-only and has no tier grouping, so it flows directly from L1 to L3
- **Somatic statements stop at Layer 3** — somatic classifications do not participate in Layer 4 group aggregation
- **Winner-takes-all** at Layers 3 and 4 — the highest-ranked submission level (or proposition type) becomes the "contributing" result; others become "non-contributing" evidence
- Each layer's output includes `evidenceLines` that reference the layer below, creating a fully nested structure in the final JSON output
