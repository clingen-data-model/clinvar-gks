# ClinvarSomaticEvidenceLine

!!! warning "Draft"

    This data class is at a **draft** maturity level and may change significantly in future releases.

An evidence line for ClinVar somatic clinical impact (SCI) statements. Carries a target proposition (therapeutic response, diagnostic, or prognostic) and an evidence outcome reflecting the AMP/ASCO/CAP tiered classification. SCI statements use this evidence line to link the parent VariantClinicalSignificanceProposition to specific clinical assertion types.

**JSON Schema:** [ClinvarSomaticEvidenceLine](https://github.com/clingen-data-model/clinvar-gks/blob/main/schema/clinvar-gks/json/ClinvarSomaticEvidenceLine){ target=_blank }

**Composed of:**

- [EvidenceLine](EvidenceLine.md)
- [ClinvarSomaticEvidenceLineProperties](ClinvarSomaticEvidenceLineProperties.md)

