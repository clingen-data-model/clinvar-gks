# Profile Schemas and Documentation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a consumer-facing profile reference system with per-profile documentation pages, downloadable JSON Schema (draft 2020-12) files, inline examples, ClinVar content mapping, and comprehensive extension documentation.

**Architecture:** Expand the existing `docs/profiles/` section with per-profile pages that each show the full JSON shape, field descriptions, ClinVar content mapping, and inline examples. Create `schemas/profiles/` with JSON Schema 2020-12 files for programmatic validation. Keep existing cross-cutting reference tables (statement-types, classifications, propositions, review-status) as-is and link from profile pages. Update mkdocs.yml navigation and profiles index.

**Tech Stack:** MkDocs with Material theme, JSON Schema draft 2020-12, JSONC example files.

---

## File Structure

### New Files

**Profile Documentation Pages** (`docs/profiles/`):
- `scv-pathogenicity.md` — SCV Germline Pathogenicity profile (G.01)
- `scv-oncogenicity.md` — SCV Oncogenicity profile (O.10)
- `scv-somatic-clinical-impact.md` — SCV Somatic Clinical Impact profile (S.11-S.14, covers all tiers and sub-types)
- `scv-other.md` — SCV custom ClinVar profiles (G.02-G.09: drug response, risk factor, association, etc.)
- `vcv-germline.md` — VCV Germline aggregate profile
- `vcv-somatic.md` — VCV Somatic aggregate profile (oncogenicity + clinical impact)
- `catvar-canonical-allele.md` — Categorical Variant canonical allele profile
- `extensions-reference.md` — Consolidated extension reference across all output types

**JSON Schema Files** (`schemas/profiles/`):
- `scv-statement.schema.json` — SCV Statement base schema (shared by all SCV profiles)
- `vcv-statement.schema.json` — VCV Statement schema
- `categorical-variant.schema.json` — CategoricalVariant schema
- `condition.schema.json` — Condition/Disease object schema (reusable $ref)
- `gene-context.schema.json` — Gene context qualifier schema (reusable $ref)
- `concept-set.schema.json` — ConceptSet schema for PGEP classification (reusable $ref)

### Modified Files

- `docs/profiles/index.md` — Rewrite as profile hub with links to per-profile pages
- `mkdocs.yml` — Add profile pages and schemas to navigation
- `docs/output-reference/index.md` — Add link to schemas download section

---

## Chunk 0: Schema Generation Scripts (BLOCKED — waiting for user)

### Task 0: Integrate schema generation scripts

The user is adding scripts to generate JSON Schema files programmatically from the pipeline output structures, rather than hand-crafting them from examples. This will produce the authoritative schema files that Chunk 1 would otherwise create manually.

- [ ] **Step 0.1: Wait for user to add schema generation scripts**

The user will provide scripts (likely Python or BigQuery-based) that inspect the actual output table structures and produce JSON Schema draft 2020-12 files.

- [ ] **Step 0.2: Run the generation scripts to produce schema files in `schemas/profiles/`**

- [ ] **Step 0.3: Validate generated schemas against example files**

```bash
python3 -c "
import json, jsonschema
schema = json.load(open('schemas/profiles/scv-statement.schema.json'))
# validate against each example
"
```

- [ ] **Step 0.4: Commit generated schemas**

```bash
git add schemas/profiles/
git commit -m "Add generated JSON Schema files for output profiles"
```

**Status:** BLOCKED — waiting for schema generation scripts from user. Proceed to Chunk 2 (profile documentation pages) in the meantime, referencing schemas as TBD.

---

## Chunk 1: JSON Schema Files (SUPERSEDED by Chunk 0)

> **Note:** The tasks below describe manual schema creation. These are superseded by the schema generation approach in Chunk 0. Retained for reference in case manual adjustments are needed after generation.

### Task 1: Create reusable schema components

**Files:**
- Create: `schemas/profiles/condition.schema.json`
- Create: `schemas/profiles/gene-context.schema.json`
- Create: `schemas/profiles/concept-set.schema.json`

These are `$ref`-able components used by the main profile schemas.

- [ ] **Step 1.1: Create condition.schema.json**

