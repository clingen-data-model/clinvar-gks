# ID References

## Overview

The ClinVar-GKS bundle uses typed identifiers and `#/` JSON pointer references to link objects across bundle sections. This page documents all identifier formats, reference patterns, and how to resolve them.

---

## Identifier Namespaces

All ClinVar-GKS identifiers use a prefix namespace to indicate the resource type:

| Prefix | Resource Type | Format | Example |
| --- | --- | --- | --- |
| `clinvar:` | Variation | `clinvar:{variation_id}` | `clinvar:12582` |
| `clinvar.submission:` | SCV submission | `clinvar.submission:SCV{id}.{version}` | `clinvar.submission:SCV001571657.2` |
| `clinvar.submitter:` | Submitter organization | `clinvar.submitter:{submitter_id}` | `clinvar.submitter:508027` |
| `clinvar.trait:` | Condition / trait | `clinvar.trait:{trait_id}` | `clinvar.trait:9580` |
| `clinvar.traitset:` | Condition set | `clinvar.traitset:{trait_set_id}` | `clinvar.traitset:1234` |
| `ncbigene:` | Gene | `ncbigene:{gene_id}` | `ncbigene:3077` |
| `ga4gh:` | VRS identity | `ga4gh:{type}.{digest}` | `ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY` |
| `SQ.` | Sequence reference | `SQ.{digest}` | `SQ.0iKlIQk2oZLoeOG9P1riRU6hvL5Ux8TV` |

