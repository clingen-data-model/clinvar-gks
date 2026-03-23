# Condition Extensions

## Overview

Condition and condition set records contain `extensions` arrays at two structural levels — on each individual `Condition` and on the outer `Condition` or `ConditionSet` wrapper. Extensions carry ClinVar-specific metadata, submitter-provided cross-references, and trait assignment provenance that are not part of the GA4GH VA-Spec condition model but are essential for tracing how each SCV's submitted traits were resolved.

All extensions follow the structure `{ "name": "<extension_name>", "value": <value> }`, where the value type varies by extension. Most extensions carry simple scalar values (string). Extensions with complex value types — arrays of structured objects — are documented as custom extension structures in a dedicated section below.

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
      <td><code>clinvarTraitId</code><br><em>Condition</em><br>string</td>
      <td>The ClinVar trait ID for this condition. Corresponds to the <code>id</code> attribute on the <code>Trait</code> element in ClinVar XML.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarTraitId", "value": "9580" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarTraitType</code><br><em>Condition</em><br>string</td>
      <td>The trait type as classified by ClinVar (e.g., <code>Disease</code>, <code>Finding</code>, <code>PhenotypeInstruction</code>, <code>NamedProteinVariant</code>).</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarTraitType", "value": "Disease" }</code></pre></td>
    </tr>
    <tr>
      <td><code>aliases</code><br><em>Condition</em><br>string</td>
      <td>Comma-separated alternate names for the condition from ClinVar's trait record. Present only when alternate names exist.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "aliases", "value": "HBOC, Hereditary breast and ovarian cancer syndrome" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedScvXrefs</code><br><em>Condition</em><br>array&lt;<a href="#submitted-scv-xrefs">SubmittedXref</a>&gt;</td>
      <td>The original cross-references submitted by the submitter for this trait, preserved as-is. Present only when the submitter provided xrefs. See <a href="#submitted-scv-xrefs">Submitted SCV Xrefs</a> custom extension structure below.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedScvXrefs", "value": [<a href="#submitted-scv-xrefs">...</a>] }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedScvTraitAssignment</code><br><em>Condition</em><br>string</td>
      <td>Describes how the SCV trait was matched to a ClinVar trait mapping record during <a href="condition-mapping.md">condition mapping</a> (e.g., <code>scv trait: preferred name 'breast cancer'</code>). Present only when a trait mapping match was found.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedScvTraitAssignment", "value": "scv trait: preferred name 'breast-ovarian cancer, familial, 1'" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarScvTraitAssignment</code><br><em>Condition</em><br>string</td>
      <td>The assignment stage that resolved this SCV trait to a normalized RCV trait. See the <a href="condition-mapping.md#assignment-type-reference">Assignment Type Reference</a> in the condition mapping documentation for all possible values.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarScvTraitAssignment", "value": "rcv-tm medgen id" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarScvTraitMappingType:ref(val)</code><br><em>Condition</em><br>string</td>
      <td>The ClinVar trait mapping details formatted as <code>type:ref(val)</code>. Shows the mapping type, reference field, and matched value from the trait mapping record. Present only when a trait mapping was used.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarScvTraitMappingType:ref(val)", "value": "name:preferred(breast-ovarian cancer, familial, 1)" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarTraitSetType</code><br><em>Condition / ConditionSet</em><br>string</td>
      <td>The RCV-level trait set type as assigned by ClinVar (e.g., <code>Disease</code>, <code>Finding</code>, <code>DrugResponse</code>, <code>TraitChoice</code>). Present on the outer wrapper of both single-condition and multi-condition records.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarTraitSetType", "value": "Disease" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarTraitSetId</code><br><em>Condition / ConditionSet</em><br>string</td>
      <td>The ClinVar trait set ID. Corresponds to the <code>id</code> attribute on the RCV's <code>TraitSet</code> element.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarTraitSetId", "value": "2" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedScvTraitSetType</code><br><em>Condition / ConditionSet</em><br>string</td>
      <td>The submitter's original trait set type, included only when it differs from the RCV-assigned trait set type. Useful for identifying cases where ClinVar re-classified the trait set type.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedScvTraitSetType", "value": "Finding" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Custom Extension Structures

Extensions with complex value types use structured objects rather than simple scalars. The structures below define the shape of each custom extension's `value` field.

### Submitted SCV Xrefs

The `submittedScvXrefs` extension contains an array of cross-reference objects as originally submitted by the submitter. These are preserved without normalization to maintain a record of what the submitter provided.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Field (type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>code</code><br>string</td>
      <td>The cross-reference identifier as submitted (e.g., <code>C0677776</code>, <code>604370</code>, <code>MONDO:0011450</code>).</td>
    </tr>
    <tr>
      <td><code>system</code><br>string</td>
      <td>The database name as submitted. Common values include <code>MedGen</code>, <code>OMIM</code>, <code>MONDO</code>, <code>HP</code>, <code>HPO</code>, <code>MeSH</code>, <code>MESH</code>, <code>Orphanet</code>, <code>UMLS</code>, <code>GeneReviews</code>, and <code>OMIM phenotypic series</code>.</td>
    </tr>
  </tbody>
</table>

#### Example

```json
[
  { "code": "C0677776", "system": "MedGen" },
  { "code": "604370", "system": "OMIM" }
]
```
