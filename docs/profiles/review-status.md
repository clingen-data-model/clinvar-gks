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
