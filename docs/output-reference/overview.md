# Output Format Overview

The ClinVar-GKS release file uses a **bundle format** — a single JSON object with named sections at the root level. A bundle is a dictionary-style approach to organizing a large amount of data across heterogeneous classes in a single file, where each section is a keyed collection of objects of the same class. The key is the object's unique identifier, and the value is the complete object.

This design eliminates duplication (a sequence reference shared by thousands of locations appears once), keeps individual objects compact, and enables efficient lookups by ID.

---

## Structure

```json
{
  "sequenceReference": { "<key>": { ... }, ... },
  "location":          { "<key>": { ... }, ... },
  "allele":            { "<key>": { ... }, ... },
  "gene":              { "<key>": { ... }, ... },
  "variation":         { "<key>": { ... }, ... },
  "condition":         { "<key>": { ... }, ... },
  "conditionSet":      { "<key>": { ... }, ... },
  "submitter":         { "<key>": { ... }, ... },
  "proposition":       { "<key>": { ... }, ... },
  "scv":               { "<key>": { ... }, ... },
  "vcv":               { "<key>": { ... }, ... },
  "rcv":               { "<key>": { ... }, ... }
}
```

---

## Sections

### Genomic Data Sections

These sections contain the VRS and Cat-VRS variant data:

**`sequenceReference`** — Reference sequences (chromosomes, transcripts) with refget accessions, molecule type, and assembly information. Keyed by refget accession (e.g., `SQ.0iKlIQk2oZLoeOG9P1riRU6hvL5Ux8TV`).

**`location`** — Sequence locations with start/end coordinates. Each location references its sequence via `#/sequenceReference/{key}`. Keyed by VRS location ID (e.g., `ga4gh:SL.Eg_6kV6Bb4FMjm9kEolHZ_4NhU8lBEsZ`).

**`allele`** — VRS alleles with state, expressions (SPDI, HGVS, gnomAD), and copy number data. Each allele references its location via `#/location/{key}`. Keyed by VRS allele ID (e.g., `ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY`).

**`gene`** — Gene records with NCBI gene ID, HGNC ID, symbol, and identifier IRIs. Keyed by `ncbigene:{gene_id}` (e.g., `ncbigene:3077`).

**`variation`** — Cat-VRS categorical variants linking ClinVar variation IDs to their VRS alleles, constraints, cross-references, HGVS expressions, and gene associations. Each variation references its members via `#/allele/{key}` and genes via `#/gene/{key}`. Keyed by `clinvar:{variation_id}` (e.g., `clinvar:10`).

### Clinical Data Sections

These sections contain the condition, submitter, and proposition reference data:

**`condition`** — Trait and disease concepts from ClinVar, with MedGen primary coding and cross-references to OMIM, MONDO, HPO, Orphanet, and MeSH. Keyed by `clinvar.trait:{trait_id}` (e.g., `clinvar.trait:9580`).

**`conditionSet`** — Multi-condition groupings with member condition references and a membership operator (AND or OR). Keyed by `clinvar.traitset:{trait_set_id}` (e.g., `clinvar.traitset:1234`).

**`submitter`** — Submitting organizations with name and identifier. Keyed by `clinvar.submitter:{submitter_id}` (e.g., `clinvar.submitter:500139`).

**`proposition`** — Classification propositions defining what a statement asserts — the proposition type, predicate, subject variant, and object condition. Contains SCV, VCV, and RCV propositions in a single merged section. Keyed by proposition ID (e.g., `SCV001234567-PATH` for SCVs, `VCV000012582.63-G-PATH-CP` for VCVs).

### Statement Sections

These sections contain the clinical classification statements:

**`scv`** — Submitted clinical classification statements. Each SCV carries a classification, strength, direction, proposition reference, contributions (with submitter references), evidence lines, citations, assertion method, and extensions with submitted condition provenance. Keyed by `clinvar.submission:{scv_id}.{version}`.

