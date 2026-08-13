.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A fallback custom proposition for a ClinVar submission whose classification does not map to any defined ClinVar-GKS or GA4GH proposition type. Emitted only when the upstream classification-to-type mapping yields no gks_type.

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
      - MUST be "ClinvarUndefinedProposition"
   *  - predicate
      -
      - string
      - 0..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isClinvarUndefinedAssociationFor".
