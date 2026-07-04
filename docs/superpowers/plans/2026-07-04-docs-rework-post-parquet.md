# Documentation Rework Post-Parquet Pipeline

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update all documentation to reflect the structural changes from PRs #42–#54 (Parquet release pipeline).

**Architecture:** Nine categories of doc changes, organized by change type. Most are field-type corrections or JSON example updates. The Parquet output addition is the largest change (touches ~10 files). Each task targets a specific change and lists every affected file.

**Tech Stack:** MkDocs with Material theme. Validate with `mkdocs build --strict` after each task.

**Verification:** Run `mkdocs build --strict` after every task. This is the only test — docs have no other validation gate.

---

## Change Summary

| # | Change | Scope |
|---|--------|-------|
| 1 | `confidence` is now a concept struct, not a plain string | 7 files |
| 2 | Evidence lines extracted to dict tables (FK arrays, not inlined) | 6 files |
| 3 | Gene restructured as MappableConcept | 4 files |
| 4 | `conditionSet`: `condition_refs` → `concepts`, new top-level fields | 2 files |
| 5 | Condition `aliases` promoted from extension to top-level field | 2 files |
| 6 | `coding.system` values are URLs, not short strings | 3 files |
| 7 | Parquet output added alongside JSON bundle | 10 files |
| 8 | Export pipeline: new tables, updated section list | 2 files |
| 9 | Miscellaneous fixes (layer naming, stale text, typos) | 7 files |

---

## Chunk 1: Structural Field Changes

### Task 1: Update `confidence` from plain string to concept struct

The `confidence` field changed from a plain string (e.g., `"criteria provided"`) to a concept struct with two fields:

```json
{
  "conceptType": "Confidence",
  "name": "criteria provided"
}
```

**SQL source:** All three statement procs build confidence as `STRUCT('Confidence' AS conceptType, sl.label AS name)`.

**Files:**

- Modify: `docs/output-reference/scv-statements.md` — field table row (line ~28): change type from `string` to `object` and update example
- Modify: `docs/output-reference/vcv-statements.md` — field table row (line ~26): change type from `string` to `object` and update example
- Modify: `docs/output-reference/rcv-statements.md` — field table row (line ~27): change type from `string` to `object` and update example
- Modify: `docs/output-reference/classes/index.md` — Mermaid UML diagram (lines ~83, ~91, ~99): change `confidence : string` to `confidence : Concept`
- Modify: `docs/output-reference/overview.md` — if confidence is mentioned in the MappableConcept table, update the type
- Modify: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` — confidence derivation description: update to show it produces a concept struct, not a string label
- Modify: `docs/reference/glossary.md` — glossary entry for Confidence (line ~138): update definition to describe concept struct

**Steps:**

- [ ] **Step 1:** Update `docs/output-reference/scv-statements.md` — change `confidence` type from `string` to concept struct with example JSON
- [ ] **Step 2:** Update `docs/output-reference/vcv-statements.md` — same change
- [ ] **Step 3:** Update `docs/output-reference/rcv-statements.md` — same change
- [ ] **Step 4:** Update `docs/output-reference/classes/index.md` — change UML diagram `confidence : string` to `confidence : Concept` on all three statement classes
- [ ] **Step 5:** Update `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` — update confidence description from "the submission level label" to "a Concept struct with conceptType and name"
- [ ] **Step 6:** Update `docs/reference/glossary.md` — update Confidence definition
- [ ] **Step 7:** Run `mkdocs build --strict` — verify no broken links or warnings
- [ ] **Step 8:** Commit: `docs: update confidence field from string to concept struct`

---

### Task 2: Update evidence lines documentation (FK arrays, not inlined)

Evidence lines are now stored in three separate dict tables. Statements reference them via `hasEvidenceLines` arrays containing `#/evidenceLine/` JSON pointer strings. This applies to all three statement levels (SCV, VCV, RCV).

**Dict tables:**

