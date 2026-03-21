# ClinVar GKS Data Set Technical Underpinnings 

This section describes the fundamental aspects of how the clinvar data is organized and transformed into GKS standard statements.

## Submissions / SCVs

These are the baseline statements that are submitted to ClinVar.
ClinVar aggregates submissions with different rules for specific statement types. In the Aggregated Statements section the rules used to aggregate submissions will reference the concepts and attributes defined here, as well as, how they are aggregated to provide a higher order statements such as RCVs and VCVs based on ClinVar's methods.

### Statement Types 

ClinVar GKS groups ClinVar submissions into 14 unique types. Several of these types are no longer accepted but exist historically.

|#|Statement Type|Proposition Profile<br/><i><p style='font-size:small;font-weight:normal'>(* non-standard)</p><i/>|Statement Category|
|----|--------------|--------------------|-------------------------|
|G.01|Pathogenicity|Variant Pathogencity|Germline Classification|
|G.02|Drug Response|Clinvar Drug Response*|Germline Classification|
|G.03|Risk Factor|Clinvar Risk Factor*|Germline Classification|
|G.04|Protective|Clinvar Protective*|Germline Classification|
|G.05|Affects|Clinvar Affects*|Germline Classification|
|G.06|Association|Clinvar Association*|Germline Classification|
|G.07|Confers Sensitivity|Clinvar Confers Sensitivity*|Germline Classification|
|G.08|Other|Clinvar Other*|Germline Classification|
|G.09|Not Provided|Clinvar Not Provided*|Germline Classification|
|O.10|Oncogenicity|Variant Oncogenicity|Oncogenic Classification|
|S.11|Clinical Significance|Clinical Significance|Somatic Clinical Impact|
|S.12|Therapeutic Response|Therapeutic Response|Somatic Clinical Impact|
|S.13|Diagnostic|Diagnostic|Somatic Clinical Impact|
|S.14|Prognostic|Prognostic|Somatic Clinical Impact|

#### About *non-standard statements

The non-standard statements are defined only in the ClinVar GKS datasets. These are needed to handle the non-standard data in ClinVar. The ClinVar GKS dataset is a complete representation of ClinVar's XML VCV and RCV releases and as such must have a way to represent all of the data in ClinVar. ClinVar GKS does NOT attempt to guess at or map submissions like `Risk Factor` to the `Pathogenicity` Risk Allele classifications since the Risk Factor classification was provided years ahead of the recent ability to classify Variant Pathogenicity submissions with `established`, `likely` or `uncertain` `risk allele`.

Additionally, some of these non-standard statements are no longer accepted as submissions to ClinVar. ClinVar has stopped accepting `Risk Factor` in favor of the newer Pathogenicity classification terms, as well as, `other`, `confers sensitivity`, `affects` and `association`.

`Not Provided` statements are interesting in that they represent submissions whereby the submitter provided NO classification. While this may seem counter intuitive ClinVar allows this under certain circumstances. Historically, ClinVar needed to allow this for `Functional Impact` submissions where the submitter was not explicitly classifying the variant. There may be other scenarios that remain.

#### About Clinical Significance & Somatic Clinical Impact types

The `Clinical Significance` statement is the top-level submission for all `Somatic Clinical Impact` **Tier I, II, III & IV** submissions. These `Somatic Clinical Impact` submissions are different than `Pathogenicity` or `Oncogenicity` submissions in that they have a sub-statement that is tightly coupled with the **Tier I & II** classified submissions. All **Tier I & II** submissions MUST have one of either `Therapeutic Response`, `Diagnostic` or `Prognostic` related submission data associated with them. This is defined in the AMP/ASCO guidelines that these submissions represent. However, **Tier III & IV** do NOT have a combined sub-statement as they represent the *Uncertain* and *Benign/Likely benign* Somatic Clinical Impact submissions. All of the `Somatic Clinical Impact` submissions will have a `Clinical Significance` statement at the top-level and those that are **Tier I & II** will have the sub-statement associated through an `Evidence Line` that is the specific sub-statement type.

### Statement Categories (aka VCV Groups)

ClinVar aggregates these 14 statement types into 1 of 3 VCV level categories (or groups) within ClinVar.
These are Germline Classification, Somatic Clinical Impact and (Somatic) Oncogenicity Classification. Each statement type has a set list of classification values to which ClinVar normalizes historic or similar classifications terms used by some submitters. These classification terms are mapped to the GKS VA statement class' direction and strength. Below is the reference listing of statement types with their list of allowed classifications and the direction and strength of each classification value for each of the 3 statement groups. 

#### Germline Classification

The Germline Classification category groups 9 statement types

