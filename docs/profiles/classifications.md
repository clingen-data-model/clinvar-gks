# Classifications

Each statement type has a set list of classification values to which ClinVar normalizes historic or similar classification terms used by some submitters. These classification terms are mapped to the GKS VA statement class' **direction** and **strength**.

## Germline Classification

The Germline Classification category groups 9 statement types.

| # | Statement Type | Classification | Direction | Strength |
| --- | --- | --- | --- | --- |
| G.01 | Pathogenicity | Pathogenic | supports | definitive |
|  |  | Pathogenic, low penetrance | supports | definitive |
|  |  | Risk allele | supports | definitive |
|  |  | Likely pathogenic | supports | likely |
|  |  | Likely pathogenic, low penetrance | supports | likely |
|  |  | Likely risk allele | supports | likely |
|  |  | Pathogenic/Likely pathogenic | supports | \<null\> |
|  |  | Uncertain significance | neutral | \<null\> |
|  |  | Uncertain risk allele | neutral | \<null\> |
|  |  | conflicting data from submitters | neutral | \<null\> |
|  |  | Benign | disputes | definitive |
|  |  | Likely benign | disputes | likely |
|  |  | Benign/Likely benign | disputes | \<null\> |
| G.02 | Drug Response | drug response | supports | \<null\> |
| G.03 | Risk Factor | risk factor | supports | \<null\> |
| G.04 | Protective | protective | supports | \<null\> |
| G.05 | Affects | Affects | supports | \<null\> |
| G.06 | Association | association | supports | \<null\> |
|  |  | association not found | disputes | \<null\> |
| G.07 | Confers Sensitivity | confers sensitivity | supports | \<null\> |
| G.08 | Other | other | supports | \<null\> |
| G.09 | Not Provided | not provided | supports | \<null\> |

## Oncogenicity Classification

The Oncogenicity Classification category groups only 1 statement type.

| # | Statement Type | Classification | Direction | Strength |
| --- | --- | --- | --- | --- |
| O.10 | Oncogenicity | Oncogenic | supports | definitive |
|  |  | Likely oncogenic | supports | likely |
|  |  | Uncertain significance | neutral | \<null\> |
|  |  | Benign | disputes | definitive |
|  |  | Likely benign | disputes | likely |

## Somatic Clinical Impact

The Somatic Clinical Impact category groups 1 primary statement type with up to 3 evidence statement types.

### Clinical Significance (Primary)

| # | Statement Type | Classification | Direction | Strength |
| --- | --- | --- | --- | --- |
| S.11 | Clinical Significance | Tier I - Strong | supports | strong |
|  |  | Tier II - Potential | supports | potential |
|  |  | Tier III - Unknown | neutral | \<null\> |
|  |  | Tier IV - Benign/Likely benign | disputes | \<null\> |

### Evidence Statement Types

All Tier I and II Clinical Significance statements MUST have at least one of the following statement types as evidence. These sub-statement types are critical to Tier I and II clinical significance submissions in ClinVar.

| # | Statement Type | Direction | Strength |
| --- | --- | --- | --- |
| S.12 | Therapeutic Response | supports | strong or potential |
| S.13 | Diagnostic | supports | strong or potential |
| S.14 | Prognostic | supports | strong or potential |