| Table | Bundle section key pattern |
|---|---|
| `gks_dict_evidence_line` | `clinvar.submission:{id}.{version}` |
| `gks_dict_vcv_evidence_line` | `{id}.contributing` / `{id}.non-contributing` |
| `gks_dict_rcv_evidence_line` | `{id}.contributing` / `{id}.non-contributing` |

**All three statement levels use `hasEvidenceLines` as the field name** (the code uses this consistently; some docs incorrectly show VCV/RCV as `evidenceLines`).

**Files:**

- Modify: `docs/output-reference/vcv-statements.md` — fix field name from `evidenceLines` to `hasEvidenceLines`; update to show FK references instead of inlined objects
- Modify: `docs/output-reference/rcv-statements.md` — same fix
- Modify: `docs/output-reference/classes/statements.md` — line ~50: fix description that says "Each layer is connected via hasEvidenceLines" (correct field name but clarify FK behavior); also update `submissionLevel` values to include `NOCL` and `FLAG`
- Modify: `docs/output-reference/classes/evidence.md` — update to describe evidence lines as dict table entries referenced via FK, not inlined objects
- Modify: `docs/output-reference/classes/index.md` — verify/fix UML diagram field names for VCV/RCV evidence lines
- Modify: `docs/reference/glossary.md` — update EvidenceLine entry (line ~91) to describe FK reference pattern

**Steps:**

- [ ] **Step 1:** Read current `docs/output-reference/vcv-statements.md` evidence lines section and fix field name to `hasEvidenceLines`; update examples to show FK references (`#/evidenceLine/{key}`)
- [ ] **Step 2:** Read current `docs/output-reference/rcv-statements.md` and apply same fix
- [ ] **Step 3:** Update `docs/output-reference/classes/statements.md` — fix `hasEvidenceLines` description, add `NOCL` and `FLAG` to `submissionLevel` values
- [ ] **Step 4:** Update `docs/output-reference/classes/evidence.md` — describe evidence line dict tables and FK reference pattern
- [ ] **Step 5:** Verify `docs/output-reference/classes/index.md` UML diagram uses correct field names
- [ ] **Step 6:** Update `docs/reference/glossary.md` evidence line entry
- [ ] **Step 7:** Run `mkdocs build --strict`
- [ ] **Step 8:** Commit: `docs: update evidence lines to FK reference pattern with dict tables`

---

### Task 3: Update gene documentation to MappableConcept format

The `gks_dict_gene` table was restructured as a MappableConcept. Old fields (`symbol`, `entrez_gene_id`, `hgnc_id`) are replaced with the standard MappableConcept pattern.

**Current gene structure:**

```json
{
  "id": "ncbigene:3845",
  "conceptType": "gene",
  "name": "KRAS",
  "primaryCoding": {
    "code": "3845",
    "name": "KRAS",
    "system": "https://www.ncbi.nlm.nih.gov/gene/",
    "iris": ["https://identifiers.org/ncbigene:3845", "https://www.ncbi.nlm.nih.gov/gene/3845"]
  },
  "mappings": [
    {
      "coding": {
        "code": "6407",
        "system": "https://www.genenames.org",
        "iris": ["https://identifiers.org/hgnc:6407", "https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/HGNC:6407"]
      },
      "relation": "exactMatch"
    }
  ]
}
```

**Files:**

- Modify: `docs/output-reference/cat-vrs.md` — update `GeneListItem` table (lines ~171–180); if GeneListItem still has its own fields, verify against code; if it now uses a `gene` FK to `#/gene/`, document the pointer
- Modify: `docs/output-reference/classes/variations.md` — update `clinvarGeneList` extension description
- Modify: `docs/output-reference/classes/index.md` — update `Gene` class in UML diagram (lines ~35–37) to show MappableConcept fields
- Modify: `docs/output-reference/id-references.md` — verify `#/gene/` reference pattern is correct

**Steps:**

