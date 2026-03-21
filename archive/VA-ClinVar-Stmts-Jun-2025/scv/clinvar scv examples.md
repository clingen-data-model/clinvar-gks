# ClinVar VCV Aggregation Examples

This document demonstrates the ClinVar aggregation process through progressive use cases that build upon each other, showing how submissions accumulate over time for a single variant.

## Germline Classification (GC) Scenarios

### Use Case #GC-01: V1 Single Not Provided SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV000020169.9 | Aug 04, 2024 | V1 | GC | NP | OMIM | No Assertion Provided | RECLASSIFIED - HFE POLYMORPHISM | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV000020169.9 (OMIM) |

*Contributing statements: SCV000020169.9 (OMIM)*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | No Classification Provided (-1) | NP | RECLASSIFIED - HFE POLYMORPHISM |

*Contributing Level 1 statements: NP (No Assertion Provided)*  
*Non-contributing Level 1 statements: None*

---

### Use Case #GC-02: V1 Conflicting 0-star VP SCVs & 0-star RF SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001927447.1 | Sep 26, 2021 | V1 | GC | VP | University Medical Center Utrecht | No Assertion Criteria Provided | not provided | VUS |
| SCV000109422.1 | Apr 13, 2021 | V1 | GC | VP | Sinai Health System | No Assertion Criteria Provided | not provided | P |
| SCV001142520.1 | Jan 12, 2020 | V1 | GC | RF | University of Alabama | No Assertion Criteria Provided | Cystic fibrosis | RF |
| SCV000020169.9 | Aug 04, 2024 | V1 | GC | NP | OMIM | No Assertion Provided | RECLASSIFIED - HFE POLYMORPHISM | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV001927447.1 (University Medical Center Utrecht), SCV000109422.1 (Sinai Health System) |
| V1 | RF | No Assertion Criteria Provided (0★) | RF | SCV001142520.1 (University of Alabama) |
| V1 | NP | No Assertion Provided (-1) | NP | SCV000020169.9 (OMIM) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity; RF | not provided; Cystic fibrosis |

*Contributing Level 1 statements: VP (No Assertion Criteria Provided), RF (No Assertion Criteria Provided)*  
*Non-contributing Level 1 statements: NP (No Assertion Provided - lower review status)*

---

### Use Case #GC-03: V1 Conflicting 1-star VP SCVs

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV000206973.2 | Feb 26, 2016 | V1 | GC | VP | Blueprint Genetics | Criteria Provided, Single Submitter | Hereditary hemochromatosis | P |
| SCV001251532.1 | May 31, 2020 | V1 | GC | VP | UNC at Chapel Hill | Criteria Provided, Single Submitter | Hemochromatosis type 1 | P |
| SCV000198337.4 | Oct 25, 2020 | V1 | GC | VP | LMM | Criteria Provided, Single Submitter | Not specified | B |
| SCV001927447.1 | Sep 26, 2021 | V1 | GC | VP | University Medical Center Utrecht | No Assertion Criteria Provided | not provided | VUS |
| SCV000109422.1 | Apr 13, 2021 | V1 | GC | VP | Sinai Health System | No Assertion Criteria Provided | not provided | P |
| SCV001142520.1 | Jan 12, 2020 | V1 | GC | RF | University of Alabama | No Assertion Criteria Provided | Cystic fibrosis | RF |
| SCV000020169.9 | Aug 04, 2024 | V1 | GC | NP | OMIM | No Assertion Provided | RECLASSIFIED - HFE POLYMORPHISM | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | VP | Criteria Provided, Conflicting Classifications (1★) | Conflicting classifications of pathogenicity | SCV000206973.2 (Blueprint Genetics), SCV001251532.1 (UNC at Chapel Hill), SCV000198337.4 (LMM) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000109422.1 (Sinai Health System), SCV001927447.1 (University Medical Center Utrecht) |
| V1 | RF | No Assertion Criteria Provided (0★) | RF | SCV001142520.1 (University of Alabama) |
| V1 | NP | No Assertion Provided (-1) | NP | SCV000020169.9 (OMIM) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Criteria Provided, Conflicting Classifications (1★) | Conflicting classifications of pathogenicity | Not specified, Hemochromatosis type 1, Hereditary hemochromatosis |

