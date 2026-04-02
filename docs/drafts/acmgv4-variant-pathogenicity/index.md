# ACMGv4 Variant Pathogenicity Profile

!!! warning "Draft"
    This page is under active development. The design and content are subject to change.

## Overview

This project defines the ClinVar-GKS profile for variant pathogenicity classification using the ACMG/AMP v4 evidence framework. The goal is to represent ACMG v4 evidence criteria, rule combinations, and classification outcomes within the GKS Statement and EvidenceLine structures.

---

## Background

The ACMG/AMP guidelines (2015, updated v4) provide a standardized framework for classifying germline sequence variants. Submitters to ClinVar increasingly cite specific ACMG evidence criteria (e.g., PVS1, PM2, BP1) in their assertions. This profile captures that structured evidence alongside the final pathogenicity classification.

---

## Design Goals

- Represent ACMG v4 evidence criteria as structured evidence within VA-Spec EvidenceLines
- Map ClinVar-submitted ACMG criteria to standardized codes and strength levels
- Support both individual criterion assertions and combined rule-based classifications
- Maintain compatibility with the existing SCV Pathogenicity profile (G.01)

---

## Current Work

*This section will be updated as the design progresses.*
