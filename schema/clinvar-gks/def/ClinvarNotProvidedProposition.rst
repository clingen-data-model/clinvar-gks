.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A proposition for ClinVar submissions where the submitter did not provide a clinical classification. These submissions still carry variant-condition associations but lack a formal pathogenicity or clinical significance assessment.

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
      - MUST be "ClinvarNotProvidedProposition".
   *  - predicate
      -
      - string
      - 1..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "hasNoProvidedClassificationFor".
   *  - objectCondition
      -
      - :ref:`Condition` | :ref:`iriReference`
      - 1..1
      - The condition for which no classification was provided.
