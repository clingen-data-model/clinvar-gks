.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A ClinVar canonical allele — the most common variant type. ClinVar identifies each variation by mapping submitted attributes to a GRCh38 genomic allele, which becomes the defining allele constraint. Carries ClinVar-specific extensions (HGVS list, gene list, cytogenetic location, variation type, etc.) alongside the Cat-VRS CanonicalAllele structure.

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