**`vcv`** — Variation-level aggregate classification statements. VCVs aggregate SCVs across a variation by classification, priority (somatic tiers), and submission level contribution. Evidence lines reference contributing SCVs via `#/scv/` or lower-level VCV groupings via `#/vcv/`. Keyed by the VCV layer ID.

**`rcv`** — Condition-level aggregate classification statements. RCVs follow the same aggregation structure as VCVs but are scoped to a specific RCV accession (variation + condition). Evidence lines reference SCVs and lower-level RCV groupings.

---

## JSON Pointer References

Objects reference each other using `#/{section}/{key}` strings instead of embedding full objects inline. This keeps the file compact and enables consumers to resolve references by looking up the key in the named section.

### Reference Patterns

| Pattern | Example | Resolves To |
| --- | --- | --- |
| `#/sequenceReference/{key}` | `#/sequenceReference/SQ.0iKlIQk2oZLoeOG9P1riRU6hvL5Ux8TV` | Sequence reference object |
| `#/location/{key}` | `#/location/ga4gh:SL.Eg_6kV6Bb4FMjm9kEolHZ_4NhU8lBEsZ` | Sequence location object |
| `#/allele/{key}` | `#/allele/ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY` | VRS allele object |
| `#/gene/{key}` | `#/gene/ncbigene:3077` | Gene object |
| `#/variation/{key}` | `#/variation/clinvar:10` | Categorical variant object |
| `#/condition/{key}` | `#/condition/clinvar.trait:9580` | Condition object |
| `#/conditionSet/{key}` | `#/conditionSet/clinvar.traitset:1234` | Condition set object |
| `#/submitter/{key}` | `#/submitter/clinvar.submitter:500139` | Submitter object |
| `#/proposition/{key}` | `#/proposition/SCV001234567-PATH` | Proposition object |
| `#/scv/{key}` | `#/scv/clinvar.submission:SCV001234567.1` | SCV statement object |
| `#/vcv/{key}` | `#/vcv/VCV000012582.63-G-PATH-CP` | VCV statement object |
| `#/rcv/{key}` | `#/rcv/RCV000012345.8-G-PATH-CP` | RCV statement object |

### Resolving References

To resolve a reference string like `#/allele/ga4gh:VA.abc123`:

1. Split on `/` — the second segment is the section name (`allele`), the third is the key (`ga4gh:VA.abc123`)
2. Look up the key in the named section of the root object
3. The value at that key is the resolved object

### Reference Depth

References are **one level deep** — a resolved object may itself contain references, but those are always to other root-level sections, never nested references within references. A consumer can fully resolve any object by following at most 2-3 hops (e.g., variation → allele → location → sequenceReference).

---

## MappableConcept Pattern

Several fields across statements use a **MappableConcept** structure — a typed object with a display name, optional primary coding, and optional extensions:

```json
{
  "conceptType": "Classification",
  "name": "Pathogenic",
  "primaryCoding": {
    "code": "pathogenic",
    "system": "ACMG Guidelines, 2015"
  },
  "extensions": [ ... ]
}
```

Fields that use this pattern:

- **`classification`** — the clinical significance label (`conceptType: "Classification"`)
- **`strength`** — the evidence strength (`conceptType: "Strength"`)
- **`evidenceOutcome`** — the evidence line outcome (`conceptType: "Outcome"`)
- **`strengthOfEvidenceProvided`** — the evidence line strength (`conceptType: "Strength"`)

The `conceptType` identifies the kind of concept. The `name` is the human-readable display value. The `primaryCoding` provides a machine-readable code and system when available. Not all instances carry `primaryCoding` — aggregate VCV/RCV classifications, for example, may only have `conceptType` and `name`.

---

## Future: Inlining Tool

The bundle format is designed to support a community tool that converts the single compressed file into **inlined output** at various levels of detail — from complete (all references resolved inline) to minimal (references only). This tool is under development and will be documented here when available.
