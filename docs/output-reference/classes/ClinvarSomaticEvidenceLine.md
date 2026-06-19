# ClinvarSomaticEvidenceLine

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

An evidence line for ClinVar somatic clinical impact (SCI) statements. Carries a target proposition (therapeutic response, diagnostic, or prognostic) and an evidence outcome reflecting the AMP/ASCO/CAP tiered classification. SCI statements use this evidence line to link the parent VariantClinicalSignificanceProposition to specific clinical assertion types.

**JSON Schema:** [ClinvarSomaticEvidenceLine](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarSomaticEvidenceLine){ target=_blank }

Some ClinvarSomaticEvidenceLine attributes are inherited from [EvidenceLine](EvidenceLine.md), [ClinvarSomaticEvidenceLineProperties](ClinvarSomaticEvidenceLineProperties.md).

## Information Model

| Field | Type | Limits | Description |
| --- | --- | --- | --- |
| `id` | `string` | 0..1 | The 'logical' identifier of the Entity in the system of record, e.g. a UUID.  This 'id' is unique within a given system, but may or may not be globally unique outside the system. It is used within a system to reference an object from another. |
| `name` | `string` | 0..1 | A primary name for the entity. |
| `description` | `string` | 0..1 | A free-text description of the Entity. |
| `aliases` | `string`[] (unordered) | 0..m | Alternative name(s) for the Entity. |
| `extensions` | `Extension`[] (unordered) | 0..m | A list of extensions to the Entity, that allow for capture of information not directly supported by elements defined in the model. |
| `specifiedBy` | `Method` \| `iriReference` | 0..1 | A specification that describes all or part of the process that led to creation of the Information Entity |
| `contributions` | `Contribution`[] (ordered) | 0..m | Specific actions taken by an Agent toward the creation, modification, validation, or deprecation of an Information Entity. |
| `reportedIn` | `Document` \| `iriReference`[] (unordered) | 0..m | A document in which the the Information Entity is reported. |
| `type` | `string` | 0..1 | MUST be "EvidenceLine". |
| `targetProposition` | `Proposition` | 0..1 | The possible fact against which evidence items contained in an Evidence Line were collectively evaluated, in determining the overall strength and direction of support they provide. For example, in an ACMG Guideline-based assessment of variant pathogenicity, the support provided by distinct lines of evidence are assessed against a target proposition that the variant is pathogenic for a specific disease. |
| `hasEvidenceItems` | `StudyResult` \| `Statement` \| `EvidenceLine` \| `iriReference`[] (unordered) | 0..m | An individual piece of information that was evaluated as evidence in building the argument represented by an Evidence Line. |
| `directionOfEvidenceProvided` | `string` | 0..1 | The direction of support that the Evidence Line is determined to provide toward its target Proposition (supports, disputes, neutral) |
| `strengthOfEvidenceProvided` | `MappableConcept` | 0..1 | The strength of support that an Evidence Line is determined to provide for or against its target Proposition, evaluated relative to the direction indicated by the directionOfEvidenceProvided value. |
| `scoreOfEvidenceProvided` | `number` | 0..1 | A quantitative score indicating the strength of support that an Evidence Line is determined to provide for or against its target Proposition, evaluated relative to the direction indicated by the directionOfEvidenceProvided value. |
| `evidenceOutcome` | `MappableConcept` | 0..1 | The evidence level outcome for the somatic clinical impact assertion, based on the AMP/ASCO/CAP tiered evidence framework. Values reflect the tier mapping (e.g., "Level A/B" for Tier I, "Level C/D" for Tier II). Present only on somatic clinical impact evidence lines. |
| `proposition` | `VariantTherapeuticResponseProposition` \| `VariantDiagnosticProposition` \| `VariantPrognosticProposition` \| `iriReference` | 0..1 | The target proposition for this evidence line. For somatic clinical impact statements, this is one of the specific assertion type propositions: VariantTherapeuticResponseProposition (TR), VariantDiagnosticProposition (DIAG), or VariantPrognosticProposition (PROG). |