Derive from the `objectCondition` structure in SCV examples. Fields: conceptType, name, id, primaryCoding (code, name, system, iris), mappings array, extensions array.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "condition.schema.json",
  "title": "Condition",
  "description": "A disease or phenotype condition from ClinVar, conforming to GA4GH Concept with ClinVar extensions.",
  "type": "object",
  "properties": {
    "conceptType": { "type": "string", "enum": ["Disease", "Finding", "PhenotypeInstruction", "NamedProteinVariant"] },
    "name": { "type": "string" },
    "id": { "type": "string" },
    "primaryCoding": { "$ref": "#/$defs/Coding" },
    "mappings": { "type": "array", "items": { "$ref": "#/$defs/Mapping" } },
    "extensions": { "type": "array", "items": { "$ref": "#/$defs/Extension" } }
  },
  "required": ["name"],
  "$defs": { ... }
}
```

- [ ] **Step 1.2: Create gene-context.schema.json**

Derive from `geneContextQualifier` in SCV examples.

- [ ] **Step 1.3: Create concept-set.schema.json**

Schema for the ConceptSet structure used in PGEP classifications and objectClassification.

- [ ] **Step 1.4: Commit**

```bash
git add schemas/profiles/
git commit -m "Add reusable JSON Schema components for conditions, genes, and concept sets"
```

### Task 2: Create SCV Statement schema

**Files:**
- Create: `schemas/profiles/scv-statement.schema.json`

- [ ] **Step 2.1: Write the SCV Statement JSON Schema**

Derive from examples and output-reference docs. The schema covers all SCV profile variants (pathogenicity, oncogenicity, somatic, custom). Key structures:
- Root: id, type, classification, strength, direction, description, proposition, contributions, specifiedBy, reportedIn, extensions, hasEvidenceLines
- classification: name, primaryCoding, extensions (description)
- proposition: type (enum of all proposition types), id, subjectVariant, predicate, objectCondition, geneContextQualifier, modeOfInheritanceQualifier, penetranceQualifier
- For somatic: objectTherapy, conditionQualifier in evidence line target propositions
- contributions: array of Contribution objects
- extensions: array of name/value pairs

- [ ] **Step 2.2: Validate schema against example files**

```bash
# Install jsonschema CLI if needed, then validate each example
python3 -c "
import json, jsonschema
schema = json.load(open('schemas/profiles/scv-statement.schema.json'))
for f in ['examples/scv/SCV001571657.2-path.jsonc', ...]:
    instance = json.load(open(f))
    jsonschema.validate(instance, schema)
    print(f'{f}: VALID')
