# Statements

ClinVar-GKS statements are profiles of the GA4GH [VA-Spec Statement](https://va-spec.ga4gh.org/) type. They exist at three levels of aggregation, each carrying a [ClinvarProposition](ClinvarProposition.md) that defines what is being asserted.

The [ClinvarStatement](ClinvarStatement.md) union type encompasses all three:

| Level | Profile | Bundle Section | Description |
| --- | --- | --- | --- |
| Submission | [ClinvarScvStatement](ClinvarScvStatement.md) | `scv` | A single submitter's clinical classification |
| Variant aggregate | [ClinvarVcvStatement](ClinvarVcvStatement.md) | `vcv` | Aggregate across all submissions for a variant + proposition type |
| Condition aggregate | [ClinvarRcvStatement](ClinvarRcvStatement.md) | `rcv` | Aggregate scoped to a specific variant + condition pair |

---

## SCV Statements

Each SCV represents one submitter's assertion about a variant-condition relationship. SCV statements carry:

- **Classification** — the submitter's clinical classification (e.g., Pathogenic, Likely benign, Tier I - Strong)
- **Direction** — whether the evidence `supports`, `disputes`, or is `neutral` toward the proposition
- **Strength** — the strength of the assessment (e.g., definitive, likely)
- **Contributions** — submitter identity and dates (submitted, created, evaluated) with `#/submitter/` references
- **Method** — the classification guideline used (e.g., ACMG Guidelines 2015, AMP/ASCO/CAP Guidelines 2017)

### SCV Extensions

| Extension | Description |
| --- | --- |
| `clinvarScvId` | SCV accession without version (e.g., `SCV001571657`) |
| `clinvarScvVersion` | Version number |
| `clinvarScvReviewStatus` | Review status (e.g., `criteria provided, single submitter`) |
| `submissionLevel` | Aggregation tier: `PG`, `EP`, `CP`, or `NOCP` |
| `submittedScvLocalKey` | Submitter's internal identifier |
| `submittedScvClassification` | Original classification before normalization (when different) |
| `submittedCondition` | Submitter's original condition for single-condition submissions |
| `submittedConditionSet` | Submitter's original conditions for multi-condition submissions |

The `submittedCondition` and `submittedConditionSet` extensions carry a [SubmittedConditionMapping](SubmittedConditionMapping.md) that traces how the submitter's original condition was mapped to the ClinVar canonical condition.

---

## VCV and RCV Statements

Aggregate statements group SCV submissions into a hierarchical evidence structure. Both VCV and RCV follow the same three-layer pattern:

1. **Classification layer** — groups SCVs by classification label (e.g., all "Pathogenic" submissions)
2. **Priority layer** — groups by review status tier (practice guideline > expert panel > criteria provided > no criteria provided)
3. **Aggregate contribution layer** — references individual SCV submissions as evidence items

Each layer is connected via `hasEvidenceLines`, with nested sub-statements carrying the same proposition type as the parent but scoped to a specific tier or classification group.

### Aggregate Extensions

| Extension | Description |
| --- | --- |
| `clinvarReviewStatus` | The highest review status among contributing submissions |

### VCV vs RCV

- **VCV** statements aggregate across all conditions for a variant — the `objectCondition` on the proposition may reference multiple conditions or a condition set
- **RCV** statements are scoped to a single ClinVar RCV accession (one variant + one condition combination)