*Contributing Level 1 statements: VP (Criteria Provided, Conflicting Classifications)*  
*Non-contributing Level 1 statements: VP (No Assertion Criteria Provided), RF (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

### Use Case #GC-04: V1 Flagged Submission and Concordant 1-star VP SCVs

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV000206973.2 | Feb 26, 2016 | V1 | GC | VP | Blueprint Genetics | Criteria Provided, Single Submitter | Hereditary hemochromatosis | P |
| SCV001251532.1 | May 31, 2020 | V1 | GC | VP | UNC at Chapel Hill | Criteria Provided, Single Submitter | Hemochromatosis type 1 | P |
| SCV001927447.1 | Sep 26, 2021 | V1 | GC | VP | University Medical Center Utrecht | No Assertion Criteria Provided | not provided | VUS |
| SCV000109422.1 | Apr 13, 2021 | V1 | GC | VP | Sinai Health System | No Assertion Criteria Provided | not provided | P |
| SCV001142520.1 | Jan 12, 2020 | V1 | GC | RF | University of Alabama | No Assertion Criteria Provided | Cystic fibrosis | RF |
| SCV000020169.9 | Aug 04, 2024 | V1 | GC | NP | OMIM | No Assertion Provided | RECLASSIFIED - HFE POLYMORPHISM | NP |
| SCV000198337.5 | Oct 25, 2020 | V1 | GC | VP | LMM | Flagged Submission | Not specified | B |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | P | SCV000206973.2 (Blueprint Genetics), SCV001251532.1 (UNC at Chapel Hill) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000109422.1 (Sinai Health System), SCV001927447.1 (University Medical Center Utrecht) |
| V1 | RF | No Assertion Criteria Provided (0★) | RF | SCV001142520.1 (University of Alabama) |
| V1 | NP | No Assertion Provided (-1) | NP | SCV000020169.9 (OMIM) |
| V1 | VP | Flagged Submission (-2) | B | SCV000198337.5 (LMM) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Criteria Provided, Multiple Submitters, No Conflicts (2★) | P | Hemochromatosis type 1, Hereditary hemochromatosis |

*Contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts)*  
*Non-contributing Level 1 statements: VP (No Assertion Criteria Provided), RF (No Assertion Criteria Provided), NP (No Assertion Provided), VP (Flagged Submission)*

---

### Use Case #GC-05: V2 Expert panel NP 3-star SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV000244399.2 | Sep 29, 2015 | V2 | GC | NP | ENIGMA | Reviewed by Expert Panel | Breast-ovarian cancer, familial, susceptibility to, 1 | NP |
| SCV000326291.1 | Sep 29, 2015 | V2 | GC | OTH | CIMBA | Criteria Provided, Single Submitter | Breast-ovarian cancer | OTH |
| SCV004360115.1 | Feb 14, 2024 | V2 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |
| SCV003783588.2 | Dec 02, 2023 | V2 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | VUS |
| SCV000109422.1 | Dec 23, 2013 | V2 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV000145480.2 | Sep 27, 2014 | V2 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV001238617.1 | Apr 18, 2020 | V2 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V2 | NP | Reviewed by Expert Panel (3★) | NP | SCV000244399.2 (ENIGMA) |
| V2 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS | SCV003783588.2 (Labcorp), SCV004360115.1 (Color) |
| V2 | OTH | Criteria Provided, Single Submitter (1★) | OTH | SCV000326291.1 (CIMBA) |
| V2 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V2 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V2 | GC | Reviewed by Expert Panel (3★) | NP | Breast-ovarian cancer, familial, susceptibility to, 1 |

