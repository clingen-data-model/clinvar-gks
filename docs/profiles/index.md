# Statement Profiles

This section describes the fundamental aspects of how ClinVar data is organized and transformed into GKS standard statements within the ClinVar-GKS pipeline.

## Overview

ClinVar submissions (SCVs) are the baseline statements submitted to ClinVar by clinical laboratories, expert panels, and other organizations. ClinVar aggregates these submissions using different rules for specific statement types to produce higher-order statements (RCVs and VCVs).

ClinVar-GKS maps each submission to a specific **statement type**, **proposition profile**, and **classification** with corresponding **direction** and **strength** values conforming to the GA4GH VA-Spec standard.

## Sections

- [Statement Types](statement-types.md) — the 14 statement types and their categories
- [Classifications](classifications.md) — classification values mapped to direction and strength
- [Propositions](propositions.md) — mapping of statement types to GKS proposition types
- [Review Status](review-status.md) — star levels, rank order, and aggregation behavior
