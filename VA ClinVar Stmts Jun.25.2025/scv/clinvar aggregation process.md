# Rules for aggregating SCVs into VCVs

## Overview
This document describes the systematic process for aggregating individual Submitted Clinical Variants (SCVs) into Variant Classification Variants (VCVs) using ClinVar's hierarchical aggregation methodology. The process transforms detailed individual submissions into consolidated statements that represent community consensus while maintaining data quality and traceability.

## SCV Statement Structure

### Required Attributes
Every SCV statement contains these essential fields:
- **Variant**: The genetic variant being classified
- **Category**: Broad clinical context (GC, SCI, OC)
- **Type**: Specific statement type within the category
- **Submitter**: Organization providing the classification
- **Review Status**: Quality assessment level
- **Condition**: Associated medical condition (referred to as "Tumor Type" for DIAG, PROG, TR, and VO statement types)
- **Classification**: Specific clinical assessment

### Statement Categories and Types

#### Categories
- **GC (Germline Classification)**: Inherited genetic conditions and traits
- **SCI (Somatic Clinical Impact)**: Cancer treatment and diagnostic relevance
- **OC (Oncogenicity Classification)**: Cancer-causing potential of variants

#### Statement Types by Category

**Germline Classification (GC) Types:**
- VP (Variant Pathogenicity) - Disease-causing assessment
- DR (Drug Response) - Medication response impact
- RF (Risk Factor) - Disease risk modification
- ASSOC (Association) - Statistical association with traits
- ASSOCNF (Association Not Found) - No statistical association
- PROTECT (Protective) - Protective against disease
- NP (Not Provided) - No classification given
- CS (Confers Sensitivity) - Increases disease susceptibility
- AFF (Affects) - General impact on traits

**Oncogenicity Classification (OC) Types:**
- VO (Variant Oncogenicity) - Cancer-causing assessment *(uses Tumor Type for condition)*

**Somatic Clinical Impact (SCI) Types:**
- DIAG (Diagnostic) - Diagnostic utility for cancer *(uses Tumor Type for condition)*
- PROG (Prognostic) - Disease outcome prediction *(uses Tumor Type for condition)*
- TR (Therapeutic Response) - Treatment response prediction *(uses Tumor Type for condition)*

### Classification Precedence by Statement Type

Classifications within each statement type have ordinal values that determine precedence during aggregation. Higher ordinal values take priority over lower values.

#### VP (Variant Pathogenicity) Precedence
| Classification | Description | Ordinal Value |
|----------------|-------------|---------------|
| P | Pathogenic | 11 |
| PLP | Pathogenic, Low Penetrance | 10 |
| ERA | Established Risk Allele | 9 |
| P/LP | Pathogenic/Likely Pathogenic | 8 |
| LP | Likely Pathogenic | 7 |
| LPLP | Likely Pathogenic, Low Penetrance | 6 |
| LRA | Likely Risk Allele | 5 |
| VUS | Uncertain Significance | 4 |
| URA | Uncertain Risk Allele | 3 |
| B | Benign | 2 |
| LB | Likely Benign | 1 |
| B/LB | Benign/Likely Benign | 0 |
| CDFS | Conflicting Data from Submitters | -1 |

#### VO (Variant Oncogenicity) Precedence
| Classification | Description | Ordinal Value |
|----------------|-------------|---------------|
| O | Oncogenic | 6 |
| LO | Likely Oncogenic | 5 |
| O/LO | Oncogenic/Likely Oncogenic | 4 |
| VUS | Uncertain Significance | 3 |
| B | Benign | 2 |
| LB | Likely Benign | 1 |
| B/LB | Benign/Likely Benign | 0 |

#### SCI Types (DIAG, PROG, TR) Precedence
| Classification | Description | Ordinal Value |
|----------------|-------------|---------------|
| T1 | Tier I - Strong | 3 |
| T2 | Tier II - Potential | 2 |
| T3 | Tier III - Uncertain significance | 1 |
| T4 | Tier IV - Benign/likely benign | 0 |