*Contributing Level 1 statements: NP (Reviewed by Expert Panel)*  
*Non-contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts), OTH (Criteria Provided, Single Submitter), VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

### Use Case #GC-06: V2 Expert panel VP 3-star SCV update & DR 3-star SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV002031239.1 | Jul 04, 2025 | V2 | GC | DR | PharmGKB | Reviewed by Expert Panel | methotrexate response - Toxicity | DR |
| SCV000244399.3 | Feb 20, 2025 | V2 | GC | VP | ENIGMA | Reviewed by Expert Panel | Breast-ovarian cancer, familial, susceptibility to, 1 | VUS |
| SCV004360115.1 | Feb 14, 2024 | V2 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |
| SCV003783588.2 | Dec 02, 2023 | V2 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | VUS |
| SCV000109422.1 | Dec 23, 2013 | V2 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV000145480.2 | Sep 27, 2014 | V2 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV001238617.1 | Apr 18, 2020 | V2 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V2 | VP | Reviewed by Expert Panel (3★) | VUS | SCV000244399.3 (ENIGMA) |
| V2 | DR | Reviewed by Expert Panel (3★) | DR | SCV002031239.1 (PharmGKB) |
| V2 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS | SCV003783588.2 (Labcorp), SCV004360115.1 (Color) |
| V2 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V2 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V2 | GC | Reviewed by Expert Panel (3★) | • VUS for Breast-ovarian cancer, familial, susceptibility to, 1<br>• DR for methotrexate response - Toxicity | Breast-ovarian cancer, familial, susceptibility to, 1; methotrexate response - Toxicity |

*Contributing Level 1 statements: VP (Reviewed by Expert Panel), DR (Reviewed by Expert Panel)*  
*Non-contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts), VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

## Key Aggregation Principles Demonstrated

1. **Review Status Hierarchy**: Complete 7-level precedence system (4★ > 3★ > 2★ > 1★ > 0★ > -1 > -2) with expert panel authority taking precedence over all other evidence types

2. **VP/VO Conflict Detection**: Pathogenicity and oncogenicity statements with different significance values (Yes/Uncertain/No) automatically create "Conflicting classifications" regardless of review status

3. **VP/VO Concordance Upgrading**: Multiple pathogenicity/oncogenicity statements with same significance and review status upgrade from "Single Submitter" (1★) to "Multiple Submitters, No Conflicts" (2★)

4. **Non-VP/VO Precedence**: Statement types other than VP/VO (RF, DR, DIAG, PROG, TR, etc.) use classification ordinal values for precedence without conflict detection

5. **Flagged Submission Exclusion**: Submissions with "Flagged Submission" status (-2★) are systematically excluded by higher-quality evidence at Level 2 aggregation

6. **Expert Panel Dominance**: 3★ expert panel statements override all lower-quality evidence, creating single-authority VCVs regardless of the volume of conflicting lower-tier evidence

7. **Cross-Variant Processing**: Aggregation operates independently on different variants (V1 vs V2), demonstrating scalable variant-specific evidence consolidation

8. **GC Category Multi-Type Integration**: Germline classification statements combine different types (VP, DR, RF, OTH, NP) using statement type precedence order when at same review status level

9. **High-Quality Condition-Specific Display**: 3★ and 4★ statements in GC category use condition-specific classification format ("VUS for [condition]; DR for [condition]") instead of simple concatenation

10. **Temporal Evidence Accumulation**: Chronological submission ordering demonstrates how evidence quality improves over time, with later higher-quality submissions taking precedence over earlier lower-quality evidence

## Simplified Flow Summary

```
Individual SCVs → Level 1 Groups → Level 2 VCV
(by variant/type/status)    (by variant/category)

Review Status Hierarchy:
4★ Practice Guidelines
3★ Expert Panel  
2★ Multiple Submitters
1★ Single Submitter
0★ No Criteria
-1 No Classification
-2 Flagged Records
```