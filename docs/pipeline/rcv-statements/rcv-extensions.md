# RCV Statement Extensions

## Overview

RCV aggregate statement records contain `extensions` arrays at two structural levels -- on the top-level `Statement` and on the `classification` object. Extensions carry aggregate review status information and classification context that are not part of the GA4GH VA-Spec statement model but are essential for interpreting the aggregation outcome.

RCV statement extensions use `value` (not `value_string`) for extension values, following the convention for aggregate-level metadata.

A key structural difference from VCV: RCV propositions use a single `objectConditionClassification` field, a `ConceptSet` with exactly two concepts -- the SCV's condition (or conditionSet) and the aggregate classification -- joined with an AND operator. PG and EP are independent submission levels.

---

## Statement Extensions

Extensions on the top-level RCV `Statement` record, built in the [RCV Statement procedure](rcv-proc.md).

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
      <td>The aggregate review status derived from the submission level and aggregation outcome. This reflects the overall confidence level for the aggregate classification. The same value set as VCV review status applies.<br><br>
      Values include:
      <ul>
        <li><code>practice guideline</code> -- PG</li>
        <li><code>reviewed by expert panel</code> -- EP</li>
        <li><code>criteria provided, single submitter</code> -- CP with one submitter</li>
        <li><code>criteria provided, multiple submitters, no conflicts</code> -- CP concordant</li>
        <li><code>criteria provided, conflicting classifications</code> -- CP conflicting</li>
        <li><code>no assertion criteria provided</code> -- NOCP</li>
        <li><code>no classification provided</code> -- NOCL</li>
        <li><code>flagged submission</code> -- FLAG</li>
      </ul>
      Always present when the aggregate review status can be determined.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "clinvarReviewStatus", "value": "criteria provided, conflicting classifications" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Classification Extensions

### classification Extensions

Extensions on the `classification` object. RCV uses `classification` at every layer for every submission level.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>conflictingExplanation</code><br><em>classification</em><br>string</td>
      <td>A formatted breakdown of the conflicting classification counts when multiple distinct significance values exist for a conflict-detectable proposition type. Format: <code>Pathogenic(3); Likely pathogenic(2)</code>. Present only when the classification is conflicting (i.e., when the classification name starts with "Conflicting classifications of").</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "conflictingExplanation", "value": "Pathogenic(3); Likely pathogenic(2)" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## objectConditionClassification

The `objectConditionClassification` field on RCV propositions is not an extension -- it is a core proposition field of type `ConceptSet`. It always contains exactly two concepts joined with an AND operator: the SCV's actual condition (sourced from `gks_scv_condition_sets`) and the aggregate classification.

```json
{
  "objectConditionClassification": {
    "type": "ConceptSet",
    "concepts": [
      {
        "conceptType": "Disease",
        "id": "12345",
        "name": "Hereditary breast and ovarian cancer syndrome",
        "primaryCoding": {"code": "C0677776", "system": "MedGen"}
      },
      {
        "conceptType": "Classification",
        "name": "Conflicting classifications of pathogenicity"
      }
    ],
    "membershipOperator": "AND"
  }
}
```

When the underlying SCV uses a multi-condition `conditionSet` instead of a single `condition`, the first concept is itself a nested ConceptSet of conditions. Extensions on the source condition are excluded.

This same structure is used at all four layers without modification -- no per-SCV expansion or recombination is performed.

---

## Proposition Qualifier Extensions

RCV proposition `aggregateQualifiers` are not technically extensions -- they are structured qualifier arrays -- but they carry metadata about the aggregation context. Documented here for completeness. The qualifier set is identical to VCV.

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
      <td>The proposition type label for this aggregation (e.g., <code>Pathogenicity</code>, <code>Oncogenicity</code>, <code>Somatic Clinical Impact</code>). Present at Layers 1--3.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "PropositionType", "value": "Somatic Clinical Impact" }</code></pre></td>
    </tr>
    <tr>
      <td><code>SubmissionLevel</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The submission level label for this aggregation, taken from the standard label in the submission level lookup table. Present at Layers 1--2.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "SubmissionLevel", "value": "criteria provided" }</code></pre></td>
    </tr>
    <tr>
      <td><code>ClassificationTier</code><br><em>aggregateQualifiers</em><br>string</td>
      <td>The somatic classification tier (e.g., <code>Tier I - Strong</code>, <code>Tier II - Potential</code>). Present only at Layer 1 for somatic clinical impact propositions with tier grouping.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "ClassificationTier", "value": "Tier I - Strong" }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## SCI Label Format

For somatic clinical impact (SCI) propositions, the RCV aggregate classification label format differs from VCV. The RCV SCI label format is:

```text
<tier_label> - <assertion_type> - <clinical_significance> (<scv_count>)
```

For example: `Tier I - Strong - diagnostic - supports diagnosis (1)`

The condition/tumor name is not included in the label because it is already represented in the `objectConditionClassification` ConceptSet.
