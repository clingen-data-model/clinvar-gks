# Glossary

Key terms, acronyms, and concepts used throughout the ClinVar-GKS documentation.

---

## Standards and Organizations

**GA4GH** (Global Alliance for Genomics and Health)
:   International consortium developing standards for genomic data representation and exchange.

**GKS** (Genomic Knowledge Standards)
:   Collective term for GA4GH standards — VRS, Cat-VRS, and VA-Spec — for representing genomic variants and clinical assertions.

**VRS** (Variation Representation Specification)
:   GA4GH standard for normalized, computable variant identifiers. Defines how variants are represented with sequence references, locations, and states.

**Cat-VRS** (Categorical Variation Representation Specification)
:   GA4GH standard for categorical variant representations that group variants at a higher level — CanonicalAlleles, CategoricalCnvChange, CategoricalCnvCount.

**VA-Spec** (Variant Annotation Specification)
:   GA4GH standard for clinical variant statements. Defines the Statement, Proposition, and EvidenceLine structures used by SCV and VCV outputs.

**ACMG** (American College of Medical Genetics and Genomics)
:   Organization that publishes pathogenicity classification guidelines (2015, v4) used by ClinVar submitters.

**AMP/ASCO/CAP**
:   Association for Molecular Pathology / American Society of Clinical Oncology / College of American Pathologists. Published somatic clinical impact tiering guidelines (Tier I-IV).

---

## ClinVar Concepts

**ClinVar**
:   NCBI database of clinically relevant variant submissions and aggregate classifications.

**SCV** (Submitted Clinical Variant)
:   Individual submission from a laboratory or organization reporting their clinical interpretation of a variant. Each SCV contains one classification for one variant and condition combination.

**VCV** (Variant-level Clinical Variant)
:   Aggregate classification combining all SCV submissions for the same variant across all conditions. Represents the variant-level summary.

**RCV** (Review-level Clinical Variant)
:   Aggregate classification combining all SCV submissions for the same variant AND the same condition. Used internally by ClinVar for aggregation.

**Trait** (ClinVar terminology)
:   A disease, phenotype, or finding associated with a variant submission. In GKS output, this is termed "Condition."

**TraitSet**
:   A group of traits with a membership operator. In GKS output, this is termed "ConditionSet."

**Review Status**
:   Star levels (0-4) indicating submission confidence. Determines how submissions are ranked during aggregation. See [Review Status](../profiles/review-status.md).

---

## Submission Levels

**Submission Level**
:   Classification of SCV authority and review rigor. Determines aggregation logic and review status derivation.

**PG** (Practice Guideline)
:   Submission level rank 4 (4 stars). Published practice guidelines from authoritative bodies.

**EP** (Expert Panel)
:   Submission level rank 3 (3 stars). Classifications reviewed and approved by expert panels.

**CP** (Criteria Provided)
:   Submission level rank 1 (1 star). Submitter provided documented criteria for their classification.

**NOCP** (No Assertion Criteria Provided)
:   Submission level rank 0 (0 stars). Classification submitted without documented criteria.

**NOCL** (No Classification Provided)
:   Submission level rank -1 (0 stars). Submission present but no classification was given.

**FLAG** (Flagged Submission)
:   Submission level rank -3 (0 stars). Submission flagged by ClinVar for quality concerns.

---

## Data Model

**Statement** (VA-Spec)
:   A complete clinical assertion containing classification, proposition, evidence, contributions, and metadata. Both SCV and VCV records are Statements.

**Proposition** (VA-Spec)
:   The core clinical claim being asserted. Contains a subject (variant), predicate (relationship), object (condition/therapy), and optional qualifiers.

**EvidenceLine** (VA-Spec)
:   Links a proposition to evidence items with direction and strength assessments. SCV statements use `hasEvidenceLines`; VCV statements use nested `evidenceLines`.

**CategoricalVariant** (Cat-VRS)
:   Higher-level grouping that associates a ClinVar variation with its resolved VRS representation. Types: CanonicalAllele, CategoricalCnvChange, CategoricalCnvCount.

**MappableConcept**
:   A single concept with `conceptType`, `name`, and optional `extension` array. Used for single-label classifications and objectClassification.

