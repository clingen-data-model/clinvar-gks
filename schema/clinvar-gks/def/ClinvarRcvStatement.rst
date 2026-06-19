.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A ClinVar RCV (reference clinical variant) statement. Represents an aggregate classification for a specific variant-condition pair across all submissions sharing the same proposition type and condition. RCV statements contain evidence lines that group contributing SCV submissions by review status priority tier, scoped to a single condition or condition set.
RCV statements use the same 12 proposition types as SCV statements. Unlike VCV statements which aggregate across all conditions for a variant, RCV statements are scoped to a single condition. Evidence lines at the RCV level follow the same priority tier structure as VCV statements.

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
