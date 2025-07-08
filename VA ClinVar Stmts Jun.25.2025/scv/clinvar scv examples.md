# ClinVar VCV Aggregation Examples

This document demonstrates the ClinVar aggregation process through progressive use cases that build upon each other, showing how submissions accumulate over time for a single variant.

## Germline Classification (GC) Scenarios

### Use Case #GC-01: Single Not Provided SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |

*Contributing statements: SCV001238617.1 (Brotman Baty Inst)*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | No Classification Provided (-1) | NP | Breast-ovarian cancer |

*Contributing Level 1 statements: NP (No Assertion Provided)*  
*Non-contributing Level 1 statements: None*

---

### Use Case #GC-02: Conflicting 0-star VP SCVs

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |
| SCV000145480.1 | Apr 01, 2014 | V1 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV000109422.1 | Dec 23, 2013 | V1 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.1 (BIC), SCV000109422.1 (SCRP) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | Breast-ovarian cancer |

*Contributing Level 1 statements: VP (No Assertion Criteria Provided)*  
*Non-contributing Level 1 statements: NP (No Assertion Provided - lower review status)*

---

### Use Case #GC-03: Conflicting 1-star VP SCVs

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |
| SCV000145480.2 | Sep 27, 2014 | V1 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV000109422.1 | Dec 23, 2013 | V1 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV003783588.1 | Feb 13, 2023 | V1 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | P |
| SCV004360115.1 | Feb 14, 2024 | V1 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V1 | VP | Criteria Provided, Conflicting Classifications (1★) | Conflicting classifications of pathogenicity | SCV003783588.1 (Labcorp), SCV004360115.1 (Color) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Criteria Provided, Conflicting Classifications (1★) | Conflicting classifications of pathogenicity | Hereditary breast ovarian cancer syndrome, Hereditary cancer-predisposing syndrome |

*Contributing Level 1 statements: VP (Criteria Provided, Conflicting Classifications)*  
*Non-contributing Level 1 statements: VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

### Use Case #GC-04: Concordant 1-star VP SCVs with OTH 1-star SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |
| SCV000145480.2 | Sep 27, 2014 | V1 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV000109422.1 | Dec 23, 2013 | V1 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV003783588.2 | Dec 02, 2023 | V1 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | VUS |
| SCV004360115.1 | Feb 14, 2024 | V1 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |
| SCV000326291.1 | Sep 29, 2015 | V1 | GC | OTH | CIMBA | Criteria Provided, Single Submitter | Breast-ovarian cancer | OTH |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V1 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS | SCV003783588.2 (Labcorp), SCV004360115.1 (Color) |
| V1 | OTH | Criteria Provided, Single Submitter (1★) | OTH | SCV000326291.1 (CIMBA) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS; OTH | Hereditary breast ovarian cancer syndrome, Hereditary cancer-predisposing syndrome, Breast-ovarian cancer |

*Contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts), OTH (Criteria Provided, Single Submitter) - using 2★ exception rule*  
*Non-contributing Level 1 statements: VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

### Use Case #GC-05: Expert panel NP 3-star SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |
| SCV000145480.2 | Sep 27, 2014 | V1 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV000109422.1 | Dec 23, 2013 | V1 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV003783588.2 | Dec 02, 2023 | V1 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | VUS |
| SCV004360115.1 | Feb 14, 2024 | V1 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |
| SCV000326291.1 | Sep 29, 2015 | V1 | GC | OTH | CIMBA | Criteria Provided, Single Submitter | Breast-ovarian cancer | OTH |
| SCV000244399.2 | Sep 29, 2015 | V1 | GC | NP | ENIGMA | Reviewed by Expert Panel | Breast-ovarian cancer, familial, susceptibility to, 1 | NP |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V1 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS | SCV003783588.2 (Labcorp), SCV004360115.1 (Color) |
| V1 | OTH | Criteria Provided, Single Submitter (1★) | OTH | SCV000326291.1 (CIMBA) |
| V1 | NP | Reviewed by Expert Panel (3★) | NP | SCV000244399.2 (ENIGMA) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Reviewed by Expert Panel (3★) | NP | Breast-ovarian cancer, familial, susceptibility to, 1 |

*Contributing Level 1 statements: NP (Reviewed by Expert Panel)*  
*Non-contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts), OTH (Criteria Provided, Single Submitter), VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

