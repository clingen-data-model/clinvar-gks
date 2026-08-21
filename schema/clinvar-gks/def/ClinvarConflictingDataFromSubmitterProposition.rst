.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A proposition for ClinVar submissions where the submitter's data conflicts with other submitters' data for the same variant-condition pair. Used for submissions classified as "conflicting data from submitters".

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
      - MUST be "ClinvarConflictingDataFromSubmitterProposition".
   *  - predicate
      -
      - string
      - 0..1
      - The relationship the Proposition describes between the subject variant and object condition. MUST be "isConflictingDataFromSubmittersFor".