"
```

Note: JSONC files need comment stripping first. May need to use a JSON5/JSONC parser or strip comments manually.

- [ ] **Step 2.3: Commit**

```bash
git add schemas/profiles/scv-statement.schema.json
git commit -m "Add JSON Schema for SCV Statement profile"
```

### Task 3: Create VCV Statement schema

**Files:**
- Create: `schemas/profiles/vcv-statement.schema.json`

- [ ] **Step 3.1: Write the VCV Statement JSON Schema**

Derive from VCV examples. Key structures:
- Root: id, type, direction, strength, classification_mappableConcept, classification_conceptSet, classification_conceptSetSet, proposition, extensions, evidenceLines
- proposition: type, id, subjectVariant, predicate, objectClassification_mappableConcept, objectClassification_conceptSet, objectClassification_conceptSetSet, aggregateQualifiers
- evidenceLines: array with type, directionOfEvidenceProvided, strengthOfEvidenceProvided, evidenceItems (recursive or ID reference)
- Recursive: evidenceItems can contain full nested VCV statements or leaf ID references

Use `oneOf` for the 3-way classification split (exactly one of mappableConcept, conceptSet, conceptSetSet should be present).

- [ ] **Step 3.2: Commit**

```bash
git add schemas/profiles/vcv-statement.schema.json
git commit -m "Add JSON Schema for VCV Statement profile"
```

### Task 4: Create Categorical Variant schema

**Files:**
- Create: `schemas/profiles/categorical-variant.schema.json`

- [ ] **Step 4.1: Write the CategoricalVariant JSON Schema**

Derive from cat-vrs examples. Key structures:
- Root: id, type, name, constraints, mappings, members, extensions
- constraints: array with type-specific constraint objects (DefiningAlleleConstraint, DefiningLocationConstraint, CopyChangeConstraint, CopyCountConstraint)
- Allele: id, type, name, digest, location (SequenceLocation), state (LiteralSequenceExpression or ReferenceLengthExpression), expressions
- mappings: coding + relation
- extensions: clinvarHgvsList, clinvarGeneList, and scalar extensions

- [ ] **Step 4.2: Commit**

```bash
git add schemas/profiles/categorical-variant.schema.json
git commit -m "Add JSON Schema for CategoricalVariant profile"
```

---

## Chunk 2: Profile Documentation Pages

### Task 5: Write SCV Pathogenicity profile page

**Files:**
- Create: `docs/profiles/scv-pathogenicity.md`

- [ ] **Step 5.1: Write the profile page**

Structure (following va-spec.ga4gh.org pattern):
1. **Profile Summary** — one-paragraph description, statement type code (G.01), proposition type, applicable classifications
2. **Schema Shape** — field table with Type, Required, Description columns
3. **Classification Values** — table of valid classification names with direction and strength mappings
4. **Proposition** — field documentation for VariantPathogenicityProposition including predicate, subjectVariant, objectCondition, qualifiers
5. **Extensions** — table of SCV extensions with descriptions
6. **ClinVar Content Mapping** — how ClinVar fields map to GKS fields
7. **Example** — inline JSON example (abbreviated, linking to full example file)
8. **Schema Download** — link to `scv-statement.schema.json`

- [ ] **Step 5.2: Commit**

```bash
git add docs/profiles/scv-pathogenicity.md
git commit -m "Add SCV Pathogenicity profile documentation"
```

### Task 6: Write SCV Oncogenicity profile page

**Files:**
- Create: `docs/profiles/scv-oncogenicity.md`

- [ ] **Step 6.1: Write the profile page**

Same structure as pathogenicity but for oncogenicity (O.10). Different classification values (Oncogenic, Likely oncogenic, etc.), VariantOncogenicityProposition, predicate isOncogenicFor.

- [ ] **Step 6.2: Commit**

```bash
git add docs/profiles/scv-oncogenicity.md
git commit -m "Add SCV Oncogenicity profile documentation"
```

### Task 7: Write SCV Somatic Clinical Impact profile page

**Files:**
- Create: `docs/profiles/scv-somatic-clinical-impact.md`

- [ ] **Step 7.1: Write the profile page**

Covers S.11-S.14. This is the most complex SCV profile because it has:
- 4 sub-types: Clinical Significance, Therapeutic Response, Diagnostic, Prognostic
- Tier I-IV classifications with different strengths
- Evidence line target propositions (therapeutic → drug, diagnostic → condition, prognostic → outcome)
- Drug therapy extraction for therapeutic assertions
- conditionQualifier vs objectCondition swapping for therapeutic

Include sub-sections for each sub-type with specific predicates, example JSON.

- [ ] **Step 7.2: Commit**

```bash
git add docs/profiles/scv-somatic-clinical-impact.md
git commit -m "Add SCV Somatic Clinical Impact profile documentation"
```

### Task 8: Write SCV Other Profiles page

**Files:**
- Create: `docs/profiles/scv-other.md`

- [ ] **Step 8.1: Write the profile page**

Covers G.02-G.09 (Drug Response, Risk Factor, Protective, Affects, Association, Confers Sensitivity, Other, Not Provided). These use custom ClinVar proposition types. Note which are historical/deprecated vs active.

- [ ] **Step 8.2: Commit**

```bash
git add docs/profiles/scv-other.md
git commit -m "Add SCV Other profiles documentation"
```

### Task 9: Write VCV Germline profile page

**Files:**
- Create: `docs/profiles/vcv-germline.md`

- [ ] **Step 9.1: Write the profile page**

Document the germline VCV aggregate statement:
- 4-layer hierarchy (L1→L4)
- classification_mappableConcept for non-PGEP (with conflictingExplanation)
- classification_conceptSet / conceptSetSet for PGEP
- Proposition with objectClassification 3-way split
- aggregateQualifiers (AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier)
- clinvarReviewStatus extension
- Evidence lines with contributing/non-contributing SCVs
- Nested structure with full inlined sub-statements

- [ ] **Step 9.2: Commit**

```bash
git add docs/profiles/vcv-germline.md
git commit -m "Add VCV Germline profile documentation"
```

### Task 10: Write VCV Somatic profile page

**Files:**
- Create: `docs/profiles/vcv-somatic.md`

- [ ] **Step 10.1: Write the profile page**

Document the somatic VCV aggregate statement:
- Stops at Layer 3 (no Layer 4 for somatic)
- Includes tier aggregation at Layer 2
- Statement group "S" with prop types: sci, onco
- Same classification 3-way split but PGEP less common in somatic

- [ ] **Step 10.2: Commit**

```bash
git add docs/profiles/vcv-somatic.md
git commit -m "Add VCV Somatic profile documentation"
```

### Task 11: Write CategoricalVariant profile page

**Files:**
- Create: `docs/profiles/catvar-canonical-allele.md`

- [ ] **Step 11.1: Write the profile page**

Document the CategoricalVariant (canonical allele) profile:
- Constraint types and when each is used
- VRS allele structure (location, state, expressions)
- Mappings with relation types
- Extensions: clinvarHgvsList, clinvarGeneList, type classifications
- Member references (JSON pointers to defining allele)

- [ ] **Step 11.2: Commit**

```bash
git add docs/profiles/catvar-canonical-allele.md
git commit -m "Add CategoricalVariant Canonical Allele profile documentation"
```

---

## Chunk 3: Extensions Reference and Navigation

### Task 12: Write consolidated extensions reference

**Files:**
- Create: `docs/profiles/extensions-reference.md`

- [ ] **Step 12.1: Write the extensions reference page**

Consolidate all extensions across all output types into one reference page, organized by where they appear:

1. **SCV Statement Extensions** — clinvarScvId, clinvarScvVersion, clinvarScvReviewStatus, submittedScvClassification, submittedScvLocalKey, submissionLevel
2. **SCV Classification Extensions** — description (formatted string)
3. **Condition Extensions** — clinvarTraitId, clinvarTraitType, aliases, submittedScvXrefs, submittedScvTraitAssignment, clinvarScvTraitAssignment, clinvarScvTraitMappingType:ref(val), clinvarTraitSetType, clinvarTraitSetId, submittedScvTraitSetType
4. **VCV Statement Extensions** — clinvarReviewStatus
5. **VCV Classification Extensions** — conflictingExplanation, description (in conceptSet)
6. **CategoricalVariant Extensions** — categoricalVariationType, definingVrsVariationType, clinvarVariationType, clinvarSubclassType, clinvarCytogeneticLocation, clinvarAssembly, vrsPreProcessingIssue, vrsProcessingException, clinvarHgvsList, clinvarGeneList
7. **SequenceReference Extensions** — assembly

For each extension: name, parent context, value type, description, example value.

- [ ] **Step 12.2: Commit**

```bash
git add docs/profiles/extensions-reference.md
git commit -m "Add consolidated extensions reference page"
```

### Task 13: Update profiles index and navigation

**Files:**
- Modify: `docs/profiles/index.md`
- Modify: `mkdocs.yml`

- [ ] **Step 13.1: Rewrite profiles index**

Reorganize as a profile hub:
- Overview paragraph
- **SCV Profiles** section with links to pathogenicity, oncogenicity, somatic, other
- **VCV Profiles** section with links to germline, somatic
- **Categorical Variant Profiles** section with link to canonical allele
- **Reference Tables** section linking to existing statement-types, classifications, propositions, review-status pages
- **Extensions** section linking to extensions-reference
- **Schemas** section with download links to all schema files

- [ ] **Step 13.2: Update mkdocs.yml navigation**

```yaml
  - Profiles:
    - profiles/index.md
    - SCV Profiles:
      - Pathogenicity: profiles/scv-pathogenicity.md
      - Oncogenicity: profiles/scv-oncogenicity.md
      - Somatic Clinical Impact: profiles/scv-somatic-clinical-impact.md
      - Other Profiles: profiles/scv-other.md
    - VCV Profiles:
      - Germline: profiles/vcv-germline.md
      - Somatic: profiles/vcv-somatic.md
    - Categorical Variants:
      - Canonical Allele: profiles/catvar-canonical-allele.md
    - Reference:
      - Statement Types: profiles/statement-types.md
      - Classifications: profiles/classifications.md
      - Propositions: profiles/propositions.md
      - Review Status: profiles/review-status.md
    - Extensions Reference: profiles/extensions-reference.md
