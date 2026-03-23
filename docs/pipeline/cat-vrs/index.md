# Cat-VRS Generation (gks_catvar_proc)

## Overview

The `clinvar_ingest.gks_catvar_proc` stored procedure transforms ClinVar variation data into GA4GH Cat-VRS (Categorical Variation Representation Specification) format. It builds categorical variant records that group genomic variants at a higher level for use in clinical assertions — linking VRS-resolved alleles with their expressions, cross-references, constraints, and ClinVar metadata.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

Steps produce three types of output:

- <span class="role-badge badge-pipeline">Pipeline table</span> — persists in BigQuery for use by downstream procedures or external processing
- <span class="role-badge badge-artifact">JSON artifact</span> — exported as a JSONL file for public distribution
- <span class="role-badge badge-internal">Internal</span> — exists only within the procedure and is consumed by later steps

### Step 1a: Build `gks_seqref`

Extracts enriched sequence reference records from VRS output. For each distinct accession with a resolved `refgetAccession`, derives:

- **Molecule type** from the accession prefix (genomic, mRNA, RNA, or protein)
- **Residue alphabet** (`na` or `aa`) based on accession type
- **Assembly extensions** mapping assembly version numbers to human-readable names (GRCh38, GRCh37, NCBI36)

**Output:** Small lookup table joined by subsequent steps. <span class="role-badge badge-internal">Internal</span>

### Step 1b: Build `gks_seqloc`

Extracts distinct sequence locations from VRS output and joins each to its enriched sequence reference from `gks_seqref`. Transforms range endpoints into the Cat-VRS `start_range`/`end_range` array format for imprecise locations.

**Output:** `gks_seqloc` — one row per unique VRS sequence location. <span class="role-badge badge-internal">Internal</span>

### Step 2: Build `gks_ctxvar_expression`

Consolidates all variant expressions (SPDI, HGVS, gnomAD) for each variation+accession pair, ranked by a 4-level precedence hierarchy:

1. **SPDI** (highest) — canonical SPDI from VRS output
2. **HGVS** — nucleotide expressions from `variation_hgvs`
3. **gnomAD** — VCF-style identifiers from `variation_loc`
4. **Derived HGVS** (lowest) — positional HGVS from `variation_loc` when no `variation_hgvs` entry exists

Only includes expressions for variations that successfully resolved through VRS processing. Selects the best expression as the variant `name` using HGVS type (descending) and precedence ordering.

**Output:** `gks_ctxvar_expression` — one row per variation+accession+assembly. <span class="role-badge badge-internal">Internal</span>

### Step 3: Build `gks_ctxvar`

Joins VRS output with expressions and sequence locations to build contextual variant records. Maps VRS output types to categorical variant types:

| VRS Output Type | Categorical Variant Type |
|---|---|
| `Allele` | `CanonicalAllele` |
| `CopyNumberChange` | `CategoricalCnvChange` |
| `CopyNumberCount` | `CategoricalCnvCount` |
| Other | `Non-Constrained` |

**Output:** `gks_ctxvar` — one row per distinct contextual variant. <span class="role-badge badge-internal">Internal</span>

### Step 4: Build `gks_catvar_extension`

Assembles all extension metadata for each variation into a single extensions array. Includes:

- ClinVar HGVS list with molecular consequences (built from `variation_hgvs` with SO term lookups)
- Gene associations (from `gene_association` and `gene` tables)
- Categorical and VRS type classifications
- VRS processing issues and exceptions
- ClinVar variation metadata (type, subclass, cytogenetic location)

See [Categorical Variant Extensions](catvar-extensions.md) for a reference of all extension types.

**Output:** `gks_catvar_extension` — one row per variation with an `extensions` array. <span class="role-badge badge-internal">Internal</span>

### Step 5: Build `gks_catvar_mappings`

Builds cross-reference mappings for each variation from two sources:

- **ClinVar self-reference** — an `exactMatch` mapping to the ClinVar variation identifier
- **External cross-references** — `relatedMatch` (or `closeMatch` for ClinGen) mappings from `variation_xref` with IRI resolution for known databases (dbSNP, OMIM, UniProtKB, GTR, etc.)

**Output:** `gks_catvar_mappings` — one row per variation with a `mappings` array. <span class="role-badge badge-internal">Internal</span>

### Step 6: Build `gks_catvar_pre`

Assembles the preliminary categorical variant record by joining contextual variants with their constraints, extensions, and mappings. Generates constraint structures based on categorical variant type:

| Categorical Type | Constraints Generated |
|---|---|
| `CanonicalAllele` | `DefiningAlleleConstraint` |
| `CategoricalCnvCount` | `DefiningLocationConstraint` + `CopyCountConstraint` |
| `CategoricalCnvChange` | `DefiningLocationConstraint` + `CopyChangeConstraint` |

**Output:** `gks_catvar_pre` — one row per categorical variant with full structured record. <span class="role-badge badge-pipeline">Pipeline table</span>

### Step 7: Build `gks_catvar`

Converts the structured records from `gks_catvar_pre` into JSON format using `TO_JSON` with null/empty stripping, then normalizes and keys the output using the `clinvar_ingest.normalizeAndKeyById` UDF.

**Output:** `gks_catvar` — final JSON-normalized categorical variant records. <span class="role-badge badge-artifact">JSON artifact</span> — exported as `variation.jsonl.gz`. See [Categorical Variants](../../output-reference/cat-vrs.md) for consumer documentation.

---

## Output Tables

| Table | Description | Role |
|---|---|---|
| `gks_seqref` | Enriched sequence references with molecule type and assembly | <span class="role-badge badge-internal">Internal</span> |
| `gks_seqloc` | Sequence locations with joined sequence references | <span class="role-badge badge-internal">Internal</span> |
| `gks_ctxvar_expression` | Precedence-ranked variant expressions per variation+accession | <span class="role-badge badge-internal">Internal</span> |
| `gks_ctxvar` | Contextual variants with VRS type mapping | <span class="role-badge badge-internal">Internal</span> |
| `gks_catvar_extension` | Extension metadata arrays (HGVS list, genes, types) | <span class="role-badge badge-internal">Internal</span> |
| `gks_catvar_mappings` | Cross-reference mappings to external databases | <span class="role-badge badge-internal">Internal</span> |
| `gks_catvar_pre` | Assembled categorical variant records with constraints | <span class="role-badge badge-pipeline">Pipeline table</span> |
| `gks_catvar` | Final JSON-normalized output | <span class="role-badge badge-artifact">JSON artifact</span> |

---

## Dependencies

- **UDFs**: `clinvar_ingest.normalizeAndKeyById`, `clinvar_ingest.schema_on`
- **Source Tables**: `gks_vrs`, `variation_loc`, `variation_hgvs`, `variation_identity`, `variation_xref`, `gene_association`, `gene`
- **Upstream Procedures**: `variation_identity_proc`, VRS Python processing
- **Downstream Consumers**: `gks_statement_scv_proc`, export pipeline
