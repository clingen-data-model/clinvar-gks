# ClinvarScvStatement

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

A ClinVar SCV (submitted clinical variant) statement. Represents a single submitter's assertion about a variant-condition relationship, including their classification, direction, strength, method, and contributions.
Allowable proposition types at SCV level:
Germline classification (9 types): VariantPathogenicityProposition, ClinvarRiskFactorProposition, ClinvarProtectiveProposition, ClinvarDrugResponseProposition, ClinvarAffectsProposition, ClinvarAssociationProposition, ClinvarConfersSensitivityProposition, ClinvarOtherProposition, ClinvarNotProvidedProposition.
Oncogenicity (1 type): VariantOncogenicityProposition.
Somatic clinical impact (1 type): VariantClinicalSignificanceProposition with evidence lines carrying VariantTherapeuticResponseProposition, VariantDiagnosticProposition, or VariantPrognosticProposition.
Conflicting data (1 type): ClinvarConflictingDataFromSubmitterProposition.

**JSON Schema:** [ClinvarScvStatement](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarScvStatement){ target=_blank }

Some ClinvarScvStatement attributes are inherited from `Statement`, `ClinvarScvStatementProperties`.

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | SCV-level extensions including submission metadata, review status, and condition mapping. See [SCV Statements — Extensions](../scv-statements.md#extensions) for the complete list of extension names, value types, and custom type definitions. |
| `specifiedBy` | `Method` \| `iriReference` | 0..1 | A specification that describes all or part of the process that led to creation of the Information Entity |
| `contributions` | `Contribution`[] (ordered) | 0..m | Specific actions taken by an Agent toward the creation, modification, validation, or deprecation of an Information Entity. |
| `reportedIn` | `Document` \| `iriReference`[] (unordered) | 0..m | A document in which the the Information Entity is reported. |
| `type` | `string` | 0..1 | MUST be "Statement". |
| `proposition` | [ClinvarProposition](ClinvarProposition.md) \| `iriReference` | 0..1 | The proposition assessed by this SCV statement. Must be one of the GA4GH standard proposition types (pathogenicity, oncogenicity, clinical significance) or a ClinVar-specific proposition type (risk factor, protective, drug response, affects, association, confers sensitivity, other, not provided, conflicting data). |
| `direction` | `string` | 0..1 | A term indicating whether the Statement supports, disputes, or remains neutral w.r.t. the validity of the Proposition it evaluates. |
| `strength` | `MappableConcept` | 0..1 | A term used to report the strength of a Proposition's assessment in the direction indicated (i.e. how strongly supported or disputed the Proposition is believed to be).  Implementers may choose to frame a strength assessment in terms of how *confident* an agent is that the Proposition is true or false, or in terms of the *strength of all evidence* they believe supports or disputes it. |
| `score` | `number` (draft) | 0..1 | A quantitative score that indicates the strength of a Proposition's assessment in the direction indicated (i.e. how strongly supported or disputed the Proposition is believed to be). Depending on its implementation, a score may reflect how *confident* that agent is that the Proposition is true or false, or the *strength of evidence* they believe supports or disputes it. Instructions for how to interpret the meaning of a given score may be gleaned from the method or document referenced in 'specifiedBy' attribute. |
| `classification` | `MappableConcept` | 0..1 | A single term or phrase summarizing the outcome of direction and strength assessments of a Statement's Proposition, in terms of a classification of its subject. |
| `hasEvidenceLines` | [ClinvarSomaticEvidenceLine](ClinvarSomaticEvidenceLine.md) \| `EvidenceLine` \| `iriReference`[] (unordered) | 0..m | Evidence lines for this SCV statement. For somatic clinical impact (SCI) statements, evidence lines carry target propositions (VariantTherapeuticResponseProposition, VariantDiagnosticProposition, or VariantPrognosticProposition) and an evidence outcome reflecting the AMP/ASCO/CAP tier. Germline and oncogenicity SCVs typically do not have evidence lines. |

