# gks_trait_proc Procedure

## Overview

The `clinvar_ingest.gks_trait_proc` stored procedure builds GKS-compliant trait records from ClinVar's normalized `trait` table. Each output record includes a primary coding (MedGen when available), cross-reference mappings to external ontologies (OMIM, MONDO, HPO, Orphanet, MeSH, EFO), and ClinVar-specific extensions. The resulting `gks_trait` table serves as the lookup for the [Condition Sets](condition-sets.md) procedure, which joins it with condition mapping results to build the final condition structures.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes as a single query with two CTEs within a loop over the target schema(s) identified by the `on_date` parameter.

### Step 1: Extract Traits

The `traits` CTE selects distinct trait records from the `trait` table, extracting:

- Trait `id`, `type`, and preferred `name`
- Alternate names concatenated into a comma-separated `synonyms` string
- Cross-references parsed from the raw `xrefs` field via the `clinvar_ingest.parseXRefItems` UDF

### Step 2: Build Trait Cross-References

The `trait_xrefs` CTE unnests each trait's parsed xrefs and builds a coding struct for each cross-reference. Each coding includes:

- The database name (`system`) and identifier (`code`)
- An array of IRIs — an identifiers.org canonical IRI and a secondary browsable URL

Cross-references are filtered to include only:

- Non-Gene databases (Gene xrefs are excluded)
- Records with no `ref_field` (inline xrefs only)
- Primary type xrefs (or xrefs with no type specified)

### Step 3: Aggregate into `gks_trait`

The final query joins traits with their cross-references and aggregates into one row per trait:

- **`primaryCoding`** — the MedGen coding, selected as the first non-null MedGen xref. The MedGen coding includes the trait name in its `name` field
- **`mappings`** — all non-MedGen codings wrapped with a `relatedMatch` relation
- **`extensions`** — an array containing:
  - `clinvarTraitId` — the ClinVar trait ID
  - `clinvarTraitType` — the trait type (e.g., Disease, Finding, PhenotypeInstruction)
  - `aliases` — comma-separated alternate names (included only when synonyms exist)

**Output:** `gks_trait` — one row per trait with structured codings, mappings, and extensions.

---

## IRI Mapping Reference

Each supported database maps to a pair of IRIs — a canonical identifiers.org IRI and a secondary browsable URL:

| Database | identifiers.org Pattern | Secondary URL |
| --- | --- | --- |
| MedGen | `https://identifiers.org/medgen:{id}` | `https://www.ncbi.nlm.nih.gov/medgen/{id}` |
| OMIM | `https://identifiers.org/mim:{id}` | `https://www.ncbi.nlm.nih.gov/medgen/{id}` |
| Human Phenotype Ontology | `https://identifiers.org/{id}` | `https://hpo.jax.org/browse/term/{id}` |
| MONDO | `https://identifiers.org/mondo:{digits}` | `http://purl.obolibrary.org/obo/MONDO_{digits}` |
| Orphanet | `https://identifiers.org/orphanet.ordo:Orphanet_{id}` | `http://www.orpha.net/ORDO/Orphanet_{id}` |
| MeSH | `https://identifiers.org/mesh:{id}` | `https://www.ncbi.nlm.nih.gov/mesh/?term={id}` |
| EFO | `https://identifiers.org/efo:{id}` | `http://www.ebi.ac.uk/efo/EFO_{id}` |

MONDO IDs are normalized by extracting the numeric portion — `MONDO:0000001` becomes `0000001` in both IRI patterns.

---

## Output Tables

| Table | Description |
| --- | --- |
| `gks_trait` | GKS-compliant trait records with primary coding, cross-reference mappings, and extensions |

---

## Dependencies

- **UDFs**: `clinvar_ingest.schema_on`, `clinvar_ingest.parseXRefItems`
- **Source Tables**: `trait`
- **Upstream Procedures**: None — operates on base ClinVar ingest tables
- **Downstream Consumers**: `gks_scv_condition_sets_proc`
