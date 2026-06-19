# MkDocs Schema Pages Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire 23 generated Markdown class pages into the MkDocs site with lead-in pages and organized nav structure for Variations, Propositions, Statements, and Evidence groups.

**Architecture:** Generated `.md` files from `schema/clinvar-gks/md/` are copied into `docs/output-reference/classes/` at build time. Four hand-written lead-in pages provide narrative context for each group. The `mkdocs.yml` nav is updated to organize classes into logical sections under Data Model.

**Tech Stack:** MkDocs Material theme, Markdown, existing `make all` build system

---

## File Structure

### New files to create

| File | Responsibility |
|---|---|
| `docs/output-reference/classes/variations.md` | Lead-in: Cat-VRS types, how ClinVar maps variants, extension overview |
| `docs/output-reference/classes/propositions.md` | Lead-in: subject-predicate-object pattern, type/code/predicate table, GA4GH vs ClinVar-specific |
| `docs/output-reference/classes/statements.md` | Lead-in: SCV/VCV/RCV layers, aggregation overview, extension summary |
| `docs/output-reference/classes/evidence.md` | Lead-in: somatic SCI evidence lines, tier mapping, TR/DIAG/PROG |

### Files to copy (from `schema/clinvar-gks/md/` → `docs/output-reference/classes/`)

23 generated class pages. These are copied (not symlinked) so MkDocs can serve them directly:

**Variations group (7):** `ClinvarCategoricalVariant.md`, `ClinvarCanonicalAllele.md`, `ClinvarCategoricalCnvChange.md`, `ClinvarCategoricalCnvCount.md`, `ClinvarNonConstrainedVariant.md`, `HgvsListItem.md`, `GeneListItem.md`

**Propositions group (10):** `ClinvarProposition.md`, `ClinvarRiskFactorProposition.md`, `ClinvarProtectiveProposition.md`, `ClinvarDrugResponseProposition.md`, `ClinvarAffectsProposition.md`, `ClinvarAssociationProposition.md`, `ClinvarConfersSensitivityProposition.md`, `ClinvarOtherProposition.md`, `ClinvarNotProvidedProposition.md`, `ClinvarConflictingDataFromSubmitterProposition.md`

**Statements group (5):** `ClinvarStatement.md`, `ClinvarScvStatement.md`, `ClinvarVcvStatement.md`, `ClinvarRcvStatement.md`, `SubmittedConditionMapping.md`

**Evidence group (1):** `ClinvarSomaticEvidenceLine.md`

### Files to modify

| File | Change |
|---|---|
| `mkdocs.yml` | Update Data Model nav section with grouped sub-pages |
| `docs/output-reference/classes/index.md` | Update class links to point to new sub-page paths |

---

## Chunk 1: Copy generated pages and update nav

### Task 1: Copy generated Markdown pages into docs

**Files:**
- Copy: `schema/clinvar-gks/md/*.md` → `docs/output-reference/classes/`

- [ ] **Step 1: Copy all 23 generated md files**

```bash
cp schema/clinvar-gks/md/*.md docs/output-reference/classes/
```

- [ ] **Step 2: Verify all 23 files are present**

```bash
ls docs/output-reference/classes/*.md | wc -l
# Expected: 24 (23 class pages + index.md)
```

- [ ] **Step 3: Commit**

```bash
git add docs/output-reference/classes/
git commit -m "Copy generated class Markdown pages into docs"
```

### Task 2: Update mkdocs.yml nav structure

**Files:**
- Modify: `mkdocs.yml:59-74` (Data Model section)

Replace the existing Data Model nav entry:

```yaml
    - Data Model:
      - output-reference/classes/index.md
```

With the grouped structure:

```yaml
    - Data Model:
      - output-reference/classes/index.md
      - Variations:
        - output-reference/classes/variations.md
        - ClinvarCategoricalVariant: output-reference/classes/ClinvarCategoricalVariant.md
        - ClinvarCanonicalAllele: output-reference/classes/ClinvarCanonicalAllele.md
        - ClinvarCategoricalCnvChange: output-reference/classes/ClinvarCategoricalCnvChange.md
        - ClinvarCategoricalCnvCount: output-reference/classes/ClinvarCategoricalCnvCount.md
        - ClinvarNonConstrainedVariant: output-reference/classes/ClinvarNonConstrainedVariant.md
        - HgvsListItem: output-reference/classes/HgvsListItem.md
        - GeneListItem: output-reference/classes/GeneListItem.md
      - Propositions:
        - output-reference/classes/propositions.md
        - ClinvarProposition: output-reference/classes/ClinvarProposition.md
        - ClinvarRiskFactorProposition: output-reference/classes/ClinvarRiskFactorProposition.md
        - ClinvarProtectiveProposition: output-reference/classes/ClinvarProtectiveProposition.md
        - ClinvarDrugResponseProposition: output-reference/classes/ClinvarDrugResponseProposition.md
        - ClinvarAffectsProposition: output-reference/classes/ClinvarAffectsProposition.md
        - ClinvarAssociationProposition: output-reference/classes/ClinvarAssociationProposition.md
        - ClinvarConfersSensitivityProposition: output-reference/classes/ClinvarConfersSensitivityProposition.md
        - ClinvarOtherProposition: output-reference/classes/ClinvarOtherProposition.md
        - ClinvarNotProvidedProposition: output-reference/classes/ClinvarNotProvidedProposition.md
        - ClinvarConflictingDataFromSubmitterProposition: output-reference/classes/ClinvarConflictingDataFromSubmitterProposition.md
      - Statements:
        - output-reference/classes/statements.md
        - ClinvarStatement: output-reference/classes/ClinvarStatement.md
        - ClinvarScvStatement: output-reference/classes/ClinvarScvStatement.md
        - ClinvarVcvStatement: output-reference/classes/ClinvarVcvStatement.md
        - ClinvarRcvStatement: output-reference/classes/ClinvarRcvStatement.md
        - SubmittedConditionMapping: output-reference/classes/SubmittedConditionMapping.md
      - Evidence:
        - output-reference/classes/evidence.md
        - ClinvarSomaticEvidenceLine: output-reference/classes/ClinvarSomaticEvidenceLine.md
```

- [ ] **Step 1: Update mkdocs.yml Data Model nav section**

- [ ] **Step 2: Run `mkdocs build --strict` to validate**

```bash
mkdocs build --strict
```

Expected: Build succeeds with no errors (warnings about missing lead-in pages are OK at this step)

- [ ] **Step 3: Commit**

```bash
git add mkdocs.yml
git commit -m "Update Data Model nav with grouped class pages"
```

---

## Chunk 2: Write lead-in pages

### Task 3: Write Variations lead-in page

**Files:**
- Create: `docs/output-reference/classes/variations.md`

Content outline:
- Title: "Variations"
- Intro: How ClinVar variations are represented using GA4GH Cat-VRS types
- Section: Three Cat-VRS recipes used (CanonicalAllele, CategoricalCnv, CategoricalVariant) with brief description and link to class page
- Section: ClinVar-specific extensions overview — what extensions are carried on all variant types (HGVS list, gene list, cytogenetic location, variation type, etc.) with links to HgvsListItem and GeneListItem pages
- Section: VRS composition chain — how variants reference alleles, locations, and sequence references via `#/` pointers (brief, links to existing pipeline docs)
- Reference existing content from `docs/output-reference/cat-vrs.md` for tone and detail level

- [ ] **Step 1: Write `docs/output-reference/classes/variations.md`**
- [ ] **Step 2: Run `mkdocs build --strict` to validate**
- [ ] **Step 3: Commit**

### Task 4: Write Propositions lead-in page

**Files:**
- Create: `docs/output-reference/classes/propositions.md`

