# Evidence Lines

Evidence lines in ClinVar-GKS appear only on somatic clinical impact (SCI) statements. They link the parent `VariantClinicalSignificanceProposition` to a specific clinical assertion type — therapeutic response, diagnostic, or prognostic.

The [ClinvarSomaticEvidenceLine](ClinvarSomaticEvidenceLine.md) profiles the VA-Spec `EvidenceLine` with additional properties for the target proposition and evidence outcome.

---

## When Evidence Lines Appear

| Statement Category | Has Evidence Lines? |
| --- | --- |
| Germline classification (PATH, RF, PROT, etc.) | No |
| Oncogenicity (ONCO) | No |
| Somatic clinical impact (SCI) — Tier I or II | Yes |
| Somatic clinical impact (SCI) — Tier III or IV | No (no clinical assertion type) |

Evidence lines are present only on Tier I and Tier II SCI statements, where ClinVar requires at least one clinical assertion type (therapeutic response, diagnostic, or prognostic) to support the tier classification.

---

## Target Propositions

Each evidence line carries a `proposition` specifying the clinical assertion type. These are GA4GH VA-Spec standard types:

| Code | Type | Predicates | Description |
| --- | --- | --- | --- |
| `TR` | VariantTherapeuticResponseProposition | `predictsSensitivityTo`, `predictsResistanceTo` | Response to a specific therapy |
| `DIAG` | VariantDiagnosticProposition | `isDiagnosticInclusionCriterionFor`, `isDiagnosticExclusionCriterionFor` | Diagnostic relevance |
| `PROG` | VariantPrognosticProposition | `associatedWithBetterOutcomeFor`, `associatedWithWorseOutcomeFor` | Prognostic significance |

---

## Evidence Outcome

The `evidenceOutcome` field maps the AMP/ASCO/CAP tier to an evidence level:

| Tier | Evidence Outcome |
| --- | --- |
| Tier I - Strong | `Level A/B` |
| Tier II - Potential | `Level C/D` |

---

## Relationship to Parent Statement

An SCI statement's structure connects the tiers to the clinical assertions:

```
SCV Statement
├── proposition: VariantClinicalSignificanceProposition (isClinicallySignificantFor)
├── classification: "Tier I - Strong"
└── hasEvidenceLines:
    └── ClinvarSomaticEvidenceLine
        ├── proposition: VariantTherapeuticResponseProposition (predictsSensitivityTo)
        ├── evidenceOutcome: "Level A/B"
        └── directionOfEvidenceProvided: "supports"
```

The parent statement asserts clinical significance (the tier), while the evidence line specifies *what kind* of clinical significance — which therapy, diagnostic criterion, or prognostic outcome the variant is relevant for.

---

## Extensions

Somatic evidence lines also carry `submittedCondition` or `submittedConditionSet` extensions providing the submitter's original condition details. See [SubmittedConditionMapping](SubmittedConditionMapping.md) for the mapping structure.