#### All Other Statement Types
Statement types not listed above have a single classification equal to the statement type name, with ordinal value 0:
- NP, AFF, DR, RF, PROTECT, CS, ASSOC, ASSOCNF (all ordinal value 0)

### Review Status Hierarchies

#### SCV Review Status Hierarchy (Input Statements)

Individual SCV review statuses indicate the quality and reliability of each submission:

| Review Status | Rating | Ordinal Value | Description |
|---------------|---------|---------------|-------------|
| Practice Guideline | 4 stars | 4 | Official clinical guidelines |
| Reviewed by Expert Panel | 3 stars | 3 | Professional expert consensus |
| Criteria Provided, Single Submitter | 1 star | 1 | Individual laboratory assessment |
| No Assertion Criteria Provided | 0 stars | 0 | Minimal supporting evidence |
| No Classification Provided | No Classification | -1 | No assessment given |
| Flagged Submission | Flagged Records | -2 | Problematic or invalid data |

#### Aggregate Statement Review Status Hierarchy (Output Statements)

Aggregate statements (Level 1 and Level 2) can have additional review statuses that result from the aggregation process:

| Review Status | Rating | Ordinal Value | Description |
|---------------|---------|---------------|-------------|
| Practice Guideline | 4 stars | 4 | Highest authority guidelines |
| Reviewed by Expert Panel | 3 stars | 3 | Expert consensus review |
| Criteria Provided, Multiple Submitters, No Conflicts | 2 stars | 2 | Multi-submitter consensus |
| Criteria Provided, Multiple Submitters | 2 stars | 2 | Multi-submitter evidence |
| Criteria Provided, Single Submitter | 1 star | 1 | Individual assessment |
| Criteria Provided, Conflicting Classifications | 1 star | 1 | Detected disagreement |
| No Assertion Criteria Provided | 0 stars | 0 | Minimal evidence |
| No Classification Provided | No Classification | -1 | No assessment |
| No Classifications from Unflagged Records | Flagged Records | -2 | Only problematic data available |

## Step 1 - Determining SCV "Significance"

### Overview
Before aggregating SCVs, each statement's classification must be translated into a standardized "significance" value. This significance mapping enables conflict detection for VP (Variant Pathogenicity) and VO (Variant Oncogenicity) statement types, which are the only types in ClinVar that support concordance/discordance analysis.

### Purpose
- **VP and VO statements**: Significance values determine if statements agree or conflict with each other
- **All other statement types**: Classifications are used directly for grouping and precedence without conflict analysis

### Significance Mapping Rules

#### VP (Variant Pathogenicity) Classifications

**Significance = "Yes"** *(Pathogenic/Harmful)*
- P (Pathogenic)
- LP (Likely Pathogenic) 
- ERA (Established Risk Allele)
- LRA (Likely Risk Allele)
- PLP (Pathogenic, Low Penetrance)
- LPLP (Likely Pathogenic, Low Penetrance)

**Significance = "Uncertain"** *(Unknown clinical impact)*
- VUS (Uncertain Significance)
- URA (Uncertain Risk Allele)

**Significance = "No"** *(Benign/Harmless)*
- B (Benign)
- LB (Likely Benign)

**Significance = "Conflict"** *(Special case)*
- CDFS (Conflicting data from submitters) *Note: Special ISCA submission requirement*

#### VO (Variant Oncogenicity) Classifications

**Significance = "Yes"** *(Oncogenic/Cancer-causing)*
- O (Oncogenic)
- LO (Likely Oncogenic)

**Significance = "Uncertain"** *(Unknown oncogenic impact)*
- VUS (Uncertain Significance)

**Significance = "No"** *(Non-oncogenic)*
- B (Benign)
- LB (Likely Benign)

#### All Other Statement Types (TR, DIAG, PROG, DR, RF, etc.)

**No significance mapping applied** - Classifications are used directly in aggregation without conflict detection analysis. These statement types rely on classification ordinal values for precedence determination rather than significance-based conflict detection.

### Process Result
Each SCV receives an assigned significance value (when applicable), enabling the Level 1 aggregation process to detect concordance or discordance among comparable statements for the same variant and statement type.

