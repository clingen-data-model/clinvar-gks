# VCV Aggregation Rules

## Overview

VCV (Variant-level Classification) aggregation combines individual SCV (Submission-level Classification) submissions into aggregate variant-level classification statements. Each SCV represents a single submitter's classification of a variant; VCV aggregation produces a summary classification that reflects the consensus (or conflict) across all submissions for the same variant and statement type.

The aggregation process is governed by **submission levels** — categories that reflect the authority and review rigor behind each submission. Submission levels determine how classifications are combined, whether conflicts are detected, and what review status label the aggregate statement receives.

---

## Submission Levels

Every SCV is assigned a submission level based on its ClinVar review status:

| Code | Label | Rank | Stars | Description |
| --- | --- | --- | --- | --- |
| PG | practice guideline | 6 | 4 | Published practice guidelines from authoritative bodies |
| EP | expert panel | 5 | 3 | Classifications reviewed and approved by expert panels |
| CP | assertion criteria provided | 4 | 1 | Submitter provided criteria for their classification |
| NOCP | no assertion criteria provided | 3 | 0 | Classification submitted without documented criteria |
| NOCL | no classification provided | 2 | -1 | Submission present but no classification given |
| FLAG | flagged submission | 1 | -3 | Submission flagged by ClinVar for quality concerns |

Every submission level is aggregated independently — only SCVs with the same submission level can aggregate together. At the Aggregate Contribution Layer, submission levels are ranked `PG > EP > CP > NOCP > NOCL > FLAG` and the highest-ranked level becomes the winner-takes-all contributing result.

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

This description is carried on the SCV classification and is not propagated onto VCV aggregate statements.

---

## Aggregation by Submission Level

### PG (Practice Guideline)

Practice guideline submissions are aggregated independently. Like CP, concordance and conflict detection produce a single aggregate label.

- **Output attribute:** `classification`
- **Review status:** always `practice guideline`

### EP (Expert Panel)

Expert panel submissions are aggregated independently. Like CP, concordance and conflict detection produce a single aggregate label.

- **Output attribute:** `classification`
- **Review status:** always `reviewed by expert panel`

### CP (Assertion Criteria Provided)

Standard aggregation with concordance and conflict detection.

- **Output attribute:** `classification` — a single aggregate label
- **Concordant** — all contributing SCVs share the same classification: the label is the shared classification name
- **Conflicting** — contributing SCVs have different classifications: the label becomes "Conflicting classifications of `<proposition_type>`" with a `conflictingExplanation` extension showing the breakdown (e.g., "Pathogenic(3); Likely pathogenic(2)")
- **Review status upgrades:** CP submissions may receive upgraded review status based on submitter count and concordance (see [Aggregate Review Status](#aggregate-review-status))

### NOCP (No Assertion Criteria Provided)

Same aggregation logic as CP — concordance/conflict detection produces a single label.

- **Output attribute:** `classification`
- **No review status upgrade** — always "no assertion criteria provided" regardless of submitter count or concordance

### FLAG (Flagged Submissions)

No aggregation logic. Flagged submissions always produce a fixed result.

- **Output attribute:** `classification`
- **Label:** always "no classifications from unflagged records"
- **No conflict detection**

### NOCL (No Classification Provided)

Passthrough with no aggregation logic.

- **Output attribute:** `classification`
- **Label:** always "not provided"

---

## Classification Output

Every VCV statement uses a single `classification` attribute to represent its aggregate classification. The classification lives only on the statement — the proposition does not carry a copy of the classification value.

### `classification`

Used by all submission levels (PG, EP, CP, NOCP, NOCL, and FLAG). Contains a single aggregate label with an optional `conflictingExplanation` extension when contributing SCVs disagree.

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

The `extension` array is only present when the classification is conflicting.

### `confidence`, `direction`, and `strength`

These statement-level fields are derived from the aggregate classification label:

- **`confidence`** — the submission level label (e.g., `"expert panel"`, `"assertion criteria provided"`). Set on every VCV statement.
- **`direction`** — derived from the classification label. For single-SCV aggregations, passed through directly from the contributing SCV. For multi-SCV aggregations, derived from the winning label.
- **`strength`** — derived from the classification label. For single-SCV aggregations, passed through directly from the contributing SCV. For multi-SCV aggregations, derived from the winning label. No hardcoded `"definitive"` value.

---

## Aggregate Review Status

Every VCV statement includes a `clinvarReviewStatus` extension indicating the aggregate review confidence level. The value depends on the submission level and aggregation outcome.

| Submission Level | Condition | Review Status |
| --- | --- | --- |
| PG | Any | `practice guideline` |
| EP | Any | `reviewed by expert panel` |
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

## Aggregation Hierarchy

VCV aggregation builds statements through a two-layer hierarchy. Each layer may consist of multiple SQL steps, but conceptually there are two aggregation layers.

### Grouping Layer

The Grouping Layer produces the initial aggregation of individual SCVs into groups. It consists of two steps that run as separate SQL operations but form a single conceptual layer:

| Step | Name | Aggregates By | Description |
| --- | --- | --- | --- |
| Base Grouping | `gks_vcv_grouping_base_agg` | Variation + Statement Group + Proposition Type + Submission Level (+ Tier) | Lowest-level aggregation of individual SCVs. Applies submission-level-specific classification and conflict detection logic |
| Tier Grouping | `gks_vcv_grouping_tier_agg` | Variation + Statement Group + Proposition Type + Submission Level | Combines tier-level groups (somatic sci only). Ranks tiers by priority, designates top tier as contributing |

Tier Grouping applies only to somatic tiered records (`tier_grouping IS NOT NULL`). Non-tiered records (all germline and non-sci somatic) flow directly from Base Grouping to the Aggregate Contribution Layer.

### Aggregate Contribution Layer

| Step | Name | Aggregates By | Description |
| --- | --- | --- | --- |
| Aggregate Contribution | `gks_vcv_aggregate_contribution` | Variation + Statement Group + Proposition Type | Winner-takes-all across submission levels. This is the terminal layer for both germline and somatic statements |

Submission levels are ranked `PG > EP > CP > NOCP > NOCL > FLAG`. The highest-ranked submission level becomes the "contributing" result; all others become "non-contributing" evidence.

Each layer's output includes `evidenceLines` that reference the layer below, creating a nested structure in the final JSON output.