Content outline:
- Title: "Propositions"
- Intro: Subject-predicate-object pattern — what propositions represent
- Section: Complete table of all 12 proposition types with Code, Type, Predicate, Description columns (match existing table in `docs/output-reference/scv-statements.md:135-148` and `docs/profiles/propositions.md`)
- Section: GA4GH standard types (3) — brief note that these come from VA-Spec, link to va-spec.ga4gh.org
- Section: ClinVar-specific types (9) — note that several are deprecated by ClinVar but historical submissions remain
- Section: Somatic sub-propositions — the 3 evidence line proposition types (TR, DIAG, PROG) that appear on SCI evidence lines, not as top-level propositions
- Note: Link to existing `docs/profiles/propositions.md` for the broader profiles context

- [ ] **Step 1: Write `docs/output-reference/classes/propositions.md`**
- [ ] **Step 2: Run `mkdocs build --strict` to validate**
- [ ] **Step 3: Commit**

### Task 5: Write Statements lead-in page

**Files:**
- Create: `docs/output-reference/classes/statements.md`

Content outline:
- Title: "Statements"
- Intro: Three levels of ClinVar statements — SCV (submission), VCV (variant aggregate), RCV (condition aggregate)
- Section: SCV statements — what they contain, how they reference propositions/submitters/conditions, extension summary
- Section: VCV statements — how aggregation works across submissions, priority tier evidence lines, nested sub-statements
- Section: RCV statements — same aggregation structure as VCV but scoped to a condition
- Section: Submitted condition mapping — what `submittedCondition`/`submittedConditionSet` extensions capture, link to SubmittedConditionMapping class page
- Reference existing content from `docs/output-reference/scv-statements.md`, `vcv-statements.md`, `rcv-statements.md` for tone

- [ ] **Step 1: Write `docs/output-reference/classes/statements.md`**
- [ ] **Step 2: Run `mkdocs build --strict` to validate**
- [ ] **Step 3: Commit**

### Task 6: Write Evidence lead-in page

**Files:**
- Create: `docs/output-reference/classes/evidence.md`

Content outline:
- Title: "Evidence Lines"
- Intro: Evidence lines appear only on somatic clinical impact (SCI) statements
- Section: AMP/ASCO/CAP tier mapping — Tier I → Level A/B, Tier II → Level C/D, Tier III/IV → no evidence outcome
- Section: Target proposition types — VariantTherapeuticResponseProposition (TR), VariantDiagnosticProposition (DIAG), VariantPrognosticProposition (PROG) with predicates
- Section: Relationship to parent SCI statement — how VariantClinicalSignificanceProposition at the statement level relates to the specific TR/DIAG/PROG proposition on the evidence line
- Section: Extensions — note that evidence lines also carry `submittedCondition`/`submittedConditionSet` extensions

- [ ] **Step 1: Write `docs/output-reference/classes/evidence.md`**
- [ ] **Step 2: Run `mkdocs build --strict` to validate**
- [ ] **Step 3: Commit**

---

## Chunk 3: Update index and validate

### Task 7: Update Data Model index page links

**Files:**
- Modify: `docs/output-reference/classes/index.md`

The existing index page links to individual class pages using paths like `sequence-reference.md`, `location.md`, `allele.md`, etc. — pages that don't exist. Update these links to point to the correct class page paths or to the group lead-in pages where appropriate.

For genomic classes (SequenceReference, Location, Allele, Gene) that don't have ClinVar-specific schemas, link to the Variations lead-in or keep as descriptive text without broken links.

- [ ] **Step 1: Update links in index.md to match new file paths**
- [ ] **Step 2: Run `mkdocs build --strict` to validate no broken links**
- [ ] **Step 3: Commit**

### Task 8: Final validation and push

- [ ] **Step 1: Run full MkDocs build**

```bash
mkdocs build --strict
```

Expected: Clean build, no errors

- [ ] **Step 2: Start dev server and visually verify**

```bash
mkdocs serve
```

Check:
- Data Model nav section shows 4 groups with sub-pages
- Each lead-in page renders correctly with admonitions and tables
- Each class page renders field tables correctly (no broken pipe columns)
- JSON schema links work
- "One of" and "Composed of" links resolve to sibling pages

- [ ] **Step 3: Commit any fixes and push**

```bash
git push
```