## Step 2 - Generating VariantTypeStatusAggregate Statements (aka Level 1 Aggregation)

### Overview
Level 1 aggregation combines individual SCVs into intermediate statements by grouping them based on variant, statement type, and review status. The aggregation process detects concordance (agreement) or discordance (disagreement) among SCVs to create VariantTypeStatusAggregate statements.

### Process

#### Step 1: Group SCVs for Aggregation
Collect SCVs that share the same:
- Variant
- Statement type
- Review status

**Deduplication rule**: Use only distinct combinations of variant, type, review status, significance, and submitter to prevent a single submitter from being counted multiple times for the same assessment.

#### Step 2: Apply Statement Type-Specific Rules

**For VP and VO Statement Types (Pathogenicity/Oncogenicity)**

These statement types support concordance/discordance analysis based on significance values:

**When Discordance Detected** *(different significance values exist)*
- Final classification: "Conflicting classifications of pathogenicity" (VP) or "Conflicting classifications of oncogenicity" (VO)
- Final review status: 
  - "Criteria provided, conflicting classifications" if input SCVs had "criteria provided, single submitter"
  - "No assertion criteria provided" if input SCVs had "no assertion criteria provided"
- Contributing SCVs: All SCVs in the group
- Final conditions: Unique list from all contributing SCVs (conditions/tumor types)

**When Concordance Detected** *(same significance value)*
- **Single SCV**: 
  - Final classification: Match the single SCV classification
  - Final review status: Match the single SCV review status
  - Contributing SCVs: The single SCV
  - Final conditions: From the single SCV (condition/tumor type)
  
- **Multiple SCVs with same significance**:
  - Final classification: Concatenate unique classification terms from all SCVs
  - Final review status:
    - "Criteria provided, multiple submitters, no conflicts" if input SCVs had "criteria provided, single submitter"
    - "No assertion criteria provided" if input SCVs had "no assertion criteria provided"
  - Contributing SCVs: All SCVs in the group
  - Final conditions: Unique list from all contributing SCVs (conditions/tumor types)

**For All Other Statement Types (DIAG, PROG, TR, DR, RF, etc.)**

These statement types use classification precedence based on ordinal values:

- Final classification: Highest ordinal value classification among all SCVs in the group
- Final review status:
  - "Criteria provided, multiple submitters" if multiple SCVs match the maximum classification
  - "Criteria provided, single submitter" if only one SCV matches the maximum classification
  - Adjust to "no assertion criteria provided" if input SCVs had "no assertion criteria provided"
- Contributing SCVs: Only those with the maximum classification ordinal value
- Non-contributing SCVs: Those with lower classification ordinal values  
- Final conditions: Unique list from all contributing SCVs (conditions/tumor types)

**Special Rules for GC Statement Types (VP, DR, RF, ASSOC, etc.):**

- **High-Quality Statements (3-star and 4-star only)**: List all unique conditions with their classifications (e.g., "DR for Condition01", "RF for Condition02")
- **Lower Quality Statements (2-star and below)**: Use standard classification display without condition-specific listings
- **Multiple Conditions**: Each unique condition gets its own classification entry for 3-star and 4-star statements only

**Special Rules for SCI Statement Types (DIAG, PROG, TR):**

- **Classification Display**: Show only the top classification from contributing SCVs
- **Tumor Type Display**: 
  - Single tumor type: Show the specific tumor type name
  - Multiple tumor types: Show count (e.g., "3 tumor types")
- **Lower Level Evidence Annotation**: If non-contributing SCVs exist with lower classification ordinal values, add annotation: "+ lower level of evidence for [tumor type]" or "+ lower level of evidence for [X tumor types]"

#### Step 3: Create Level 1 Aggregate Statement
Generate the VariantTypeStatusAggregate statement with:
- Variant, statement type, and final review status as identifiers
- Final classification as determined by the rules above
- List of contributing and non-contributing SCVs
- Unique list of conditions from contributing SCVs (conditions/tumor types)


## Step 3 - Generating VariantCategoryMaxStatusAggregate Statements (aka Level 2 Aggregation / VCV Statements)

