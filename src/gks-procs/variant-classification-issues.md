# ClinVar "Other" Classification Handling Issue

## Overview

This document describes an inconsistency in how ClinVar handles "other" classifications during aggregation, specifically when they are annotated as benign-equivalent.

## Examples

### Example 1: VCV99330 (Pathogenic/Likely Pathogenic)

**URL:** <https://www.ncbi.nlm.nih.gov/clinvar/variation/99330/>

| Aggregate Classification | Review Status | Submissions     |
|--------------------------|---------------|-----------------|
| Path/Likely Path         | 2-star        | 14 contributing |

**Issue:** 1 submission is classified as "other" (Eurofins Ntd Llc) but is noted as being benign. Despite this, the "other" classification is lumped with the Path/Likely Path aggregate and does **not** cause a conflict.

### Example 2: VCV617719 (Likely Benign)

**URL:** <https://www.ncbi.nlm.nih.gov/clinvar/variation/617719/>

| Aggregate Classification | Review Status | Submissions    |
|--------------------------|---------------|----------------|
| Likely Benign; Other     | 2-star        | 2 contributing |

**Issue:** 1 submission is classified as "other" (Eurofins Ntd Llc) but is noted as being benign. In this case, the "other" classification appears to count toward the Benign classification, raising the aggregate from 1-star to 2-star.

## Analysis

### Inconsistent Behavior

In Example 2, the "other" classification appears to be treated as equivalent to "Benign" for aggregation purposes, which raises the review status from 1-star to 2-star.

This behavior is:

- **Confusing at best** — it is not evident to users that "other" should be treated as Benign during aggregation
- **Misleading at worst** — the aggregate classification doesn't accurately reflect the underlying submission classifications

### Inconsistency Between Examples

If "other" should be treated as "benign," ClinVar should indicate this more clearly and consistently:

- In **Example 1**: 13 "path" and "likely path" submissions + 1 "other" (noted as benign) → No conflict flagged, "other" is grouped with Path/Likely Path
- In **Example 2**: 1 "likely benign" + 1 "other" (noted as benign) → "Other" contributes to 2-star status

## Recommendation

Non-pathogenicity-related classification-based SCVs should **not** be bundled with standard pathogenicity classifications. This includes:

- Other
- Drug response
- Association
- Protective
- Risk factor
- Confers sensitivity

## Questions for ClinVar Team

1. **Is this behavior a bug?**
   - If **no**: Please explain the rule governing how "other" is handled so it can be tested and applied downstream
   - If **yes**: Please clarify how "other" classifications **should** be handled going forward

2. **What is the expected aggregation logic** when an "other" submission has a benign annotation?