VCV and RCV aggregate statement IDs use a hierarchical format without a namespace prefix — see [VCV Statement IDs](#vcv-statement-ids) and [RCV Statement IDs](#rcv-statement-ids).

---

## JSON Pointer References

Objects reference each other using `#/{section}/{key}` strings. To resolve a reference:

1. Split the string on `/` — the second segment is the bundle section name, the third is the key
2. Look up the key in the named section of the bundle

### Reference Patterns

| Pattern | Example | Target Section |
| --- | --- | --- |
| `#/sequenceReference/{key}` | `#/sequenceReference/SQ.0iKlIQk2oZLoeOG9P1riRU6hvL5Ux8TV` | `sequenceReference` |
| `#/location/{key}` | `#/location/ga4gh:SL.Eg_6kV6Bb4FMjm9kEolHZ_4NhU8lBEsZ` | `location` |
| `#/allele/{key}` | `#/allele/ga4gh:VA.ELQCnIBGqaTl0AEE0Az18XZ2cgIHAQIY` | `allele` |
| `#/gene/{key}` | `#/gene/ncbigene:3077` | `gene` |
| `#/variation/{key}` | `#/variation/clinvar:10` | `variation` |
| `#/condition/{key}` | `#/condition/clinvar.trait:9580` | `condition` |
| `#/conditionSet/{key}` | `#/conditionSet/clinvar.traitset:1234` | `conditionSet` |
| `#/submitter/{key}` | `#/submitter/clinvar.submitter:500139` | `submitter` |
| `#/proposition/{key}` | `#/proposition/SCV001234567-PATH` | `proposition` |
| `#/scv/{key}` | `#/scv/clinvar.submission:SCV001234567.1` | `scv` |
| `#/vcv/{key}` | `#/vcv/VCV000012582.63-G-PATH-CP` | `vcv` |
| `#/rcv/{key}` | `#/rcv/RCV000012345.8-G-PATH-CP` | `rcv` |

### Where References Appear

| Object Type | Field | References |
| --- | --- | --- |
| Location | `sequenceReference` | `#/sequenceReference/` |
| Allele | `location` | `#/location/` |
| Variation | `members[]` | `#/allele/` |
| Variation | `constraints[].allele` | `#/allele/` |
| Variation | `constraints[].location` | `#/location/` |
| Variation | `extensions[].clinvarGeneList[].gene` | `#/gene/` |
| Proposition | `subjectVariant` | `#/variation/` |
| Proposition | `objectCondition` | `#/condition/` or `#/conditionSet/` |
| SCV Statement | `proposition` | `#/proposition/` |
| SCV Statement | `contributions[].contributor` | `#/submitter/` |
| VCV Statement | `proposition` | `#/proposition/` |
| VCV Statement | `evidenceLines[].evidenceItems[]` | `#/scv/` or `#/vcv/` |
| RCV Statement | `proposition` | `#/proposition/` |
| RCV Statement | `evidenceLines[].evidenceItems[]` | `#/scv/` or `#/rcv/` |

### Resolution Example

```python
import gzip
import json

# Load the bundle
with gzip.open("clinvar-gks-current.json.gz", "rt") as f:
    bundle = json.load(f)

def resolve(bundle, ref):
    """Resolve a #/section/key reference to the target object."""
    parts = ref.lstrip("#/").split("/", 1)
    return bundle[parts[0]][parts[1]]

# Look up a variation
variant = bundle["variation"]["clinvar:10"]

# Resolve its allele member
allele = resolve(bundle, variant["members"][0])

# Resolve the allele's location
location = resolve(bundle, allele["location"])

# Resolve the location's sequence reference
seq_ref = resolve(bundle, location["sequenceReference"])
```

---

## SCV Proposition IDs

SCV proposition IDs combine the SCV accession with an uppercase proposition type code:

```text
{scv_id}-{PROP_CODE}
```

| Component | Description | Examples |
| --- | --- | --- |
| `scv_id` | SCV accession (without version) | `SCV001234567` |
| `PROP_CODE` | Uppercase proposition type code | `PATH`, `ONCO`, `SCI`, `ASSOC`, `RF`, `DR`, `NP`, `OTH`, `PROT`, `AFF`, `CS`, `CONF`, `UNDEF` |

Examples: `SCV001234567-PATH`, `SCV004565358-PROG`, `SCV004565358-TR`

Target (somatic evidence line) propositions use the clinical impact assertion type codes: `PROG`, `DIAG`, `TR`.

---

## VCV Statement IDs

VCV aggregate statements use a hierarchical ID format reflecting the aggregation layer:

| Layer | Format | Example |
| --- | --- | --- |
| Classification | `{VCV}.{ver}-{group}-{PROP}-{level}[-{TIER}]` | `VCV000012582.63-G-PATH-CP` |
| Priority | `{VCV}.{ver}-{group}-{PROP}-{level}` | `VCV000012582.63-S-SCI-CP` |
| Aggregate | `{VCV}.{ver}-{group}-{PROP}` | `VCV000012582.63-G-PATH` |

Components:

- **group** — statement group: `G` (Germline), `S` (Somatic), `O` (Oncogenicity)
- **PROP** — proposition type code (uppercase): `PATH`, `ONCO`, `SCI`, `ASSOC`, etc.
- **level** — submission level: `PG`, `EP`, `CP`, `NOCP`, `NOCL`, `FLAG`
- **TIER** — classification tier (somatic only, uppercase): `TIER 1`, `TIER 2`, etc.

---

## RCV Statement IDs

RCV aggregate statements follow the same pattern as VCV but with an RCV accession:

| Layer | Format | Example |
| --- | --- | --- |
| Classification | `{RCV}.{ver}-{group}-{PROP}-{level}[-{TIER}]` | `RCV000012345.10-G-PATH-CP` |
| Priority | `{RCV}.{ver}-{group}-{PROP}-{level}` | `RCV000012345.10-S-SCI-CP` |
| Aggregate | `{RCV}.{ver}-{group}-{PROP}` | `RCV000012345.10-G-PATH` |

The component abbreviations are the same as VCV.

---

## VCV/RCV Proposition IDs

VCV and RCV proposition IDs use the accession (without version) in the same layered format:

| Layer | Format | Example |
| --- | --- | --- |
| Classification | `{accession}-{group}-{PROP}-{level}[-{TIER}]` | `VCV000012582-G-PATH-CP` |
| Priority | `{accession}-{group}-{PROP}-{level}` | `VCV000012582-S-SCI-CP` |
| Aggregate | `{accession}-{group}-{PROP}` | `VCV000012582-G-PATH` |

---

## External Cross-References

Variation records contain `mappings` to external databases using standardized URL formats:

| Database | URL Pattern |
| --- | --- |
| MedGen | `https://identifiers.org/medgen:{id}` |
| OMIM | `http://www.omim.org/entry/{id}` |
| HPO | `https://identifiers.org/{id}` |
| MONDO | `https://identifiers.org/mondo:{id}` |
| Orphanet | `http://www.orpha.net/ORDO/Orphanet_{id}` |
| dbSNP | `https://identifiers.org/dbsnp:rs{id}` |
| ClinGen | `https://reg.clinicalgenome.org/.../by_caid?caid={id}` |
| UniProtKB | `https://www.uniprot.org/uniprot/{id}` |
| GTR | `https://www.ncbi.nlm.nih.gov/gtr/tests/{id}` |
| PubMed | `https://pubmed.ncbi.nlm.nih.gov/{id}` |

Condition records contain `mappings` to disease/phenotype databases (OMIM, MONDO, HPO, Orphanet, MeSH) and a `primaryCoding` from MedGen.