### Use Case #GC-06: Expert panel VP 3-star SCV update & DR 3-star SCV

#### Input Dataset
| SCV ID | Date | Variant | Category | Type | Submitter | Review Status | Condition | Classification |
|--------|------|---------|----------|------|-----------|---------------|-----------|----------------|
| SCV001238617.1 | Apr 18, 2020 | V1 | GC | NP | Brotman Baty Inst | No Assertion Provided | Breast-ovarian cancer | NP |
| SCV000145480.2 | Sep 27, 2014 | V1 | GC | VP | BIC | No Assertion Criteria Provided | Breast-ovarian cancer | VUS |
| SCV000109422.1 | Dec 23, 2013 | V1 | GC | VP | SCRP | No Assertion Criteria Provided | Breast-ovarian cancer | P |
| SCV003783588.2 | Dec 02, 2023 | V1 | GC | VP | Labcorp | Criteria Provided, Single Submitter | Hereditary breast ovarian cancer syndrome | VUS |
| SCV004360115.1 | Feb 14, 2024 | V1 | GC | VP | Color | Criteria Provided, Single Submitter | Hereditary cancer-predisposing syndrome | VUS |
| SCV000244399.3 | Feb 20, 2025 | V1 | GC | VP | ENIGMA | Reviewed by Expert Panel | Breast-ovarian cancer, familial, susceptibility to, 1 | VUS |
| SCV002031239.1 | Jul 04, 2025 | V1 | GC | DR | PharmGKB | Reviewed by Expert Panel | methotrexate response - Toxicity | DR |

#### Aggregation Results

**Level 1 Aggregation:**
| Variant | Type | Review Status | Classification | Contributing SCVs |
|---------|------|---------------|----------------|------------------|
| V1 | NP | No Assertion Provided (-1) | NP | SCV001238617.1 (Brotman Baty Inst) |
| V1 | VP | No Assertion Criteria Provided (0★) | Conflicting classifications of pathogenicity | SCV000145480.2 (BIC), SCV000109422.1 (SCRP) |
| V1 | VP | Criteria Provided, Multiple Submitters, No Conflicts (2★) | VUS | SCV003783588.2 (Labcorp), SCV004360115.1 (Color) |
| V1 | VP | Reviewed by Expert Panel (3★) | VUS | SCV000244399.3 (ENIGMA) |
| V1 | DR | Reviewed by Expert Panel (3★) | DR | SCV002031239.1 (PharmGKB) |

*Contributing statements: All SCVs above*  
*Non-contributing statements: None*

**Level 2 Aggregation (VCV):**
| Variant | Category | Review Status | Classification | Conditions |
|---------|----------|---------------|----------------|------------|
| V1 | GC | Reviewed by Expert Panel (3★) | • VUS for Breast-ovarian cancer, familial, susceptibility to, 1<br>• DR for methotrexate response - Toxicity | Breast-ovarian cancer, familial, susceptibility to, 1; methotrexate response - Toxicity |

*Contributing Level 1 statements: VP (Reviewed by Expert Panel), DR (Reviewed by Expert Panel)*  
*Non-contributing Level 1 statements: VP (Criteria Provided, Multiple Submitters, No Conflicts), VP (No Assertion Criteria Provided), NP (No Assertion Provided)*

---

## Key Aggregation Principles Demonstrated

1. **Review Status Precedence**: Higher star ratings take priority (2★ > 0★ > -1)
2. **Conflict Detection**: VP statements with different significance values create "Conflicting classifications"
3. **Concordance Handling**: VP statements with same significance upgrade to "Multiple Submitters, No Conflicts"
4. **Quality Filtering**: Only highest available review status contributes to final VCV
5. **Condition Aggregation**: Unique conditions from contributing statements are preserved

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

## Proposed Simplifications

1. **Tabular Format**: Datasets now display as proper markdown tables for better readability
2. **Condensed Results**: Removed verbose step-by-step analysis, focusing on key outcomes
3. **Clear Hierarchy**: Emphasized review status precedence with star ratings
4. **Outcome Focus**: Highlighted final VCV results and what gets included/excluded
5. **Progressive Complexity**: Each use case builds naturally on the previous one
6. **Key Principles**: Added summary section explaining the core aggregation rules

This format makes it easier to understand the progression from simple single statements to complex multi-submitter scenarios while maintaining all the essential technical details.