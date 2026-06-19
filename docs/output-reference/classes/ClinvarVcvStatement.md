# ClinvarVcvStatement

!!! info "Trial Use"

    This data class is at a **trial use** maturity level and may change in future releases. Maturity levels are described in the [GKS Maturity Model](https://vrs.ga4gh.org/en/2.0/appendices/maturity_model.html#maturity-model).

A ClinVar VCV (variant-level aggregate) statement. Aggregates all SCV submissions for the same variant and proposition type into a single classification, regardless of condition.

### Aggregation

VCV statements are built through a multi-layer hierarchy:

- **Classification layer** — groups SCVs by classification label within a submission level
- **Priority layer** — groups by tier within a submission level (somatic only)
- **Aggregate Contribution layer** — applies winner-takes-all ranking across submission levels (`PG > EP > CP > NOCP > NOCL > FLAG`)

Evidence lines at each layer reference either SCV submissions or lower-level VCV groupings. See [VCV Statements](../vcv-statements.md#layer-hierarchy) for the full aggregation rules.

### Proposition Types

VCV statements use the same 12 proposition types as SCV statements. See [ClinvarScvStatement — Proposition Types](ClinvarScvStatement.md#proposition-types) for the full list.

**JSON Schema:** [ClinvarVcvStatement](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarVcvStatement){ target=_blank }

Some ClinvarVcvStatement attributes are inherited from `Statement`, `ClinvarAggregateStatementProperties`.

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | Aggregate-level extensions. See [VCV Statements — Extensions](../vcv-statements.md#extensions) for the complete list of extension names, value types, and descriptions. |
| `specifiedBy` | `Method` \| `iriReference` | 0..1 | A specification that describes all or part of the process that led to creation of the Information Entity |
| `contributions` | `Contribution`[] (ordered) | 0..m | Specific actions taken by an Agent toward the creation, modification, validation, or deprecation of an Information Entity. |
| `reportedIn` | `Document` \| `iriReference`[] (unordered) | 0..m | A document in which the the Information Entity is reported. |
| `type` | `string` | 0..1 | MUST be "Statement". |
| `proposition` | [ClinvarProposition](ClinvarProposition.md) \| `iriReference` | 0..1 | The aggregate proposition assessed by this VCV or RCV statement. Uses the same proposition types as SCV statements. The proposition at the aggregate level represents the consensus or highest-priority classification across contributing submissions. |
| `direction` | `string` | 0..1 | A term indicating whether the Statement supports, disputes, or remains neutral w.r.t. the validity of the Proposition it evaluates. |
| `strength` | `MappableConcept` | 0..1 | A term used to report the strength of a Proposition's assessment in the direction indicated (i.e. how strongly supported or disputed the Proposition is believed to be).  Implementers may choose to frame a strength assessment in terms of how *confident* an agent is that the Proposition is true or false, or in terms of the *strength of all evidence* they believe supports or disputes it. |
| `score` | `number` (draft) | 0..1 | A quantitative score that indicates the strength of a Proposition's assessment in the direction indicated (i.e. how strongly supported or disputed the Proposition is believed to be). Depending on its implementation, a score may reflect how *confident* that agent is that the Proposition is true or false, or the *strength of evidence* they believe supports or disputes it. Instructions for how to interpret the meaning of a given score may be gleaned from the method or document referenced in 'specifiedBy' attribute. |
| `classification` | `MappableConcept` | 0..1 | A single term or phrase summarizing the outcome of direction and strength assessments of a Statement's Proposition, in terms of a classification of its subject. |
| `hasEvidenceLines` | `EvidenceLine` \| `iriReference`[] (unordered) | 0..m | Evidence lines grouping contributing submissions by review status priority tier. Each evidence line contains nested sub-statements (classification layer) or SCV references (aggregate contribution layer). Tiers are: practice guideline (PG), expert panel (EP), criteria provided (CP), and no criteria provided (NOCP). |