```

- [ ] **Step 13.3: Validate docs build**

```bash
mkdocs build --strict
```

- [ ] **Step 13.4: Commit**

```bash
git add docs/profiles/index.md mkdocs.yml
git commit -m "Update profiles index and navigation for per-profile pages"
```

### Task 14: Add schema download section to output reference

**Files:**
- Modify: `docs/output-reference/index.md`

- [ ] **Step 14.1: Add schemas section**

Add a "JSON Schemas" section to the output reference index with download links to each schema file and a brief description of what each validates.

- [ ] **Step 14.2: Final build validation and commit**

```bash
mkdocs build --strict
git add docs/output-reference/index.md
git commit -m "Add JSON Schema download links to output reference"
```

---

## Confirmed Design Decisions

1. **Option A**: Per-profile pages in `docs/profiles/` with schemas in `schemas/profiles/`
2. **JSON Schema draft 2020-12** for programmatic validation
3. **Reusable $ref components** for shared structures (condition, gene-context, concept-set)
4. **Single SCV schema** covering all SCV profile variants (pathogenicity through custom) — the proposition type field discriminates
5. **Existing cross-cutting tables** (statement-types, classifications, propositions, review-status) kept as-is and linked from profile pages
6. **Consolidated extensions reference** — one page covering all extension types across all output formats
7. **Profile pages follow va-spec.ga4gh.org pattern** — schema shape, field docs, classification values, examples, ClinVar mapping, schema download
