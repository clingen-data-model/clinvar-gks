# Data Model

The ClinVar-GKS release file organizes data into bundle sections, each containing objects of a specific class. These classes form a directed graph of relationships — variants reference alleles, alleles reference locations, statements reference propositions, and so on.

This page provides a visual overview of how the classes relate to each other, with links to detailed documentation for each class.

---

## Class Relationship Diagram

The diagram below shows how the bundle classes relate to each other. Arrows indicate reference direction — for example, a Variation references its Allele members, and an SCV Statement references its Proposition.

```mermaid
flowchart LR
    subgraph "<b>Genomic</b>"
        direction TB
        SR(["SequenceReference<br/><small>SQ.{digest}</small>"])
        LOC(["Location<br/><small>ga4gh:SL.{digest}</small>"])
        AL(["Allele<br/><small>ga4gh:VA.{digest}</small>"])
        G(["Gene<br/><small>ncbigene:{id}</small>"])
        V(["<b>Variation</b><br/><small>clinvar:{id}</small>"])
    end

    subgraph "<b>Clinical</b>"
        direction TB
        COND(["Condition<br/><small>clinvar.trait:{id}</small>"])
        CS(["ConditionSet<br/><small>clinvar.traitset:{id}</small>"])
        SUB(["Submitter<br/><small>clinvar.submitter:{id}</small>"])
        PROP(["<b>Proposition</b><br/><small>{scv}-{CODE}</small>"])
    end

    subgraph "<b>Statements</b>"
        direction TB
        SCV(["<b>SCV</b><br/><small>clinvar.submission:{id}.{ver}</small>"])
        VCV(["<b>VCV</b><br/><small>{vcv}-{group}-{prop}-{level}</small>"])
        RCV(["<b>RCV</b><br/><small>{rcv}-{group}-{prop}-{level}</small>"])
    end

    %% Genomic chain
    LOC -- "#/sequenceReference/" --> SR
    AL -- "#/location/" --> LOC
    V -- "#/allele/" --> AL
    V -. "#/gene/" .-> G

    %% Clinical links
    CS -- "#/condition/" --> COND
    PROP -- "#/variation/" --> V
    PROP -- "#/condition/" --> COND
    PROP -. "#/conditionSet/" .-> CS

    %% Statement links
    SCV -- "#/proposition/" --> PROP
    SCV -- "#/submitter/" --> SUB
    VCV -- "#/proposition/" --> PROP
    VCV -- "#/scv/" --> SCV
    VCV -. "#/vcv/" .-> VCV
    RCV -- "#/proposition/" --> PROP
    RCV -- "#/scv/" --> SCV
    RCV -. "#/rcv/" .-> RCV
```

Solid arrows represent primary references. Dashed arrows represent optional or self-referencing relationships (e.g., VCV statements can reference lower-level VCV groupings, and genes are referenced from variation extensions).

---

## Genomic Classes

These classes represent the variant and its genomic context. VRS types (SequenceReference, Location, Allele) use their upstream GA4GH schemas directly. ClinVar-specific profiles are documented under [Variations](variations.md).

| Class | Bundle Section | Key Pattern | Description |
| --- | --- | --- | --- |
| SequenceReference | `sequenceReference` | `SQ.{digest}` | Reference sequence with refget accession, molecule type, and assembly |
| Location | `location` | `ga4gh:SL.{digest}` | Position or range on a sequence reference |
| Allele | `allele` | `ga4gh:VA.{digest}` | Specific sequence change at a location |
| Gene | `gene` | `ncbigene:{id}` | Gene record with Entrez ID, HGNC ID, and symbol |
| [ClinvarCategoricalVariant](ClinvarCategoricalVariant.md) | `variation` | `clinvar:{id}` | ClinVar variation with Cat-VRS representation and extensions |

See [Variations](variations.md) for the full variant type hierarchy and extension documentation.

---

## Clinical Classes

These classes represent the conditions, submitters, and propositions that support clinical classification statements. Conditions and submitters use upstream GA4GH types. ClinVar-specific proposition types are documented under [Propositions](propositions.md).

| Class | Bundle Section | Key Pattern | Description |
| --- | --- | --- | --- |
| Condition | `condition` | `clinvar.trait:{id}` | Disease or phenotype with MedGen coding and cross-references |
| ConditionSet | `conditionSet` | `clinvar.traitset:{id}` | Grouping of conditions with AND/OR membership operator |
| Submitter | `submitter` | `clinvar.submitter:{id}` | Submitting organization |
| [ClinvarProposition](ClinvarProposition.md) | `proposition` | `{scv_id}-{CODE}` | Classification proposition (12 types) |

See [Propositions](propositions.md) for the full type/code/predicate reference.

---

## Statement Classes

These classes represent clinical classification statements at different levels of aggregation. All are profiles of the VA-Spec Statement type documented under [Statements](statements.md).

| Class | Bundle Section | Key Pattern | Description |
| --- | --- | --- | --- |
| [ClinvarScvStatement](ClinvarScvStatement.md) | `scv` | `clinvar.submission:{id}.{ver}` | Submitted clinical classification |
| [ClinvarVcvStatement](ClinvarVcvStatement.md) | `vcv` | `{vcv}-{group}-{prop}-{level}` | Variant-level aggregate |
| [ClinvarRcvStatement](ClinvarRcvStatement.md) | `rcv` | `{rcv}-{group}-{prop}-{level}` | Condition-level aggregate |
| [ClinvarSomaticEvidenceLine](ClinvarSomaticEvidenceLine.md) | (nested) | — | Somatic clinical impact evidence line |

See [Statements](statements.md) for the aggregation structure and [Evidence Lines](evidence.md) for the somatic tier mapping.
