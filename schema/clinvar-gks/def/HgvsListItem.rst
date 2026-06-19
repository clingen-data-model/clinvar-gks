.. warning:: This data class is at a **draft** maturity level and may \
    change significantly in future releases. Maturity \
    levels are described in the :ref:`maturity-model`.

**Computational Definition**

A complex structure for sharing individual HGVS entries associated with Clinvar Variations including nucleotide expressions, protein expressions, molecular consequence and mane select/plus settings for the specific aligned and projected forms of the clinvar variant.

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
   *  - nucleotideExpression
      -
      - :ref:`Expression`
      - 0..1
      - The nucleotide HGVS expression with `syntax` (e.g.,` hgvs.c`, `hgvs.g`)  and `value` (the HGVS string).
   *  - nucleotideType
      -
      - string
      - 0..1
      - The type of nucleotide expression as reported by ClinVar (e.g., `coding`,  `genomic`, `genomic, top-level`).
   *  - maneSelect
      -
      - boolean
      - 0..1
      - `true` if this transcript is designated as MANE Select. Absent or `false` when  not applicable.
   *  - manePlus
      -
      - boolean
      - 0..1
      - `true` if this transcript is designated as MANE Plus Clinical. Absent or `false`  when not applicable.
   *  - proteinExpression
      -
      - :ref:`Expression`
      - 0..1
      - The protein HGVS expression with syntax (typically `hgvs.p`) and `value`. Present  only when a protein-level expression exists for the nucleotide expression.
   *  - molecularConsequence
      -
                        .. raw:: html

                            <span style="background-color: #B2DFEE; color: black; padding: 2px 6px; border: 1px solid black; border-radius: 3px; font-weight: bold; display: inline-block; margin-bottom: 5px;" title="Unordered">&#8942;</span>
      - :ref:`Coding`
      - 0..m
      - Sequence Ontology terms describing the predicted molecular consequence.  Each entry includes `code` (SO identifier), `system`, `name` (SO term label),  and `iris` (identifiers.org link).
