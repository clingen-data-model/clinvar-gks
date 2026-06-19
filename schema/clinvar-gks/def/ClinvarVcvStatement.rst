.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A ClinVar VCV (variant classification variant) statement. Represents an aggregate classification for a variant across all submissions sharing the same proposition type. VCV statements contain evidence lines that group contributing SCV submissions by review status priority tier (practice guideline, expert panel, criteria provided, no criteria provided).
VCV statements use the same 12 proposition types as SCV statements. Evidence lines at the VCV level contain nested sub-statements at the classification layer, each carrying the same proposition type as the parent but scoped to a specific priority tier. The innermost layer references individual SCV submissions as evidence items.

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
