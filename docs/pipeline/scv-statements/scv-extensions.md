# SCV Statement Extensions

## Overview

SCV statement records contain `extensions` arrays at three structural levels — on the top-level `Statement`, on the `classification` object, and on proposition qualifier objects (`geneContextQualifier`, `modeOfInheritanceQualifier`, `penetranceQualifier`). Extensions carry ClinVar-specific metadata, submitter-provided values, and formatted descriptions that are not part of the GA4GH VA-Spec statement model but are essential for tracing how each SCV was processed.

All extensions follow the structure `{ "name": "<extension_name>", "value_string": "<value>" }` for statement-level and qualifier-level extensions, and `{ "name": "<extension_name>", "value_string": "<value>" }` for classification extensions. Note that SCV extensions use `value_string` (not `value`) to match the VA-Spec extension convention for string-typed values.

---

## Statement Extensions

Extensions on the top-level `Statement` record, built in Step 7 of the [SCV Statement procedure](index.md).

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>clinvarScvId</code><br><em>Statement</em><br>string</td>
      <td>The ClinVar SCV accession without version (e.g., <code>SCV001571657</code>). Always present.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarScvId", "value_string": "SCV001571657" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarScvVersion</code><br><em>Statement</em><br>string</td>
      <td>The version number of the SCV submission (e.g., <code>2</code>). Always present.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarScvVersion", "value_string": "2" }</code></pre></td>
    </tr>
    <tr>
      <td><code>clinvarScvReviewStatus</code><br><em>Statement</em><br>string</td>
      <td>The ClinVar review status of this submission (e.g., <code>criteria provided, single submitter</code>, <code>no assertion criteria provided</code>). Present when the SCV has a review status.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarScvReviewStatus", "value_string": "no assertion criteria provided" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedScvClassification</code><br><em>Statement</em><br>string</td>
      <td>The original classification text submitted by the submitter, preserved when it differs from the normalized classification name. Present only when the submitted classification differs from the mapped value.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedScvClassification", "value_string": "Pathogenic/Likely pathogenic" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedScvLocalKey</code><br><em>Statement</em><br>string</td>
      <td>The unique local key provided by the submitter for this submission. Often contains variant and condition identifiers. Present only when the submitter provided a local key.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedScvLocalKey", "value_string": "NM_004985.5:c.35G>A|Acute myeloid leukemia" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submissionLevel</code><br><em>Statement</em><br>string</td>
      <td>The submission level code derived from the SCV's review status rank. Values: <code>PG</code> (practice guideline), <code>EP</code> (expert panel), <code>CP</code> (criteria provided), <code>NOCP</code> (no assertion criteria provided), <code>NOCL</code> (no classification provided), <code>FLAG</code> (flagged). Present when the submission level can be determined.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submissionLevel", "value_string": "CP" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Classification Extensions

Extensions on the `classification` object within the Statement, providing a formatted summary of the classification context.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>description</code><br><em>classification</em><br>string</td>
      <td>A formatted multi-line description summarizing the classification context. Template:<br><code>for &lt;condition_name&gt;\nClassification is based on the &lt;submission_level_label&gt; submission\n&lt;evaluated_date&gt; by &lt;submitter_name&gt;</code><br>Where <code>condition_name</code> is the condition name (or "<em>N</em> conditions" for multi-condition sets), <code>submission_level_label</code> is the full label (e.g., "criteria provided"), <code>evaluated_date</code> is formatted as <code>Mon YYYY</code> or <code>(-)</code>, and <code>submitter_name</code> is the submitting organization. Always present.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "description", "value_string": "for Acute myeloid leukemia\nClassification is based on the no assertion criteria provided submission\nMar 2018 by Hematopathology, MDACC" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Qualifier Extensions

Extensions on proposition qualifier objects, preserving the original submitter-provided values.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>submittedGeneSymbols</code><br><em>geneContextQualifier</em><br>array&lt;string&gt;</td>
      <td>The gene symbols originally submitted by the submitter for this assertion, extracted from the clinical assertion variation XML. Present when the submitter provided gene information. May differ from the normalized gene symbol if the submitted genes were not matched to a single-gene variation.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedGeneSymbols", "value_string": ["KRAS"] }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedModeOfInheritance</code><br><em>modeOfInheritanceQualifier</em><br>string</td>
      <td>The mode of inheritance text as originally submitted by the submitter. Present on all MOI qualifiers. Preserved alongside the normalized HPO coding.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedModeOfInheritance", "value_string": "Autosomal dominant inheritance" }</code></pre></td>
    </tr>
    <tr>
      <td><code>submittedClassification</code><br><em>penetranceQualifier</em><br>string</td>
      <td>The original submitted classification text that triggered the penetrance qualifier derivation. Present on all penetrance qualifiers. Used to trace why a <code>low</code> or <code>risk</code> penetrance value was assigned (e.g., "Pathogenic, low penetrance" → penetrance: low).</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "submittedClassification", "value_string": "Pathogenic, low penetrance" }</code></pre></td>
    </tr>
  </tbody>
</table>
