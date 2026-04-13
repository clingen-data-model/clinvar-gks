# Review Status

All ClinVar submissions contain a review status, which differentiates submissions based on their level of confidence. These review status levels (also called star levels) are used in ClinVar to group and prioritize multiple submissions for the same variant and statement type.

## Individual Submission Review Status Levels

| Review Status | Stars |
| --- | --- |
| practice guideline | 4 |
| reviewed by expert panel | 3 |
| criteria provided, single submitter | 1 |
| no assertion criteria provided | 0 |
| no classification provided | 0 |
| flagged submission | 0 |

## Aggregation Behavior

If multiple submissions exist for the same variant and statement type, ClinVar aggregates them into two higher-order statements:

- **RCVs** — aggregate of submissions for the same statement type, variant, **and condition**
- **VCVs** — aggregate of submissions for the same statement type **and variant** (across all conditions)

RCVs and VCVs use only the highest-ranking review status levels in the aggregated result. These are considered the **contributing submissions**; others are **non-contributing**.

## Rank Order

The rank order is a quantification of the review status levels used to appropriately segregate submissions within a single statement type, variant, and condition. Rank order is not a ClinVar concept but is used during the ClinVar-GKS aggregation process.

| Rank | Review Status | Stars |
| --- | --- | --- |
| 4 | practice guideline | 4 |
| 3 | reviewed by expert panel | 3 |
| 1 | criteria provided, single submitter | 1 |
| 0 | no assertion criteria provided | 0 |
| -1 | no classification provided | 0 |
| -3 | flagged submission | 0 |

## Aggregate Review Status

When individual submissions are aggregated into VCV-level statements, the resulting aggregate review status reflects both the submission level and the aggregation outcome. The aggregate review status appears as a `clinvarReviewStatus` extension on each VCV statement.

| Submission Level | Condition | Aggregate Review Status |
| --- | --- | --- |
| PG | Any | `practice guideline` |
| EP | Any | `reviewed by expert panel` |
| CP | Single submitter | `criteria provided, single submitter` |
| CP | Multiple submitters, concordant | `criteria provided, multiple submitters, no conflicts` |
| CP | Multiple submitters, conflicting | `criteria provided, conflicting classifications` |
| NOCP | Any | `no assertion criteria provided` |
| NOCL | Any | `no classification provided` |
| FLAG | Any | `flagged submission` |

CP is the only submission level where the aggregate review status changes based on the aggregation result. All other levels produce a fixed review status regardless of the number of contributing submissions.

See [VCV Aggregation Rules](../pipeline/vcv-statements/vcv-aggregation-rules.md) for full details on how submission levels are aggregated.
