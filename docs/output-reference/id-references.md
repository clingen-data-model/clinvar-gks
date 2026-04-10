# ID References and Cross-File Resolution

## Overview

The ClinVar-GKS output files use a system of typed identifiers to reference objects both within and across files. Some fields contain full embedded objects (inline), while others contain ID-only references that resolve to objects in a separate export file. This page documents all identifier formats, where they appear, and how to resolve cross-file references.

---

## Identifier Namespaces

All ClinVar-GKS identifiers use a prefix namespace to indicate the type of resource:

| Prefix | Resource Type | Format | Example |
| --- | --- | --- | --- |
| `clinvar:` | Variation | `clinvar:{variation_id}` | `clinvar:12582` |
| `clinvar.submission:` | SCV submission | `clinvar.submission:SCV{id}.{version}` | `clinvar.submission:SCV001571657.2` |
| `clinvar.submitter:` | Submitter organization | `clinvar.submitter:{submitter_id}` | `clinvar.submitter:508027` |
| `ga4gh:` | VRS identity | `ga4gh:{type}.{digest}` | `ga4gh:VA.xXBYkzzu1AH0oyMKlbBtP2` |

VCV and RCV aggregate statement IDs use a hierarchical format without a namespace prefix — see [VCV Statement IDs](#vcv-statement-ids) and [RCV Statement IDs](#rcv-statement-ids).

---

## Cross-File Reference Resolution

When a field contains an ID-only reference (rather than a full embedded object), the referenced object can be found in a specific export file by matching the `id` field.

### Resolution Table

| Reference Field | Appears In | ID Format | Resolves To | Target File |
| --- | --- | --- | --- | --- |
| `proposition.subjectVariant` | SCV statements (by-ref) | `clinvar:{variation_id}` | Categorical Variant record | `variation.jsonl.gz` |
| `proposition.subjectVariant` | VCV statements | `clinvar:{variation_id}` | Categorical Variant record | `variation.jsonl.gz` |
| `evidenceItems[].id` (leaf) | VCV statements | `clinvar.submission:SCV{id}.{ver}` | SCV Statement record | `scv_by_ref.jsonl.gz` |
| `proposition.subjectVariant` | RCV statements | `clinvar:{variation_id}` | Categorical Variant record | `variation.jsonl.gz` |
| `evidenceItems[].id` (leaf) | RCV statements | `clinvar.submission:SCV{id}.{ver}` | SCV Statement record | `scv_by_ref.jsonl.gz` |
| `contributor.id` | SCV statements | `clinvar.submitter:{id}` | Submitter organization | Not exported as standalone — embedded in SCV records |
| `constraints[].definingContext.id` | Categorical Variants | `ga4gh:{type}.{digest}` | VRS allele/copy number | Embedded within the same record |

### Resolution Example

A VCV statement's leaf-level evidence items contain ID references to SCV submissions:

```json
{
  "type": "EvidenceLine",
  "evidenceItems": [
    {"id": "clinvar.submission:SCV001571657.2"},
    {"id": "clinvar.submission:SCV000329383.7"}
  ]
}
```

To resolve these, look up each ID in `scv_by_ref.jsonl.gz`:

```python
import gzip, json

# Build an index of SCV records
scv_index = {}
with gzip.open("scv_by_ref.jsonl.gz", "rt") as f:
    for line in f:
        rec = json.loads(line)
        scv_index[rec["id"]] = rec

# Resolve references from a VCV statement
for evidence_item in vcv["evidenceLines"][0]["evidenceItems"]:
    if "type" not in evidence_item:  # leaf-level ID reference
        full_scv = scv_index.get(evidence_item["id"])
```

Similarly, a variant reference in any statement resolves to a record in `variation.jsonl.gz`:

```python
catvar_index = {}
with gzip.open("variation.jsonl.gz", "rt") as f:
    for line in f:
        rec = json.loads(line)
        catvar_index[rec["id"]] = rec

# Resolve from SCV or VCV
variant = catvar_index.get(statement["proposition"]["subjectVariant"])
```

---

## VCV Statement IDs

VCV aggregate statements use a hierarchical ID format that reflects the aggregation layer. RCV statements follow the same patterns with an RCV accession -- see [RCV Statement IDs](#rcv-statement-ids). Each layer's ID is built by progressively stripping components from right to left:

| Layer | Format | Example |
| --- | --- | --- |
| L1 (Base) | `{VCV}.{ver}-{group}-{prop}-{level}[-{tier}]` | `VCV000012582.63-G-path-CP` |
| L2 (Tier) | `{VCV}.{ver}-{group}-{prop}-{level}` | `VCV000012582.63-G-sci-CP` |
| L3 (Submission Level) | `{VCV}.{ver}-{group}-{prop}` | `VCV000012582.63-G-path` |
| L4 (Statement Group) | `{VCV}.{ver}-{group}` | `VCV000012582.63-G` |

Components:

- **group** — statement group: `G` (Germline), `S` (Somatic)
- **prop** — proposition type: `path` (Pathogenicity), `onco` (Oncogenicity), `sci` (Somatic Clinical Impact), `dr` (Drug Response), `np` (Not Provided), `assoc` (Association), `other` (Other)
- **level** — submission level: `PG`, `EP`, `PGEP`, `CP`, `NOCP`, `NOCL`, `FLAG`
- **tier** — classification tier (somatic only): `tier 1`, `tier 2`, etc.

Within a VCV statement's nested evidence lines, each evidence item references the next lower layer by its ID. The top-level L4 statement references L3 statements, which reference L2 or L1 statements, which reference individual SCVs.

---

## RCV Statement IDs

RCV aggregate statements use the same hierarchical ID format as VCV, but with an RCV accession instead of a VCV accession:

| Layer | Format | Example |
| --- | --- | --- |
| L1 (Base) | `{RCV}.{ver}-{group}-{prop}-{level}[-{tier}]` | `RCV000012345.10-G-path-CP` |
| L2 (Tier) | `{RCV}.{ver}-{group}-{prop}-{level}` | `RCV000012345.10-G-sci-CP` |
| L3 (Submission Level) | `{RCV}.{ver}-{group}-{prop}` | `RCV000012345.10-G-path` |
| L4 (Statement Group) | `{RCV}.{ver}-{group}` | `RCV000012345.10-G` |

The component abbreviations (group, prop, level, tier) are the same as those defined in [VCV Statement IDs](#vcv-statement-ids).

### RCV Proposition IDs

RCV proposition IDs use the RCV accession (without version) in a hyphen-separated format:

| Layer | Format | Example |
| --- | --- | --- |
| L1 | `{rcv_accession}-{group}-{prop}[-{level}][-{tier}]` | `RCV000012345-G-path-CP` |
| L2 | `{rcv_accession}-{group}-{prop}-{level}` | `RCV000012345-G-sci-CP` |
| L3 | `{rcv_accession}-{group}-{prop}` | `RCV000012345-G-path` |
| L4 | `{rcv_accession}-{group}` | `RCV000012345-G` |

RCV proposition IDs are internal to the statement structure and not used for cross-file resolution.

---

## VCV Proposition IDs

Each VCV statement's `proposition.id` uses a dot-separated format parallel to the statement ID:

| Layer | Format | Example |
| --- | --- | --- |
| L1 | `{variation_id}.{group}.{prop}.{level}[.{tier}]` | `12582.G.path.CP` |
| L2 | `{variation_id}.{group}.{prop}.{level}` | `12582.G.sci.CP` |
| L3 | `{variation_id}.{group}.{prop}` | `12582.G.path` |
| L4 | `{variation_id}.{group}` | `12582.G` |

Proposition IDs are internal to the statement structure and not used for cross-file resolution.

---

## Inline vs By-Reference

The pipeline produces some objects in both forms:

| Object | Inline Location | By-Reference Location |
| --- | --- | --- |
| Categorical Variant | `scv_inline.jsonl.gz` (embedded in proposition) | `scv_by_ref.jsonl.gz` (ID reference to `variation.jsonl.gz`) |
| SCV Statement | VCV nested evidence items (L1 PRE inlines full structure) | VCV leaf evidence items (ID reference to `scv_by_ref.jsonl.gz`) |
| VCV Sub-Statement | VCV nested evidence lines (higher layers inline lower layers) | N/A — always inlined within parent |

VCV statements use a mixed approach: the nested evidence structure fully inlines sub-statements at each layer, but the leaf-level evidence items (individual SCVs) are ID-only references.

---

## External Cross-References

Categorical Variant records contain `mappings` to external databases using standardized URL formats:

| Database | URL Pattern |
| --- | --- |
| MedGen | `https://identifiers.org/medgen:{id}` |
| OMIM | `https://identifiers.org/mim:{id}` |
| HPO | `https://identifiers.org/{id}` |
| MONDO | `https://identifiers.org/mondo:{id}` |
| Orphanet | `https://identifiers.org/orphanet.ordo:Orphanet_{id}` |
| dbSNP | `https://identifiers.org/dbsnp:rs{id}` |
| ClinGen | `https://reg.clinicalgenome.org/.../by_caid?caid={id}` |
| PubMed | `https://pubmed.ncbi.nlm.nih.gov/{id}` |

See the [gks_xref_iri_templates](../pipeline/cat-vrs/index.md) table for the complete list of URL template mappings.