- [ ] **Step 1:** Read `src/procedures/gks-catvar-proc.sql` gene extension CTE to confirm what fields `GeneListItem` carries vs. what it delegates to `#/gene/` FK
- [ ] **Step 2:** Update `docs/output-reference/cat-vrs.md` GeneListItem table and examples
- [ ] **Step 3:** Update `docs/output-reference/classes/variations.md` `clinvarGeneList` description
- [ ] **Step 4:** Update `docs/output-reference/classes/index.md` Gene class in UML
- [ ] **Step 5:** Verify `docs/output-reference/id-references.md` gene reference pattern
- [ ] **Step 6:** Run `mkdocs build --strict`
- [ ] **Step 7:** Commit: `docs: update gene to MappableConcept format`

---

### Task 4: Update conditionSet structure (`condition_refs` → `concepts`)

The `gks_dict_condition_set` table changed:

- Field renamed: `condition_refs` → `concepts`
- New top-level fields: `conceptSetType` (from RCV trait set type) and `membershipOperator` (`AND` or `OR`)

**Files:**

- Modify: `docs/pipeline/conditions-and-traits/condition-sets.md` — update field names and add new fields
- Modify: `docs/reference/glossary.md` — update ConditionSet entry if it references `condition_refs`

**Steps:**

- [ ] **Step 1:** Read `docs/pipeline/conditions-and-traits/condition-sets.md` and update `condition_refs` → `concepts`, add `conceptSetType` and `membershipOperator` fields to the output table
- [ ] **Step 2:** Check `docs/reference/glossary.md` for `condition_refs` references and update
- [ ] **Step 3:** Run `mkdocs build --strict`
- [ ] **Step 4:** Commit: `docs: update conditionSet field names and structure`

---

### Task 5: Promote condition `aliases` from extension to top-level field

The `aliases` field on condition records moved from inside the `extensions` array to a top-level field. It is an array of strings (synonym names), present only when the trait has synonyms.

**Files:**

- Modify: `docs/pipeline/conditions-and-traits/condition-extensions.md` — remove `aliases` from the extensions table; add a note that it is now a top-level field on the condition record
- Modify: `docs/pipeline/conditions-and-traits/traits.md` — if `aliases` is described as an extension here, move it to the top-level fields section

**Steps:**

- [ ] **Step 1:** Read `docs/pipeline/conditions-and-traits/condition-extensions.md` and move `aliases` out of extensions table
- [ ] **Step 2:** Read `docs/pipeline/conditions-and-traits/traits.md` and verify `aliases` is documented as top-level
- [ ] **Step 3:** Run `mkdocs build --strict`
- [ ] **Step 4:** Commit: `docs: promote condition aliases from extension to top-level field`

---

### Task 6: Update `coding.system` to use URLs

Some JSON examples still show short human-readable strings for `coding.system` (e.g., `"ACMG Guidelines, 2015"`, `"dbSNP"`). The actual output now uses full URLs.

**Important distinction:** Classification/strength `primaryCoding.system` values come from the external `clinvar_ingest.clinvar_clinsig_types` table and may still use short label strings. Variation/gene/condition xrefs use full URLs. Check each example against the actual source before changing.

**Files:**

- Modify: `docs/output-reference/scv-statements.md` — check classification `primaryCoding` example (line ~47–49) and strength example (line ~71–73); update system values if they now use URLs
- Modify: `docs/output-reference/cat-vrs.md` — check mappings example (line ~100–108) `"system": "dbSNP"` — verify current value
- Modify: `docs/output-reference/overview.md` — check MappableConcept example `"system": "ACMG Guidelines, 2015"` — verify current value

**Steps:**

- [ ] **Step 1:** Query `src/procedures/gks-scv-statement-proc.sql` for the classification and strength `primaryCoding` construction to determine actual system values
- [ ] **Step 2:** Update `docs/output-reference/scv-statements.md` examples if system values changed
- [ ] **Step 3:** Check `docs/output-reference/cat-vrs.md` dbSNP system value against `src/procedures/gks-catvar-proc.sql`
- [ ] **Step 4:** Check `docs/output-reference/overview.md` example
- [ ] **Step 5:** Run `mkdocs build --strict`
- [ ] **Step 6:** Commit: `docs: update coding.system examples to use URLs where applicable`