|#|statement type|classification|direction|strength|
|--|-------------------|------------------------------|---------|----------|
|G.1|Pathogenicity|Pathogenic|supports|definitive|
| | |Pathogenic, low penetrance|supports|definitive|
| | |Risk allele|supports|definitive|
| | |Likely pathogenic|supports|likely|
| | |Likely pathogenic, low penetrance|supports|likely|
| | |Likely risk allele|supports|likely|
| | |Pathogenic/Likely pathogenic|supports|\<null\>|
| | |Uncertain signficance|neutral|\<null\>|
| | |Uncertain risk allele|neutral|\<null\>|
| | |conflicting data from submitters|neutral|\<null\>|
| | |Benign|disputes|definitive|
| | |Likely benign|disputes|likely|
| | |Benign/Likely benign|disputes|\<null\>|
| | | | | |
|G.2|Risk Factor|risk factor|supports|\<null\>|
| | | | | |
|G.3|Protective|protective|supports|\<null\>|
| | | | | |
|G.4|Drug Response|drug response|supports|\<null\>|
| | | | | |
|G.5|Other|other|supports|\<null\>|
| | | | | |
|G.6|Not Provided|not provided|supports|\<null\>|
| | | | | |
|G.7|Affects|Affects|supports|\<null\>|
| | | | | |
|G.8|Association|association|supports|\<null\>|
| | |association not found|disputes|\<null\>|
| | | | | |
|G.9|Confers Sensitivity|confers sensitivity|supports|\<null\>|
| | | | | |

#### Oncogenicity Classification

The Oncogenicity Classification category groups only 1 statement type

|#|statement type|classification|direction|strength|
|-------------------|------------------------------|---------|----------|
|O.1|Oncogenicity|Oncogenic|supports|definitive|
| | |Likely oncogenic|supports|likely|
| | |Uncertain signficance|neutral|\<null\>|
| | |Benign|disputes|definitive|
| | |Likely benign|disputes|likely|
| | | | | |

#### Somatic Clinical Impact

The Somatic Clinical Impact category groups only 1 statement type, but it may additionally have evidence lines for 3 statement types.

|#|statement type|classification|direction|strength|
|--|-------------------|------------------------------|---------|----------|
|S.1|Clinical Significance|Tier I - Strong|supports|strong|
| | |Tier II - Potential|supports|potential|
| | |Tier III - Unknown|neutral|\<null\>|
| | |Tier IV - Benign/Likely benign|disputes|\<null\>|

##### Clinical Significance Evidence Statement Types

All Tier I and II Clinical Significance statements MUST have at least one of the following statement types as evidence to support it. These "sub" statement types are critical to Tier I and II clinical significance submissions in ClinVar.

|#|statement type|classification|direction|strength|
|--|-------------------|------------------------------|---------|----------|
|S.2|Therapeutic Response| |supports|strong|
| | | |supports|potential|
| | | | | |
|S.3|Diagnostic| |supports|strong|
| | | |supports|potential|
| | | | | |
|S.4|Prognostic| |supports|strong|
| | | |supports|potential|
| | | | | |

### Proposition Types

Each Statement Type is mapped to a GKS proposition type. If a proposition type does not exist then one will be created specifically for the clinvar statement type in question.
The final mapping of clinvar statement types to gks proposition types are as follows:
type

|#|statement type|proposition type|
|--|--------------|----------------|
| |Therapeutic Response|VariantTherapeuticResponseProposition|
| |Diagnostic|VariantDiagnosticProposition|
| |Prognostic|VariantPrognosticProposition|
| |Clinical Significance|VariantClinicalSignificanceProposition|
| |Oncogenicity|VariantOncogenicityProposition|
| |Pathogenicity|VariantPathogenicityProposition|

- Risk Factor - ClinVarRiskFactorProposition
- Protective - ClinVarProtectiveProposition
- Drug Response - ClinVarDrugResponseProposition
- Other - ClinVarOtherProposition
- Not Provided - ClinVarNotProvidedProposition
- Affects - ClinVarAffectsProposition
- Association - ClinVarAssociationProposition
- Confers Sensitivity - ClinVarConfersSensitivityProposition

### Review Status (aka star levels)

All submissions contain a review status, which is used to differentiate submissions based on their level of confidence.
These review status confidence levels or star levels are used in ClinVar to group and prioiritize multiple submissions for the same variant and for the same statement type.
The individual submission review status levels and star counts are:

- practice guideline (4 stars)
- reviewed by expert panel (3 stars)
- criteria provided, single submitter (1 star)
- no assertion criteria provided (0 stars)
- no classification provided (0 stars)
- flagged submission (0 stars)

If multiple submissions exist for the same variant and statement type then ClinVar will aggregate these submissions into two different higher order statements or accessions referred to as RCVs and VCVs.
RCVs are the aggregate of multiple submissions for the same statement type, variant and condition.
VCVs are the aggregate of multiple submissions for the same statement type and variant.
RCVs and VCVs also only use the highest ranking review status levels in the aggregated result. These are considered the contributing submissions whereas the others are non-contributing.
However, there are some nuances to the aggregation process that are important to understand.

### Rank Order of Review Status Levels

The rank order of the review status levels is a quanitification of the review status levels that is used to appropriately segregate submissions within a single statement type, variant and condition, when applicable.
Rank order or rank is not a ClinVar concept but it is used during the aggregation process. 
The following shows the rank order of the review status levels:

- ( 4) practice guideline (4 star)
- ( 3) reviewed by expert panel (3 star)
- ( 1) criteria provided, single submitter (1 star)
- ( 0) no assertion criteria provided (0 star)
- (-1) no classification provided (0 star)
- (-3) flagged submission (0 star)