**ConceptSet**
:   A structured group of concepts with `membershipOperator` (AND). Used for multi-concept classifications such as RCV's `objectConditionClassification` (combining condition and classification).

**Constraint** (Cat-VRS)
:   Defining relationship between a categorical variant and its VRS representation. Types: DefiningAlleleConstraint, DefiningLocationConstraint, CopyChangeConstraint, CopyCountConstraint.

**Extension**
:   Name/value pair carrying metadata not part of core GA4GH specifications but essential for clinical interpretation. Present on statements, classifications, propositions, conditions, and categorical variants.

---

## Proposition Types

**VariantPathogenicityProposition**
:   Proposition type for germline pathogenicity assertions. Predicate: `isCausalFor`. Statement type G.01.

**VariantOncogenicityProposition**
:   Proposition type for oncogenicity assertions. Predicate: `isOncogenicFor`. Statement type O.10.

**VariantClinicalSignificanceProposition**
:   Proposition type for somatic clinical significance (AMP/ASCO/CAP tiering). Predicate: `isClinicallySignificantFor`. Statement type S.11.

**VariantTherapeuticResponseProposition**
:   Proposition type for therapeutic response assertions. Predicate: `predictsSensitivityTo`. Statement type S.12.

**VariantDiagnosticProposition**
:   Proposition type for diagnostic assertions. Statement type S.13.

**VariantPrognosticProposition**
:   Proposition type for prognostic assertions. Statement type S.14.

**VariantAggregateClassificationProposition**
:   Proposition type used in VCV aggregate statements. Predicate: `hasAggregateClassification`.

**ClinVar\*Proposition**
:   Custom proposition types for non-standard ClinVar statement types (G.02-G.09): Drug Response, Risk Factor, Protective, Affects, Association, Confers Sensitivity, Other, Not Provided.

---

## Classification Terms

**Direction**
:   Whether evidence supports or disputes a proposition. Values: `supports`, `disputes`, `neutral`.

**Strength**
:   Evidence strength level. Values: `definitive`, `likely`, `strong`, `potential`. Omitted (null) when not applicable.

**Tier I** / **Tier II** / **Tier III** / **Tier IV**
:   Somatic clinical impact classification levels. Tier I (Strong) and Tier II (Potential) require paired sub-statements. Tier III (Unknown) and Tier IV (Benign/Likely benign) do not.

**Concordant**
:   All contributing SCVs for a variant share the same classification. Produces a single aggregate label.

**Conflicting**
:   Contributing SCVs have different classifications. Produces a "Conflicting classifications of..." label with a `conflictingExplanation` extension.

---

## Qualifier Types

**Gene Context Qualifier**
:   Proposition qualifier restricting an assertion to a specific gene. Contains NCBI Gene identifier and HGNC mappings.

**Mode of Inheritance Qualifier**
:   Proposition qualifier specifying inheritance pattern (e.g., autosomal dominant, X-linked). Maps to HPO terms.

**Penetrance Qualifier**
:   Proposition qualifier indicating penetrance level for pathogenic or risk allele classifications. Values: `low`, `risk`.

**Aggregate Qualifiers**
:   Array on VCV propositions containing context qualifiers: AssertionGroup, PropositionType, SubmissionLevel, ClassificationTier.

---

## VCV Aggregation

**Aggregation**
:   Process of combining multiple SCV submissions into higher-order VCV statements following submission-level-specific logic.

**Winner-Takes-All**
:   Aggregation strategy at the Aggregate Contribution Layer where the highest-ranked submission level's classification becomes the aggregate result. Lower-ranked levels become non-contributing.

**Contributing Submission**
:   Submission whose review status is highest-ranked within an aggregation group. Directly reflected in the aggregate classification.

**Non-Contributing Submission**
:   Submission ranked lower than the contributing submission. Preserved in the evidence structure but not reflected in the aggregate label.

**Grouping Layer**
:   First conceptual aggregation layer. Consists of Base Grouping and Tier Grouping steps. Produces initial aggregation of SCVs into groups by submission level.

