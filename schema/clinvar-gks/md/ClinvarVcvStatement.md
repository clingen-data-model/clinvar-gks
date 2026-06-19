# ClinvarVcvStatement

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar VCV (variant classification variant) statement. Represents an aggregate classification for a variant across all submissions sharing the same proposition type. VCV statements contain evidence lines that group contributing SCV submissions by review status priority tier (practice guideline, expert panel, criteria provided, no criteria provided).
VCV statements use the same 12 proposition types as SCV statements. Evidence lines at the VCV level contain nested sub-statements at the classification layer, each carrying the same proposition type as the parent but scoped to a specific priority tier. The innermost layer references individual SCV submissions as evidence items.

**JSON Schema:** [ClinvarVcvStatement](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarVcvStatement){ target=_blank }

**Composed of:**

- [Statement](Statement.md)
- [ClinvarAggregateStatementProperties](ClinvarAggregateStatementProperties.md)