---

## Chunk 2: Output Format and Export Changes

### Task 7: Add Parquet output documentation

The assembler (`assemble-gks-dicts.py`) now supports `--parquet-dir` which produces 15 typed Parquet files alongside the JSON bundle. This needs to be documented across all pages that describe the output format.

**Parquet files produced:**

| File | Content |
|---|---|
| `sequenceReference.parquet` | VRS sequence references |
| `location.parquet` | Genomic locations |
| `allele.parquet` | VRS alleles |
| `copyNumberCount.parquet` | Copy number count variants |
| `copyNumberChange.parquet` | Copy number change variants |
| `gene.parquet` | Gene MappableConcepts |
| `variation.parquet` | Categorical variants |
| `condition.parquet` | Conditions/traits |
| `conditionSet.parquet` | Condition sets |
| `submitter.parquet` | Submitters |
| `proposition.parquet` | All propositions (SCV+VCV+RCV merged) |
| `evidenceLine.parquet` | All evidence lines (SCV+VCV+RCV merged) |
| `scv.parquet` | SCV statements |
| `vcv.parquet` | VCV statements |
| `rcv.parquet` | RCV statements |

**Files to update:**

- Modify: `docs/pipeline/export.md` — add Parquet output section; document `--parquet-dir` flag; update bundle sections list from 12 to current count; fix sections/table inconsistency
- Modify: `docs/pipeline/index.md` — update Step 9 to mention Parquet alongside JSON; add `--parquet-dir` to the quickstart commands
- Modify: `docs/data-access/index.md` — add Parquet to file format section
- Modify: `docs/data-access/output-files.md` — add Parquet files to output files list
- Modify: `docs/data-access/download.md` — add Parquet download examples if published to R2; update directory structure
- Modify: `docs/output-reference/index.md` — update "single gzip-compressed JSON file" to include Parquet option
- Modify: `docs/output-reference/overview.md` — add note about Parquet output format
- Modify: `docs/getting-started.md` — add brief mention of Parquet availability
- Modify: `docs/index.md` — update output format description; update directory structure listing
- Modify: `docs/reference/glossary.md` — add Parquet to output format terms

**Steps:**

- [ ] **Step 1:** Update `docs/pipeline/export.md` — add `--parquet-dir` flag documentation, Parquet files table, fix bundle sections count
- [ ] **Step 2:** Update `docs/pipeline/index.md` — mention Parquet in Step 9 and quickstart
- [ ] **Step 3:** Update `docs/data-access/output-files.md` — add Parquet section
- [ ] **Step 4:** Update `docs/data-access/index.md` — add Parquet to format description
- [ ] **Step 5:** Update `docs/data-access/download.md` — add Parquet to directory structure (if published to R2)
- [ ] **Step 6:** Update `docs/output-reference/index.md` — add Parquet mention
- [ ] **Step 7:** Update `docs/output-reference/overview.md` — add Parquet note
- [ ] **Step 8:** Update `docs/getting-started.md` — brief Parquet mention
- [ ] **Step 9:** Update `docs/index.md` — update format description and directory listing
- [ ] **Step 10:** Update `docs/reference/glossary.md` — add Parquet entry
- [ ] **Step 11:** Run `mkdocs build --strict`
- [ ] **Step 12:** Commit: `docs: add Parquet output format documentation`

---

### Task 8: Update export pipeline tables and section list

The export pipeline now handles 19 `gks_dict_*` tables (up from ~12). The assembler merges VCV/RCV proposition and evidence line shards into unified bundle sections.

**Current export tables (19):**

