# Categorical Variant Extensions

## Overview

Categorical variant records contain `extensions` arrays at multiple levels of the JSON structure. Extensions carry ClinVar-specific information, VRS processing details, and linked data that are not part of the GA4GH Cat-VRS specification but are essential for clinical interpretation.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`, where the value type varies by extension. Most extensions carry simple scalar values (string, boolean, etc.). Extensions with complex value types — arrays of structured objects — are documented as custom extension structures in a dedicated section below.

---

## Extension Reference

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>categoricalVariationType</code><br><em>CategoricalVariant</em><br>string</td>
      <td>The Cat-VRS category assigned to this variation: <code>CanonicalAllele</code>, <code>CategoricalCnvChange</code>, <code>CategoricalCnvCount</code>, or <code>Non-Constrained</code>. Determines which constraint types are generated.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "categoricalVariationType", "value": "CanonicalAllele" }</code></pre></td>
    </tr>
    <tr>
      <td><code>definingVrsVariationType</code><br><em>CategoricalVariant</em><br>string</td>
      <td>The VRS class assigned during variation identity processing (e.g., <code>Allele</code>, <code>CopyNumberChange</code>, <code>CopyNumberCount</code>, <code>Not Available</code>). Reflects the upstream classification used to route the variant through VRS processing.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "definingVrsVariationType", "value": "Allele" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarVariationType</code><br><em>CategoricalVariant</em><br>string</td>
      <td>The variation type as reported by ClinVar (e.g., <code>Deletion</code>, <code>single nucleotide variant</code>, <code>Duplication</code>, <code>Indel</code>). Present when ClinVar provides a variation type.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarVariationType", "value": "Deletion" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarSubclassType</code><br><em>CategoricalVariant</em><br>string</td>
      <td>The variation subclass as reported by ClinVar (e.g., <code>SimpleAllele</code>, <code>Haplotype</code>, <code>CompoundHeterozygote</code>). Present when ClinVar provides a subclass type.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarSubclassType", "value": "SimpleAllele" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarCytogeneticLocation</code><br><em>CategoricalVariant</em><br>string</td>
      <td>The cytogenetic band location of the variation (e.g., <code>1p36.22</code>, <code>17q21.31</code>). Present when ClinVar provides a cytogenetic location.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarCytogeneticLocation", "value": "1p36.22" }</code></pre></td>
    </tr>
    <tr>
      <td><code>vrsPreProcessingIssue</code><br><em>CategoricalVariant</em><br>string</td>
      <td>Issues detected during VRS pre-processing of the variation's input expressions. Present only when issues exist. May contain multiple issues separated by newlines.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "vrsPreProcessingIssue", "value": "HGVS expression not valid: ..." }</code></pre></td>
    </tr>
    <tr>
      <td><code>vrsProcessingException</code><br><em>CategoricalVariant</em><br>string</td>
      <td>Errors returned by the external VRS Python processing service. Present only when errors occurred during VRS resolution.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "vrsProcessingException", "value": "Unable to resolve ..." }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarHgvsList</code><br><em>CategoricalVariant</em><br>array&lt;<a href="#hgvs-list">HgvsListItem</a>&gt;</td>
      <td>Complete list of HGVS expressions from ClinVar for this variation, including nucleotide and protein expressions, molecular consequences (SO terms), and MANE transcript designations. See <a href="#hgvs-list">HGVS List</a> custom extension structure below.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarHgvsList", "value": [<a href="#hgvs-list">...</a>] }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarGeneList</code><br><em>CategoricalVariant</em><br>array&lt;<a href="#gene-list">GeneListItem</a>&gt;</td>
      <td>Gene associations for this variation from ClinVar, including Entrez gene IDs, HGNC IDs, gene symbols, relationship types, and identifier IRIs. See <a href="#gene-list">Gene List</a> custom extension structure below.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarGeneList", "value": [<a href="#gene-list">...</a>] }</code></pre></td>
    </tr>
    <tr>
      <td><code>assembly</code><br><em>SequenceReference</em><br>string</td>
      <td>The genome assembly name for this sequence reference (e.g., <code>GRCh38</code>, <code>GRCh37</code>, <code>NCBI36</code>). Found within <code>members[].location.sequenceReference.extensions[]</code> and <code>constraints[].allele.location.sequenceReference.extensions[]</code>.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "assembly", "value": "GRCh38" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Custom Extension Structures

Extensions with complex value types use structured objects rather than simple scalars. The structures below define the shape of each custom extension's `value` field.

### HGVS List

The `clinvarHgvsList` extension contains an array of HGVS expression objects, each representing one expression entry from ClinVar's `HGVSlist` element for the variation. Each object may contain:

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Field (type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>nucleotideExpression</code><br>object</td>
      <td>The nucleotide HGVS expression with <code>syntax</code> (e.g., <code>hgvs.c</code>, <code>hgvs.g</code>) and <code>value</code> (the HGVS string).</td>
    </tr>
    <tr>
      <td><code>nucleotideType</code><br>string</td>
      <td>The type of nucleotide expression as reported by ClinVar (e.g., <code>coding</code>, <code>genomic</code>, <code>genomic, top-level</code>).</td>
    </tr>
    <tr>
      <td><code>maneSelect</code><br>boolean</td>
      <td><code>true</code> if this transcript is designated as MANE Select. Absent when not applicable.</td>
    </tr>
    <tr>
      <td><code>manePlus</code><br>boolean</td>
      <td><code>true</code> if this transcript is designated as MANE Plus Clinical. Absent when not applicable.</td>
    </tr>
    <tr>
      <td><code>proteinExpression</code><br>object</td>
      <td>The protein HGVS expression with <code>syntax</code> (typically <code>hgvs.p</code>) and <code>value</code>. Present only when a protein-level expression exists for the nucleotide expression.</td>
    </tr>
    <tr>
      <td><code>molecularConsequence</code><br>array</td>
      <td>Sequence Ontology terms describing the predicted molecular consequence. Each entry includes <code>code</code> (SO identifier), <code>system</code>, <code>name</code> (SO term label), and <code>iris</code> (identifiers.org link).</td>
    </tr>
  </tbody>
</table>

#### Example

```json
{
  "nucleotideExpression": {
    "syntax": "hgvs.c",
    "value": "NM_004958.4:c.5992_5993del"
  },
  "nucleotideType": "coding",
  "maneSelect": true,
  "proteinExpression": {
    "syntax": "hgvs.p",
    "value": "NP_004949.3:p.Met1998fs"
  },
  "molecularConsequence": [
    {
      "name": "frameshift_variant",
      "system": "http://www.sequenceontology.org/browser/",
      "code": "SO:0001589",
      "iris": [
        "http://www.sequenceontology.org/browser/release_2.5.3/term/SO:0001589"
      ]
    }
  ]
}
```

### Gene List

The `clinvarGeneList` extension contains an array of gene association objects. Each object includes:

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Field (type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>entrez_gene_id</code><br>string</td>
      <td>NCBI Entrez Gene identifier.</td>
    </tr>
    <tr>
      <td><code>hgnc_id</code><br>string</td>
      <td>HGNC gene identifier (e.g., <code>HGNC:1234</code>). May be null for genes without an HGNC assignment.</td>
    </tr>
    <tr>
      <td><code>symbol</code><br>string</td>
      <td>The gene symbol (e.g., <code>BRCA1</code>, <code>MTOR</code>).</td>
    </tr>
    <tr>
      <td><code>relationship_type</code><br>string</td>
      <td>The relationship between the variation and the gene as reported by ClinVar (e.g., <code>within single gene</code>, <code>genes overlapped by variant</code>).</td>
    </tr>
    <tr>
      <td><code>source</code><br>string</td>
      <td>The source of the gene association (e.g., <code>submitted</code>, <code>calculated</code>).</td>
    </tr>
    <tr>
      <td><code>iris</code><br>array</td>
      <td>Identifier IRIs for the gene, including links to identifiers.org (HGNC and/or NCBI Gene) and NCBI Gene pages.</td>
    </tr>
  </tbody>
</table>

#### Example

```json
{
  "entrez_gene_id": "2475",
  "hgnc_id": "HGNC:3942",
  "symbol": "MTOR",
  "relationship_type": "within single gene",
  "source": "calculated",
  "iris": [
    "https://identifiers.org/hgnc:3942",
    "https://www.ncbi.nlm.nih.gov/gene/2475"
  ]
}
```
