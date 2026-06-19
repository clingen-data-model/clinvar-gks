.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A proposition describing a statistical or observational association between a variant and a condition. Used for ClinVar submissions classified as "association". Does not imply a causal relationship.

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
      - MUST be "ClinvarAssociationProposition".
   *  - predicate
      -
      - string
      - 1..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isAssociatedWith".
   *  - objectCondition
      -
      - :ref:`Condition` | :ref:`iriReference`
      - 1..1
      - The condition with which the variant is associated.