| BigQuery table | Bundle section |
|---|---|
| `gks_dict_sequence_reference` | `sequenceReference` |
| `gks_dict_location` | `location` |
| `gks_dict_allele` | `allele` |
| `gks_dict_copy_number_count` | `copyNumberCount` |
| `gks_dict_copy_number_change` | `copyNumberChange` |
| `gks_dict_gene` | `gene` |
| `gks_dict_variation` | `variation` |
| `gks_dict_condition` | `condition` |
| `gks_dict_condition_set` | `conditionSet` |
| `gks_dict_submitter` | `submitter` |
| `gks_dict_proposition` | `proposition` (merged with vcv/rcv) |
| `gks_dict_evidence_line` | `evidenceLine` (merged with vcv/rcv) |
| `gks_dict_vcv_proposition` | → merged into `proposition` |
| `gks_dict_vcv_evidence_line` | → merged into `evidenceLine` |
| `gks_dict_rcv_proposition` | → merged into `proposition` |
| `gks_dict_rcv_evidence_line` | → merged into `evidenceLine` |
| `gks_dict_scv` | `scv` |
| `gks_dict_vcv` | `vcv` |
| `gks_dict_rcv` | `rcv` |

**Files:**

- Modify: `docs/pipeline/export.md` — update tables list from 12 to 19; fix "12 bundle sections" text; document the merge behavior for propositions and evidence lines
- Modify: `docs/output-reference/index.md` — update sections table if it doesn't include `copyNumberCount`, `copyNumberChange`, `evidenceLine`

**Steps:**

- [ ] **Step 1:** Update `docs/pipeline/export.md` — full table and sections list rewrite
- [ ] **Step 2:** Update `docs/output-reference/index.md` sections table
- [ ] **Step 3:** Run `mkdocs build --strict`
- [ ] **Step 4:** Commit: `docs: update export pipeline with 19 dict tables and merge behavior`

---

## Chunk 3: Terminology and Miscellaneous Fixes

### Task 9: Fix VCV layer naming ("Base"/"Tier" → "Classification"/"Priority")

Per established convention: use "Classification Grouping" and "Priority Grouping" instead of "Base Grouping" and "Tier Grouping" in documentation display names. SQL table names (`gks_vcv_grouping_base_agg`, `gks_vcv_grouping_tier_agg`) remain unchanged — only doc-facing labels change.

**Files:**

