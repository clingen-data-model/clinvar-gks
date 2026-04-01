# Propositions (Steps 2--6)

## Overview

Steps 2--6 of `gks_scv_statement_proc` build the qualifier tables and assemble the primary and target propositions for each SCV. Qualifiers capture gene context, mode of inheritance, and penetrance; propositions combine the variant, condition, and qualifiers into the structured assertion that forms the core of each VA-Spec Statement.

---

## Steps 2--4: Qualifier Tables

### Step 2: Build `temp_gene_context_qualifiers`

Extracts gene context from `single_gene_variation` by matching each SCV's variation_id to its associated gene. For each match, builds a gene concept with:

- **conceptType**: `"gene"`
- **primaryCoding**: NCBI Gene identifier using both `identifiers.org` and NCBI Gene URLs
- **HGNC mappings**: When an HGNC identifier is available, included as an additional coding
- **submittedGeneSymbols extension**: Gene symbols from `clinical_assertion_variation`, preserving the submitter's original gene annotations

When no single-gene match exists for a variation, the qualifier falls back to a record noting that "submitted genes were not normalized."

**Output:** `temp_gene_context_qualifiers` -- one row per SCV+gene combination. <span class="role-badge badge-internal">Internal</span>

---

### Step 3: Build `temp_moi_qualifiers`

Extracts ModeOfInheritance from assertion attributes in `clinical_assertion`. When a matching HPO term is available, the qualifier includes a `primaryCoding` with the HPO term identifier and label. All qualifiers include a `submittedModeOfInheritance` extension preserving the original submitted value.

**Output:** `temp_moi_qualifiers` -- one row per SCV with mode of inheritance. <span class="role-badge badge-internal">Internal</span>

---

### Step 4: Build `temp_penetrance_qualifiers`

Derives penetrance qualifiers for specific classification types:

| Classification Category | Penetrance Value |
|---|---|
| Pathogenic-low penetrance (`p-lp`), Likely pathogenic-low penetrance (`lp-lp`) | `"low"` |
| Established risk allele (`era`), Likely risk allele (`lra`), Uncertain risk allele (`ura`) | `"risk"` |

Each penetrance qualifier includes a `submittedClassification` extension preserving the original classification label that triggered the penetrance derivation.

**Output:** `temp_penetrance_qualifiers` -- one row per qualifying SCV. <span class="role-badge badge-internal">Internal</span>

---

## Step 5: Primary Proposition

Assembles the SCV proposition by joining `temp_gks_scv` with all qualifier tables and condition sets from `gks_scv_condition_sets`. The resulting proposition contains:

| Field | Description |
|---|---|
| `type` | Proposition type from Step 1 mapping (e.g., `VariantPathogenicityProposition`) |
| `subjectVariant` | Reference to the categorical variant via `clinvar:{variation_id}` |
| `predicate` | Predicate from Step 1 mapping (e.g., `isCausalFor`, `isOncogenicFor`) |
| `objectCondition_single` | Single condition from the condition pipeline |
| `objectCondition_compound` | ConditionSet for SCVs with multiple conditions |
| `geneContextQualifier` | Gene concept from Step 2 |
| `modeOfInheritanceQualifier` | Mode of inheritance from Step 3 |
| `penetranceQualifier` | Penetrance from Step 4 |

**Output:** `temp_gks_scv_proposition` -- one row per SCV with fully assembled proposition. <span class="role-badge badge-internal">Internal</span>

---

## Step 6: Target Proposition (Somatic)

Builds the evidence line target proposition for somatic clinical impact assertions. This proposition uses the `evidence_line_target_proposition` type and predicate derived in Step 1 and adds somatic-specific fields:

| Field | Description |
|---|---|
| `type` | Target proposition type (e.g., `VariantPrognosticProposition`, `VariantTherapeuticResponseProposition`) |
| `subjectVariant` | JSON pointer `4/proposition/subjectVariant` referencing the parent proposition's variant |
| `predicate` | Target predicate (e.g., `associatedWithBetterOutcomeFor`, `predictsSensitivityTo`) |
| `objectTherapy_single` | Single drug therapy for therapeutic assertions |
| `objectTherapy_compound` | Compound therapy for multi-drug therapeutic assertions |
| `conditionQualifier` | Condition moved to qualifier position for therapeutic assertions (since `objectCondition` becomes the therapy) |
| `geneContextQualifier` | Gene concept from Step 2 |
| `modeOfInheritanceQualifier` | Mode of inheritance from Step 3 |

The JSON pointer `4/proposition/subjectVariant` is used instead of duplicating the variant reference, linking the target proposition back to the same variant defined in the parent (Step 5) proposition.

**Output:** `temp_gks_scv_target_proposition` -- one row per somatic SCV with target proposition. <span class="role-badge badge-internal">Internal</span>

---

## Dependencies

- **Source Tables**: `single_gene_variation`, `clinical_assertion`, `clinical_assertion_variation`, `gene`
- **Lookup Tables**: `hpo_terms`
- **Upstream Steps**: Step 1 (`temp_gks_scv`), condition pipeline (`gks_scv_condition_sets`)