**Base Grouping** (Grouping Layer)
:   First step of the Grouping Layer. Groups SCVs by variation + statement group + proposition type + submission level [+ tier]. Applies submission-level-specific classification and conflict detection logic.

**Tier Grouping** (Grouping Layer)
:   Second step of the Grouping Layer (somatic sci only). Aggregates tier-level groups within each submission level.

**Aggregate Contribution Layer**
:   Second and final aggregation layer. Applies winner-takes-all ranking across submission levels. Terminal layer for both germline and somatic statements.

**Aggregate Review Status**
:   Final review status of a VCV statement derived from submission level and aggregation outcome. See [Aggregate Review Status](../pipeline/vcv-statements/vcv-aggregation-rules.md#aggregate-review-status).

---

## Classification Attributes (VCV)

**classification**
:   VCV/RCV classification attribute. Contains a single aggregate label with optional `conflictingExplanation` extension.

**objectClassification**
:   VCV proposition classification attribute. A MappableConcept matching the statement classification, without extensions.

---

## Identifier Formats

**clinvar:{variation_id}**
:   ClinVar variation identifier. References a CategoricalVariant record in `variation.jsonl.gz`. Example: `clinvar:12582`.

**clinvar.submission:SCV{id}.{version}**
:   SCV submission identifier with version. References an SCV Statement record. Example: `clinvar.submission:SCV001571657.2`.

**clinvar.submitter:{submitter_id}**
:   Submitter organization identifier. Embedded in SCV records. Example: `clinvar.submitter:508027`.

**ga4gh:{type}.{digest}**
:   VRS identity digest. Embedded within CategoricalVariant constraints. Example: `ga4gh:VA.xXBYkzzu1AH0oyMKlbBtP2`.

---

## Output Files

**variation.jsonl.gz**
:   Output file containing CategoricalVariant records. One record per ClinVar variation with a resolved VRS identity.

**scv_by_ref.jsonl.gz**
:   Output file containing SCV statements with variants referenced by ID. Compact format.

**scv_inline.jsonl.gz**
:   Output file containing SCV statements with full variant objects embedded inline. Self-contained format.

**vcv.jsonl.gz**
:   Output file containing VCV aggregate classification statements with hierarchical evidence structure.

---

## Technical Terms

**JSONL**
:   Newline-delimited JSON format. One complete JSON object per line, no surrounding array. Used for all ClinVar-GKS output files.

**Null Stripping**
:   Technique where null-valued fields and empty arrays are omitted from JSON output via `JSON_STRIP_NULLS(remove_empty => TRUE)`.

**By-Reference Format**
:   JSON structure where related objects are referenced by ID rather than embedded inline. Reduces duplication when many statements reference the same variant.

**Inline Format**
:   JSON structure where related objects are fully embedded within the parent. Self-contained — each record has all data needed for interpretation.

**JSON Pointer**
:   Standard format (RFC 6901) for referencing nested JSON values. Used in somatic target propositions (e.g., `4/proposition/subjectVariant`).

**BigQuery**
:   Google Cloud Platform data warehouse used for all ClinVar-GKS SQL procedures and table storage.

**Stored Procedure**
:   BigQuery SQL routine executing a specific pipeline step (e.g., `gks_catvar_proc`, `gks_vcv_proc`).

---

## External Databases

**MedGen**
:   Medical Genetics database providing standardized condition identifiers. Primary coding system for conditions.

**OMIM** (Online Mendelian Inheritance in Man)
:   Comprehensive database of genetic disorders. Used for condition cross-references.

**MONDO** (Monarch Disease Ontology)
:   Unified disease ontology providing standardized condition identifiers.

**HPO** (Human Phenotype Ontology)
:   Standardized phenotype terms used for conditions and mode of inheritance.

**Orphanet**
:   Database of rare diseases. Used for condition cross-references.

**HGNC** (HUGO Gene Nomenclature Committee)
:   Official gene nomenclature database. Gene symbols and identifiers appear in gene context qualifiers.

**dbSNP**
:   NCBI SNP database. External cross-reference source for variants.

**identifiers.org**
:   Standardized URL namespace for biomedical identifiers used in mapping IRIs.
