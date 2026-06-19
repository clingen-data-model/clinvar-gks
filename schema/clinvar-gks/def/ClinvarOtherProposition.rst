.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A proposition for ClinVar submissions classified as "other" that do not fit any standard or named classification category. ClinVar has stopped accepting new submissions with this classification, but historical submissions remain.

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
   *  - type
      -
      - string
      - 0..1
      - MUST be "ClinvarOtherProposition".
   *  - predicate
      -
      - string
      - 1..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isClinvarOtherAssociationFor".
   *  - objectCondition
      -
      - :ref:`Condition` | :ref:`iriReference`
      - 1..1
      - The condition associated with the variant.
