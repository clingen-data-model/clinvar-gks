.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A ClinVar SCV (submitted clinical variant) statement. Represents a single submitter's assertion about a variant-condition relationship, including their classification, direction, strength, method, and contributions.
Allowable proposition types at SCV level:
Germline classification (9 types): VariantPathogenicityProposition, ClinvarRiskFactorProposition, ClinvarProtectiveProposition, ClinvarDrugResponseProposition, ClinvarAffectsProposition, ClinvarAssociationProposition, ClinvarConfersSensitivityProposition, ClinvarOtherProposition, ClinvarNotProvidedProposition.
Oncogenicity (1 type): VariantOncogenicityProposition.
Somatic clinical impact (1 type): VariantClinicalSignificanceProposition with evidence lines carrying VariantTherapeuticResponseProposition, VariantDiagnosticProposition, or VariantPrognosticProposition.
Conflicting data (1 type): ClinvarConflictingDataFromSubmitterProposition.

**Information Model**


.. list-table::
   :class: clean-wrap
   :header-rows: 1
   :align: left
   :widths: auto

   *  - Field
      - Flags
      - Type
      - Limits
      - Description
