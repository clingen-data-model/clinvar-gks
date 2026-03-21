# Statement Types

ClinVar-GKS groups ClinVar submissions into 14 unique statement types. Several of these types are no longer accepted by ClinVar but exist historically.

| # | Statement Type | Proposition Profile | Statement Category |
| --- | --- | --- | --- |
| G.01 | Pathogenicity | Variant Pathogenicity | Germline Classification |
| G.02 | Drug Response | ClinVar Drug Response\* | Germline Classification |
| G.03 | Risk Factor | ClinVar Risk Factor\* | Germline Classification |
| G.04 | Protective | ClinVar Protective\* | Germline Classification |
| G.05 | Affects | ClinVar Affects\* | Germline Classification |
| G.06 | Association | ClinVar Association\* | Germline Classification |
| G.07 | Confers Sensitivity | ClinVar Confers Sensitivity\* | Germline Classification |
| G.08 | Other | ClinVar Other\* | Germline Classification |
| G.09 | Not Provided | ClinVar Not Provided\* | Germline Classification |
| O.10 | Oncogenicity | Variant Oncogenicity | Oncogenic Classification |
| S.11 | Clinical Significance | Clinical Significance | Somatic Clinical Impact |
| S.12 | Therapeutic Response | Therapeutic Response | Somatic Clinical Impact |
| S.13 | Diagnostic | Diagnostic | Somatic Clinical Impact |
| S.14 | Prognostic | Prognostic | Somatic Clinical Impact |

## Statement Categories (VCV Groups)

ClinVar aggregates these 14 statement types into one of 3 VCV-level categories:

- **Germline Classification** — groups 9 statement types (G.01 through G.09)
- **Oncogenic Classification** — groups 1 statement type (O.10)
- **Somatic Clinical Impact** — groups 4 statement types (S.11 through S.14)

## About Non-Standard Statements

The non-standard statements (marked with \*) are defined only in the ClinVar-GKS datasets. These are needed to handle non-standard data in ClinVar. The ClinVar-GKS dataset is a complete representation of ClinVar's XML VCV and RCV releases and must have a way to represent all of the data in ClinVar. ClinVar-GKS does NOT attempt to guess at or map submissions like `Risk Factor` to the `Pathogenicity` Risk Allele classifications since the Risk Factor classification was provided years ahead of the recent ability to classify Variant Pathogenicity submissions with `established`, `likely` or `uncertain` `risk allele`.

Additionally, some of these non-standard statements are no longer accepted as submissions to ClinVar. ClinVar has stopped accepting `Risk Factor` in favor of the newer Pathogenicity classification terms, as well as `other`, `confers sensitivity`, `affects` and `association`.

`Not Provided` statements represent submissions where the submitter provided NO classification. While this may seem counter-intuitive, ClinVar allows this under certain circumstances. Historically, ClinVar needed to allow this for `Functional Impact` submissions where the submitter was not explicitly classifying the variant.

## About Clinical Significance & Somatic Clinical Impact

The `Clinical Significance` statement is the top-level submission for all `Somatic Clinical Impact` **Tier I, II, III & IV** submissions. These submissions are different from `Pathogenicity` or `Oncogenicity` submissions in that they have a sub-statement tightly coupled with the **Tier I & II** classified submissions.

All **Tier I & II** submissions MUST have one of either `Therapeutic Response`, `Diagnostic` or `Prognostic` related submission data associated with them. This is defined in the AMP/ASCO guidelines. However, **Tier III & IV** do NOT have a combined sub-statement as they represent the *Uncertain* and *Benign/Likely benign* Somatic Clinical Impact submissions.

All `Somatic Clinical Impact` submissions will have a `Clinical Significance` statement at the top-level. Those that are **Tier I & II** will have the sub-statement associated through an `Evidence Line`.
