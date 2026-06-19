.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

An evidence line for ClinVar somatic clinical impact (SCI) statements. Carries a target proposition (therapeutic response, diagnostic, or prognostic) and an evidence outcome reflecting the AMP/ASCO/CAP tiered classification. SCI statements use this evidence line to link the parent VariantClinicalSignificanceProposition to specific clinical assertion types.

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
