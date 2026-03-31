# SCV Statements (gks_scv_statement_proc)

## Overview

The `clinvar_ingest.gks_scv_statement_proc` stored procedure transforms ClinVar submitted clinical variant (SCV) data into GA4GH VA-Spec Statement format. It builds complete clinical assertion records from SCV submissions — linking classification codes, propositions, qualifiers, conditions, citations, and submitter metadata into structured statements suitable for downstream aggregation and export.

The procedure accepts two parameters — `on_date DATE` and `debug BOOL` — where `on_date` identifies the ClinVar release schema to process and `debug` controls diagnostic output.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

Steps produce two types of output:

- <span class="role-badge badge-pipeline">Pipeline table</span> — persists in BigQuery for use by downstream procedures or external processing
- <span class="role-badge badge-internal">Internal</span> — exists only within the procedure and is consumed by later steps

### Step 1: Build `temp_gks_scv`

Extracts SCV records from `scv_summary` and `clinical_assertion`, joining to `clinvar_clinsig_types` for classification mapping and `submission_level` for submission level. Produces the foundational record with proposition type, direction, classification codes, strength, submitter info, drug therapy (for somatic), assertion method attributes, citations, submission_level code and label.

**Output:** `temp_gks_scv` — one row per SCV with core classification and submitter metadata. <span class="role-badge badge-internal">Internal</span>

### Step 2: Build `temp_gene_context_qualifiers`

Extracts gene context qualifiers by joining single-gene variations with submitted gene symbols from `clinical_assertion_variation`. Produces gene concept records with primaryCoding (NCBI Gene), HGNC mappings, and submittedGeneSymbols extensions.

**Output:** `temp_gene_context_qualifiers` — one row per SCV+gene combination. <span class="role-badge badge-internal">Internal</span>

### Step 3: Build `temp_moi_qualifiers`

Extracts mode of inheritance qualifiers from assertion attributes. Maps to HPO terms when available.

**Output:** `temp_moi_qualifiers` — one row per SCV with mode of inheritance. <span class="role-badge badge-internal">Internal</span>

### Step 4: Build `temp_penetrance_qualifiers`

Builds penetrance qualifiers for low-penetrance and risk allele classifications.

**Output:** `temp_penetrance_qualifiers` — one row per SCV with penetrance qualifier. <span class="role-badge badge-internal">Internal</span>

### Step 5: Build `temp_gks_scv_proposition`

Assembles primary SCV propositions by joining SCV records with gene context, MOI, penetrance qualifiers and condition sets from `gks_scv_condition_sets`.

**Output:** `temp_gks_scv_proposition` — one row per SCV with fully assembled proposition. <span class="role-badge badge-internal">Internal</span>

### Step 6: Build `temp_gks_scv_target_proposition`

Builds somatic target propositions for clinical impact assertions (prognostic, diagnostic, therapeutic) with drug therapy extraction.

**Output:** `temp_gks_scv_target_proposition` — one row per somatic SCV with target proposition. <span class="role-badge badge-internal">Internal</span>

### Step 7: Build `gks_statement_scv_pre`

Final assembly of VA-Spec Statement records. Joins SCV records with propositions, conditions, citations, and assertion methods. Builds the classification struct with description extension, contributions array, extensions array (clinvarScvId, clinvarScvVersion, clinvarScvReviewStatus, submittedScvClassification, submittedScvLocalKey, submissionLevel), and somatic evidence lines.

**Output:** `gks_statement_scv_pre` — one row per SCV with complete VA-Spec Statement record. <span class="role-badge badge-pipeline">Pipeline table</span>

---

## Output Tables

| Table | Description | Role |
|---|---|---|
| `temp_gks_scv` | Core SCV records with classification and submitter metadata | <span class="role-badge badge-internal">Internal</span> |
| `temp_gene_context_qualifiers` | Gene context qualifiers with NCBI Gene and HGNC mappings | <span class="role-badge badge-internal">Internal</span> |
| `temp_moi_qualifiers` | Mode of inheritance qualifiers with HPO term mappings | <span class="role-badge badge-internal">Internal</span> |
| `temp_penetrance_qualifiers` | Penetrance qualifiers for low-penetrance and risk alleles | <span class="role-badge badge-internal">Internal</span> |
| `temp_gks_scv_proposition` | Assembled primary propositions with qualifiers and conditions | <span class="role-badge badge-internal">Internal</span> |
| `temp_gks_scv_target_proposition` | Somatic target propositions for clinical impact assertions | <span class="role-badge badge-internal">Internal</span> |
| `gks_statement_scv_pre` | Complete VA-Spec Statement records for all SCVs | <span class="role-badge badge-pipeline">Pipeline table</span> |

---

## Dependencies

- **UDFs**: `clinvar_ingest.parseAttributeSet`, `clinvar_ingest.parseCitations`, `clinvar_ingest.parseGeneLists`, `clinvar_ingest.schema_on`, `clinvar_ingest.cleanup_temp_tables`
- **Source Tables**: `scv_summary`, `clinical_assertion`, `clinical_assertion_variation`, `single_gene_variation`, `gene`, `variation_archive`
- **Lookup Tables**: `clinvar_clinsig_types`, `submission_level`, `hpo_terms`
- **Upstream Procedures**: `gks_scv_condition_proc` (provides `gks_scv_condition_sets`), `gks_catvar_proc`
- **Downstream Consumers**: `gks_vcv_proc`, `gks_vcv_statement_proc`, `gks_json_proc`

---

## Detailed Documentation

- [SCV Records](scv-records.md) — foundational SCV record extraction (Step 1)
- [Propositions](propositions.md) — qualifier assembly and proposition construction (Steps 2-6)
- [Final Statements](final-statements.md) — complete statement assembly (Step 7)
