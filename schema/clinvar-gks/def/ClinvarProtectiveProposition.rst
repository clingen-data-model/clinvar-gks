.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A proposition describing the protective role of a variant against a condition. Used for ClinVar submissions classified as "protective". ClinVar has stopped accepting new submissions with this classification, but historical submissions remain.

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
      - MUST be "ClinvarProtectiveProposition".
   *  - predicate
      -
      - string
      - 1..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isProtectiveFor".
   *  - objectCondition
      -
      - :ref:`Condition` | :ref:`iriReference`
      - 1..1
      - The condition against which the variant is protective.
