# VCV Statement Extensions

## Overview

VCV aggregate statement records contain `extensions` arrays at two structural levels — on the top-level `Statement` and on classification objects (`classification_mappableConcept` and `classification_conceptSet` / `classification_conceptSetSet`). Extensions carry aggregate review status information and classification context that are not part of the GA4GH VA-Spec statement model but are essential for interpreting the aggregation outcome.

VCV statement extensions use `value` (not `value_string`) for extension values, following the convention for aggregate-level metadata.

---

## Statement Extensions

Extensions on the top-level VCV `Statement` record, built in the [VCV Statement procedure](vcv-proc.md).

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>clinvarReviewStatus</code><br><em>Statement</em><br>string</td>
      <td>The aggregate review status derived from the submission level and aggregation outcome. This reflects the overall confidence level for the aggregate classification. See <a href="vcv-aggregation-rules.md#aggregate-review-status">Aggregate Review Status</a> for the complete value table.<br><br>
      Values include:
      <ul>
        <li><code>practice guideline</code> — PGEP with PG-only SCVs</li>
        <li><code>reviewed by expert panel</code> — PGEP with EP-only SCVs</li>
        <li><code>practice guideline and expert panel mix</code> — PGEP with both PG and EP SCVs</li>
        <li><code>criteria provided, single submitter</code> — CP with one submitter</li>
        <li><code>criteria provided, multiple submitters, no conflicts</code> — CP concordant</li>
        <li><code>criteria provided, conflicting classifications</code> — CP conflicting</li>
        <li><code>no assertion criteria provided</code> — NOCP</li>
        <li><code>no classification provided</code> — NOCL</li>
        <li><code>flagged submission</code> — FLAG</li>
      </ul>
      Always present when the aggregate review status can be determined.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarReviewStatus", "value": "criteria provided, multiple submitters, no conflicts" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Classification Extensions

### classification_mappableConcept Extensions

Extensions on the `classification_mappableConcept` object, used for non-PGEP submission levels (CP, NOCP, NOCL, FLAG).

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>conflictingExplanation</code><br><em>classification_mappableConcept</em><br>string</td>
      <td>A formatted breakdown of the conflicting classification counts when multiple distinct significance values exist for a conflict-detectable proposition type. Format: <code>Pathogenic(3); Likely pathogenic(2)</code>. Present only when the classification is conflicting (i.e., when the classification name starts with "Conflicting classifications of").</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)" }</code></pre></td>
    </tr>
  </tbody>
</table>

### classification_conceptSet Extensions

Extensions on the `classification_conceptSet` object, used for PGEP submissions with a single classification tuple.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>description</code><br><em>classification_conceptSet</em><br>string</td>
      <td>A formatted multi-line description for the PGEP classification, using the same template as the SCV classification description. Derived from the contributing SCV's classification description extension. Template:<br><code>for &lt;condition_name&gt;\nClassification is based on the &lt;submission_level_label&gt; submission\n&lt;evaluated_date&gt; by &lt;submitter_name&gt;</code><br>Always present on PGEP classification ConceptSets.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "description", "value": "for Breast cancer\nClassification is based on the expert panel submission\nMar 2024 by GeneDx" }</code></pre></td>
    </tr>
  </tbody>
</table>

### classification_conceptSetSet Extensions

For `classification_conceptSetSet` (PGEP with 2+ classification tuples), each inner ConceptSet AND-group carries the same `description` extension as described above. The outer ConceptSet wrapper has no extensions.

---

## Proposition Qualifier Extensions

VCV proposition `aggregateQualifiers` are not technically extensions — they are structured qualifier arrays — but they carry metadata about the aggregation context. Documented here for completeness.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Qualifier (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>AssertionGroup</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The statement group for this aggregation: <code>Germline</code> or <code>Somatic</code>. Always present at all layers.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "AssertionGroup", "value": "Germline" }</code></pre></td>
    </tr>
    <tr>
      <td><code>PropositionType</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The proposition type label for this aggregation (e.g., <code>Pathogenicity</code>, <code>Oncogenicity</code>, <code>Somatic Clinical Impact</code>). Present at Layers 1–3.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "PropositionType", "value": "Pathogenicity" }</code></pre></td>
    </tr>
    <tr>
      <td><code>SubmissionLevel</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The submission level label for this aggregation. For PGEP, uses the derived label (<code>practice guideline</code>, <code>expert panel</code>, or <code>practice guideline and expert panel mix</code>). For others, uses the standard label from the submission level lookup table. Present at Layers 1–2.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "SubmissionLevel", "value": "criteria provided" }</code></pre></td>
    </tr>
    <tr>
      <td><code>ClassificationTier</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The somatic classification tier (e.g., <code>Tier I (Strong)</code>, <code>Tier II (Potential)</code>). Present only at Layer 1 for somatic clinical impact propositions with tier grouping.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "ClassificationTier", "value": "Tier I (Strong)" }</code></pre></td>
    </tr>
  </tbody>
</table>