### Overview
Level 2 aggregation creates VCV (Variant Classification Variant) statements - the final aggregate statements that represent ClinVar's official position for each variant-category combination. Each variant can have up to 3 VCV statements (one per category: GC, SCI, OC) depending on the available SCV data. The process prioritizes higher-quality evidence by only including Level 1 statements with the best available review status.

### Process

#### Step 1: Group Level 1 Statements
Collect all Level 1 VariantTypeStatusAggregate statements that share the same:
- Variant 
- Statement category (GC, SCI, or OC)

#### Step 2: Determine Maximum Review Status
Find the highest review status (star rating) among all Level 1 statements in the group.

#### Step 3: Select Contributing Statements
Apply these contribution rules:
- **General rule**: Only Level 1 statements with the maximum review status contribute to Level 2
- **Special exception**: When maximum review status is 2 stars, include BOTH 2-star AND 1-star Level 1 statements
- **Non-contributing**: All Level 1 statements below the contribution threshold are excluded

#### Step 4: Create Level 2 Statement (VCV)
Generate the final VCV statement based on the maximum review status found:

**When Maximum = 4 Stars (Practice Guidelines)**
- Final review status: 4 stars "practice guidelines"
- Final classification: List all contributing Level 1 classifications
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)

**When Maximum = 3 Stars (Expert Panel)**
- Final review status: 3 stars "reviewed by expert panel"  
- Final classification: List all contributing Level 1 classifications
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)

**When Maximum = 2 Stars (Multiple Submitters)**
- Final review status: 2 stars "criteria provided, multiple submitters, no conflicts" OR "criteria provided, multiple submitters"
- Final classification: Include Level 1 classifications from both 2-star AND 1-star statements
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)
- Special rule for GC category: Concatenate classifications using semicolons in statement type precedence order

**When Maximum = 1 Star (Single/Conflicting)**
- Final review status: 1 star "criteria provided, single submitter" OR "criteria provided, conflicting classifications"
- Final classification: Include Level 1 classifications with 1 star
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)  
- Special rule for GC category: Concatenate classifications using semicolons in statement type precedence order

**When Maximum = 0 Stars (No Criteria)**
- Final review status: 0 stars "no assertion criteria provided"
- Final classification: Include Level 1 classifications with 0 stars
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)
- Special rule for GC category: Concatenate classifications using semicolons in statement type precedence order

**When Maximum = No Classification (-1)**
- Final review status: No Classification (-1) "no classification provided"
- Final classification: Include Level 1 classifications with No Classification (-1)
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)
- Special rule for GC category: Concatenate classifications using semicolons in statement type precedence order

**When Maximum = Flagged Records (-2)**
- Final review status: Flagged Records (-2) "no classifications from unflagged records"
- Final classification: Include Level 1 classifications with Flagged Records (-2)
- Final conditions: Unique list from all contributing Level 1 statements (conditions/tumor types)
- Special rule for GC category: Concatenate classifications using semicolons in statement type precedence order

**GC Classification Assembly Order**: VP; DR; RF; ASSOC; ASSOCNF; PROTECT; CS; AFF; NP

### Special Rules for Category-Specific Level 2 Statements

**GC Category Classification Display Rules:**
- **High-Quality Statements (3-star and 4-star only)**: List all unique conditions with their classifications from contributing Level 1 statements (e.g., "DR for Condition01; RF for Condition02")
- **Lower Quality Statements (2-star and below)**: Use standard concatenation with semicolons following statement type precedence order
- **Multiple Conditions**: Each unique condition gets its own classification entry for 3-star and 4-star statements only

**SCI Category Classification Display Rules:**
- **Classification**: Show only the top classification from contributing Level 1 statements
- **Tumor Type Display**:
  - Single tumor type: Show the specific tumor type name
  - Multiple tumor types: Show count (e.g., "4 tumor types")
- **Lower Level Evidence Annotation**: If non-contributing Level 1 statements exist with lower review status, add annotation: "+ lower level of evidence for [tumor type]" or "+ lower level of evidence for [X tumor types]"


