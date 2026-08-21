.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A custom proposition describing the role of a variant as a risk factor for a condition. Used for ClinVar submissions classified as "risk factor". ClinVar has stopped accepting new submissions with this classification in favor of standard pathogenicity terms, but historical submissions remain.

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
   *  - customPropositionType
      -
      - string
      - 0..1
      - MUST be "ClinvarRiskFactorProposition"
   *  - predicate
      -
      - string
      - 0..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isRiskFactorFor".
