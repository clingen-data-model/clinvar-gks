# Getting Started

## Download the Latest Release

The current ClinVar-GKS release is available as a single compressed JSON file:

```
https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/
```

Download and decompress:

```bash
# Download the latest release
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar-gks-current.json.gz

# Decompress
gunzip clinvar-gks-current.json.gz
```

See [Data Access](data-access/index.md) for the full release schedule, archives, and file naming conventions.

---

## What's in the File

The release file is a single JSON object with **dictionary sections** at the root level. Each section is a keyed collection of objects — the key is the object's unique identifier, and the value is the object itself.

```json
{
  "sequenceReference": { "SQ.abc123": { ... } },
  "location":          { "ga4gh:SL.xyz789": { ... } },
  "allele":            { "ga4gh:VA.def456": { ... } },
  "gene":              { "ncbigene:3077": { ... } },
  "variation":         { "clinvar:10": { ... } },
  "condition":         { "clinvar.trait:9580": { ... } },
  "conditionSet":      { "clinvar.traitset:1234": { ... } },
  "submitter":         { "clinvar.submitter:500139": { ... } },
  "proposition":       { "SCV001234567-PATH": { ... } },
  "scv":               { "clinvar.submission:SCV001234567.1": { ... } },
  "vcv":               { "VCV000012582.63-G-PATH-CP": { ... } },
  "rcv":               { "RCV000012345.8-G-PATH-CP": { ... } }
}
```

Objects reference each other using `#/` JSON pointer strings. For example, an allele references its location as `"#/location/ga4gh:SL.xyz789"`, and an SCV statement references its proposition as `"#/proposition/SCV001234567-PATH"`.

See [Output Format](output-reference/overview.md) for the full structure and reference patterns.

---

## Quick Example

To find the classification statements for a specific variant, start with the variation ID. ClinVar variation 10 (the HFE p.His63Asp variant) has the key `clinvar:10` in the `variation` section:

```json
{
  "variation": {
    "clinvar:10": {
      "id": "clinvar:10",
      "type": "CategoricalVariant",
      "name": "NM_000410.4(HFE):c.187C>G (p.His63Asp)",
      "members": ["#/allele/ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY"],
      "constraints": [ ... ],
      "extensions": [ ... ],
      "mappings": [ ... ]
    }
  }
}
```

The SCV statements for this variant reference it via `#/variation/clinvar:10` in their propositions. To find them, look for entries in the `proposition` section where `subjectVariant` matches, then find the corresponding `scv` entries that reference those propositions.

---

## Key Concepts

**Statements** are the core unit of ClinVar-GKS. Each statement represents a clinical classification — either submitted (SCV), aggregated per variation (VCV), or aggregated per condition (RCV). Statements carry:

- A **classification** — the clinical significance label (e.g., Pathogenic, Likely benign)
- A **proposition** — what the classification asserts (variant X causes condition Y)
- **Direction** and **strength** — whether the evidence supports, disputes, or is neutral toward the proposition
- **Evidence lines** — links to the contributing submissions or lower-level aggregations
- **Extensions** — provenance metadata including submitted conditions, review status, and submission details

**Propositions** define the relationship being classified — a variant's causal role for a condition, its oncogenic potential, or its clinical impact. Each proposition has a type (e.g., `VariantPathogenicityProposition`), a predicate (e.g., `isCausalFor`), a subject variant, and an object condition.

**Conditions** represent the diseases or phenotypes that classifications are made against. Single conditions reference `#/condition/clinvar.trait:{id}`, while multi-condition sets reference `#/conditionSet/clinvar.traitSet:{id}`.

---

## Next Steps

- [Output Format](output-reference/overview.md) — detailed guide to the bundled dictionary structure
- [Pipeline Overview](pipeline/index.md) — how the data is produced from ClinVar XML
- [Statement Profiles](profiles/index.md) — the 14 statement types and their classifications
- [Examples](data-access/examples.md) — annotated JSON examples