- Modify: `docs/pipeline/vcv-statements/index.md` — "Key Concepts" section: rename "Base Grouping" → "Classification Grouping", "Tier Grouping" → "Priority Grouping"
- Modify: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` — rename layer display names throughout
- Modify: `docs/pipeline/vcv-statements/vcv-proc.md` — rename layer display names (keep SQL table names as-is when referencing actual tables)
- Modify: `docs/data-access/examples.md` — fix VCV example descriptions ("Tier Grouping" → "Priority Grouping", "Base Grouping" → "Classification Grouping")
- Modify: `docs/output-reference/vcv-statements.md` — update layer hierarchy table if it uses old names
- Modify: `docs/output-reference/classes/statements.md` — update aggregation hierarchy description

**Steps:**

- [ ] **Step 1:** Read each file listed and identify all instances of "Base Grouping"/"Tier Grouping" display names
- [ ] **Step 2:** Replace display names with "Classification Grouping"/"Priority Grouping" in all 6 files (keep SQL table name references unchanged)
- [ ] **Step 3:** Run `mkdocs build --strict`
- [ ] **Step 4:** Commit: `docs: rename VCV layers to Classification/Priority grouping`

---

### Task 10: Miscellaneous fixes

A collection of small fixes found during the audit.

**Fixes:**

1. **Stale RCV sentence** in `docs/pipeline/conditions-and-traits/index.md` — remove "The same condition structures will also be critical for RCV accession output when that is added to the pipeline." (RCV is already implemented)

2. **`extension` → `extensions` typo** in two files:
   - `docs/pipeline/vcv-statements/vcv-extensions.md` — JSON example uses `"extension"` (singular), should be `"extensions"` (plural)
   - `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` — same typo in classification JSON example

3. **Stale `objectConditionClassification` concept** in `docs/pipeline/rcv-statements/index.md` — the "Key Concepts" section describes an old design where classification was embedded in objectConditionClassification ConceptSet; current design uses plain `objectCondition` plus separate `classification` field (as documented correctly in `rcv-proc.md`)

4. **Statement type numbering inconsistency** between `docs/profiles/classifications.md` and `docs/profiles/statement-types.md`:
   - `classifications.md` uses `G.1`–`G.9` and `S.1`–`S.4`
   - `statement-types.md` uses `G.01`–`G.09` and `S.11`–`S.14`
   - Align to the `statement-types.md` numbering (`G.01`–`G.09`, `O.10`, `S.11`–`S.14`)

5. **Evidence lines design note** in `docs/profiles/propositions.md` — update the note about evidence lines being "inlined" since they are now FK references

**Files:**

- Modify: `docs/pipeline/conditions-and-traits/index.md`
- Modify: `docs/pipeline/vcv-statements/vcv-extensions.md`
- Modify: `docs/pipeline/vcv-statements/vcv-aggregation-rules.md`
- Modify: `docs/pipeline/rcv-statements/index.md`
- Modify: `docs/profiles/classifications.md`
- Modify: `docs/profiles/propositions.md`

**Steps:**

- [ ] **Step 1:** Fix stale RCV sentence in `docs/pipeline/conditions-and-traits/index.md`
- [ ] **Step 2:** Fix `extension` → `extensions` typo in `docs/pipeline/vcv-statements/vcv-extensions.md` and `vcv-aggregation-rules.md`
- [ ] **Step 3:** Fix stale `objectConditionClassification` in `docs/pipeline/rcv-statements/index.md` — align with `rcv-proc.md`
- [ ] **Step 4:** Fix statement type numbering in `docs/profiles/classifications.md` to match `statement-types.md`
- [ ] **Step 5:** Update evidence lines design note in `docs/profiles/propositions.md`
- [ ] **Step 6:** Run `mkdocs build --strict`
- [ ] **Step 7:** Commit: `docs: miscellaneous fixes (stale text, typos, numbering)`

---

## File Impact Matrix

| File | Tasks |
|------|-------|
| `docs/output-reference/overview.md` | 1, 6, 7 |
| `docs/output-reference/index.md` | 7, 8 |
| `docs/output-reference/scv-statements.md` | 1, 6 |
| `docs/output-reference/vcv-statements.md` | 1, 2, 9 |
| `docs/output-reference/rcv-statements.md` | 1, 2 |
| `docs/output-reference/cat-vrs.md` | 3, 6 |
| `docs/output-reference/id-references.md` | 3 |
| `docs/output-reference/classes/index.md` | 1, 2, 3 |
| `docs/output-reference/classes/statements.md` | 2, 9 |
| `docs/output-reference/classes/evidence.md` | 2 |
| `docs/output-reference/classes/variations.md` | 3 |
| `docs/pipeline/index.md` | 7 |
| `docs/pipeline/export.md` | 7, 8 |
| `docs/pipeline/vcv-statements/index.md` | 9 |
| `docs/pipeline/vcv-statements/vcv-proc.md` | 9 |
| `docs/pipeline/vcv-statements/vcv-aggregation-rules.md` | 1, 9, 10 |
| `docs/pipeline/vcv-statements/vcv-extensions.md` | 10 |
| `docs/pipeline/rcv-statements/index.md` | 10 |
| `docs/pipeline/conditions-and-traits/index.md` | 10 |
| `docs/pipeline/conditions-and-traits/condition-sets.md` | 4 |
| `docs/pipeline/conditions-and-traits/condition-extensions.md` | 5 |
| `docs/pipeline/conditions-and-traits/traits.md` | 5 |
| `docs/data-access/index.md` | 7 |
| `docs/data-access/output-files.md` | 7 |
| `docs/data-access/download.md` | 7 |
| `docs/data-access/examples.md` | 9 |
| `docs/getting-started.md` | 7 |
| `docs/index.md` | 7 |
| `docs/profiles/classifications.md` | 10 |
| `docs/profiles/propositions.md` | 10 |
| `docs/reference/glossary.md` | 1, 2, 4, 7 |

**Total: 31 files across 10 tasks.**
