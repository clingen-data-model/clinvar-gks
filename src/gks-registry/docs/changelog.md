# Schema Changelog

Changes to schemas between releases, organized by repository.

## cat-vrs

### 1.0.0.connect.2024-04.1 (initial)

**Added:**
- CanonicalAllele
- CategoricalCnv
- CategoricalVariation
- DescribedVariation
- NumberChange
- NumberCount
- ProteinSequenceConsequence
- QuantityVariance

### 1.0.0-connect.2024-09.1 (from 1.0.0.connect.2024-04.1)

**Removed:**
- CanonicalAllele
- CategoricalCnv
- CategoricalVariation
- DescribedVariation
- NumberChange
- NumberCount
- ProteinSequenceConsequence
- QuantityVariance

### 1.0.0-ballot.2024-11.1 (from 1.0.0-connect.2024-09.1)

**Added:**
- CanonicalAllele
- CategoricalCnv
- CategoricalVariant
- Constraint
- CopyChangeConstraint
- CopyCountConstraint
- DefiningAlleleConstraint
- DefiningLocationConstraint
- ProteinSequenceConsequence

### 1.0.0-snapshot.2025-02.1 (from 1.0.0-ballot.2024-11.1)

**Modified:**
- CanonicalAllele: description: updated
- ProteinSequenceConsequence: description: updated

### 1.0.0-snapshot.2025-02.3 (from 1.0.0-snapshot.2025-02.2)

**Added:**
- FeatureContextConstraint

### 1.0.0 (initial)

**Added:**
- CanonicalAllele
- CategoricalCnv
- CategoricalVariant
- Constraint
- CopyChangeConstraint
- CopyCountConstraint
- DefiningAlleleConstraint
- DefiningLocationConstraint
- FeatureContextConstraint
- ProteinSequenceConsequence

### 1.1.0-snapshot.2026-02.1 (from 1.0.0)

**Added:**
- FunctionConstraint
- FunctionVariant

**Modified:**
- CanonicalAllele: description: updated
- CopyChangeConstraint: description: updated


## gks-core

### 1.0.0.connect.2024-04.1 (initial)

**Added:**
- Code
- Coding
- CombinationTherapy
- Condition
- Disease
- Extension
- Gene
- IRI
- Mapping
- Phenotype
- TherapeuticAction
- TherapeuticAgent
- TherapeuticProcedure
- TherapeuticSubstituteGroup
- TraitSet

### 1.0.0-connect.2024-09.1 (from 1.0.0.connect.2024-04.1)

**Added:**
- Agent
- Characteristic
- ConceptMapping
- Contribution
- DataSet
- Document
- EvidenceLine
- Method
- RecordMetadata
- StudyGroup

**Removed:**
- Mapping

**Modified:**
- Code: description: updated
- Coding: description: updated
- CombinationTherapy: description: updated
- Condition: maturity: `unknown` → `draft`
- Disease: description: updated
- Extension: description: updated
- IRI: description: updated
- TherapeuticProcedure: maturity: `unknown` → `draft`, description: updated

### 1.0.0-snapshot.2024-11.1 (from 1.0.0-connect.2024-09.1)

**Added:**
- MappableConcept
- code
- date
- datetime
- iriReference

**Removed:**
- Agent
- Characteristic
- Code
- CombinationTherapy
- Condition
- Contribution
- DataSet
- Disease
- Document
- EvidenceLine
- Gene
- IRI
- Method
- Phenotype
- RecordMetadata
- StudyGroup
- TherapeuticAction
- TherapeuticAgent
- TherapeuticProcedure
- TherapeuticSubstituteGroup
- TraitSet

**Modified:**
- Extension: maturity: `draft` → `trial use`

### 1.0.0-snapshot.2024-11.3 (from 1.0.0-snapshot.2024-11.1)

**Modified:**
- Coding: maturity: `draft` → `trial use`
- ConceptMapping: maturity: `draft` → `trial use`
- MappableConcept: description: updated

### 1.0.0-snapshot.2025-02.1 (from 1.0.0-snapshot.2024-11.3)

**Modified:**
- Coding: maturity: `trial use` → `draft`
- ConceptMapping: maturity: `trial use` → `draft`
- MappableConcept: maturity: `trial use` → `draft`

### 1.0.0-snapshot.2025-02.2 (from 1.0.0-snapshot.2025-02.1)

**Modified:**
- Coding: maturity: `draft` → `trial use`
- ConceptMapping: maturity: `draft` → `trial use`
- MappableConcept: maturity: `draft` → `trial use`
- code: maturity: `draft` → `trial use`
- date: maturity: `draft` → `trial use`
- datetime: maturity: `draft` → `trial use`

### 1.0.0-snapshot.2025-02.3 (from 1.0.0-snapshot.2025-02.2)

**Modified:**
- MappableConcept: description: updated

### 1.0.0 (initial)

**Added:**
- Coding
- ConceptMapping
- Extension
- MappableConcept
- code
- date
- datetime
- iriReference

### 1.1.0 (from 1.0.0)

**Added:**
- ConceptSet


## va-spec

### 1.0.0.connect.2024-04.1 (initial)

**Added:**
- Agent
- CohortAlleleFrequency
- Contribution
- DataItem
- Document
- Method
- VariantOncogenicityStudy
- VariantPathogenicity
- VariantTherapeuticResponseStudy

### 1.0.0-connect.2024-09.1 (from 1.0.0.connect.2024-04.1)

**Added:**
- AssayVariantEffectClinicalClassificationStatement
- AssayVariantEffectFunctionalClassificationStatement
- AssayVariantEffectMeasurementStudyResult
- CohortAlleleFrequencyStudyResult
- VariantDiagnosticStudyStatement
- VariantOncogenicityStudyStatement
- VariantPathogenicityStatement
- VariantPrognosticStudyStatement
- VariantTherapeuticResponseStudyStatement

**Removed:**
- Agent
- CohortAlleleFrequency
- Contribution
- DataItem
- Document
- Method
- VariantOncogenicityStudy
- VariantPathogenicity
- VariantTherapeuticResponseStudy

### 1.0.0-ballot.2024-11.1 (from 1.0.0-connect.2024-09.1)

**Added:**
- Agent
- Condition
- Contribution
- DataSet
- Document
- EvidenceLine
- ExperimentalVariantFunctionalImpactProposition
- ExperimentalVariantFunctionalImpactStudyResult
- Method
- Statement
- StudyGroup
- SubjectVariantProposition
- Therapeutic
- TherapyGroup
- TraitSet
- VariantDiagnosticProposition
- VariantOncogenicityFunctionalImpactEvidenceLine
- VariantOncogenicityProposition
- VariantPathogenicityFunctionalImpactEvidenceLine
- VariantPathogenicityProposition
- VariantPrognosticProposition
- VariantTherapeuticResponseProposition

**Removed:**
- AssayVariantEffectClinicalClassificationStatement
- AssayVariantEffectFunctionalClassificationStatement
- AssayVariantEffectMeasurementStudyResult

**Modified:**
- CohortAlleleFrequencyStudyResult: maturity: `draft` → `trial use`
- VariantDiagnosticStudyStatement: description: updated
- VariantOncogenicityStudyStatement: description: updated
- VariantPrognosticStudyStatement: description: updated
- VariantTherapeuticResponseStudyStatement: description: updated

### 1.0.0-ballot.2024-11.2 (from 1.0.0-ballot.2024-11.1)

**Modified:**
- Agent: maturity: `draft` → `trial use`
- Contribution: maturity: `draft` → `trial use`

### 1.0.0-snapshot.2025-02.1 (from 1.0.0-ballot.2024-11.2)

**Added:**
- StudyResult

**Modified:**
- VariantOncogenicityFunctionalImpactEvidenceLine: description: updated
- VariantPathogenicityFunctionalImpactEvidenceLine: description: updated

### 1.0.0-snapshot.2025-02.2 (from 1.0.0-snapshot.2025-02.1)

**Added:**
- ConditionSet

**Removed:**
- TraitSet

**Modified:**
- Condition: description: updated
- Therapeutic: description: updated
- TherapyGroup: description: updated

### 1.0.0-ballot.2025-03.3 (from 1.0.0-ballot.2025-03.2)

**Modified:**
- ConditionSet: description: updated
- TherapyGroup: description: updated

### 1.0.0-ballot.2025-03.4 (from 1.0.0-ballot.2025-03.3)

**Added:**
- TumorVariantFrequencyStudyResult
- VariantOncogenicityEvidenceLine
- VariantPathogenicityEvidenceLine

**Removed:**
- VariantOncogenicityFunctionalImpactEvidenceLine
- VariantPathogenicityFunctionalImpactEvidenceLine

### 1.0.0 (initial)

**Added:**
- Agent
- CohortAlleleFrequencyStudyResult
- Condition
- ConditionSet
- Contribution
- DataSet
- Document
- EvidenceLine
- ExperimentalVariantFunctionalImpactProposition
- ExperimentalVariantFunctionalImpactStudyResult
- Method
- Statement
- StudyGroup
- StudyResult
- SubjectVariantProposition
- Therapeutic
- TherapyGroup
- TumorVariantFrequencyStudyResult
- VariantDiagnosticProposition
- VariantDiagnosticStudyStatement
- VariantOncogenicityEvidenceLine
- VariantOncogenicityProposition
- VariantOncogenicityStudyStatement
- VariantPathogenicityEvidenceLine
- VariantPathogenicityProposition
- VariantPathogenicityStatement
- VariantPrognosticProposition
- VariantPrognosticStudyStatement
- VariantTherapeuticResponseProposition
- VariantTherapeuticResponseStudyStatement

### 1.0.1 (from 1.0.0)

**Modified:**
- ConditionSet: description: updated
- VariantOncogenicityEvidenceLine: description: updated
- VariantPathogenicityEvidenceLine: description: updated


## vrs

### 1.0.0-rc.1 (initial)

**Added:**
- Allele
- DateTime
- Id
- Interval
- Location
- NestedInterval
- SequenceLocation
- SequenceState
- SimpleInterval
- State
- Text
- Variation

### 1.0.0-rc.2 (from 1.0.0-rc.1)

**Added:**
- B64UDigest
- CURIE

**Removed:**
- Id
- NestedInterval

**Modified:**
- Allele: ga4gh_prefix: `none` → `VA`
- SequenceLocation: ga4gh_prefix: `none` → `VSL`
- Text: ga4gh_prefix: `none` → `VT`

### 1.0.0 (from 1.0.0-rc.2)

**Removed:**
- B64UDigest

### 1.1.0 (from 1.0.0)

**Added:**
- ChromosomeLocation (`VCL`)
- Cytoband
- CytobandInterval
- Haplotype (`VH`)
- SequenceInterval
- VariationSet (`VS`)

**Removed:**
- Interval

**Modified:**
- CURIE: description: updated
- SequenceLocation: description: added
- SequenceState: description: added
- SimpleInterval: description: added
- Text: description: added
- Variation: description: updated

### 1.2.0 (from 1.1.2)

**Added:**
- CopyNumber
- DefiniteRange
- DerivedSequenceExpression
- Feature
- Gene
- HumanCytoband
- IndefiniteRange
- LiteralSequenceExpression
- MolecularVariation
- Number
- RepeatedSequenceExpression
- Sequence
- SequenceExpression
- SystemicVariation
- UtilityVariation

**Removed:**
- Cytoband
- DateTime
- State

**Modified:**
- Allele: ga4gh_prefix: `VA` → `none`, description: updated
- CURIE: description: updated
- ChromosomeLocation: ga4gh_prefix: `VCL` → `none`, description: updated
- Haplotype: ga4gh_prefix: `VH` → `none`, description: updated
- Location: description: updated
- SequenceInterval: description: added
- SequenceLocation: ga4gh_prefix: `VSL` → `none`, description: updated
- SequenceState: description: updated
- SimpleInterval: description: updated
- Text: ga4gh_prefix: `VT` → `none`, description: updated
- Variation: description: updated
- VariationSet: ga4gh_prefix: `VS` → `none`, description: updated

### 1.2.1 (from 1.2.0)

**Added:**
- ComposedSequenceExpression
- Residue

**Modified:**
- Allele: description: updated
- CURIE: description: updated
- CopyNumber: description: updated
- CytobandInterval: description: updated
- DerivedSequenceExpression: description: updated
- Gene: description: updated
- Haplotype: description: updated
- HumanCytoband: description: updated
- IndefiniteRange: description: updated
- Number: description: updated
- Sequence: description: updated
- SequenceExpression: description: updated
- SequenceInterval: description: updated
- SequenceState: description: updated
- SimpleInterval: description: updated
- UtilityVariation: description: updated

### 1.3.0 (from 1.2.1)

**Added:**
- CopyNumberChange
- CopyNumberCount
- Genotype
- GenotypeMember

**Removed:**
- CopyNumber

**Modified:**
- ComposedSequenceExpression: description: updated

### 2.0.0.connect.2024-04.1 (from 1.3.0)

**Added:**
- Adjacency (`AJ`)
- CisPhasedBlock (`CPB`)
- LengthExpression
- Range
- ReferenceLengthExpression
- SequenceReference
- SequenceString

**Removed:**
- CURIE
- ChromosomeLocation
- ComposedSequenceExpression
- CytobandInterval
- DefiniteRange
- DerivedSequenceExpression
- Feature
- Gene
- Genotype
- GenotypeMember
- Haplotype
- HumanCytoband
- IndefiniteRange
- Location
- Number
- RepeatedSequenceExpression
- Sequence
- SequenceInterval
- SequenceState
- SimpleInterval
- Text
- UtilityVariation
- VariationSet

**Modified:**
- Allele: maturity: `unknown` → `draft`, ga4gh_prefix: `none` → `VA`
- CopyNumberChange: ga4gh_prefix: `none` → `CX`, description: updated
- CopyNumberCount: maturity: `unknown` → `draft`, ga4gh_prefix: `none` → `CN`, description: updated
- LiteralSequenceExpression: maturity: `unknown` → `draft`
- Residue: maturity: `unknown` → `draft`
- SequenceLocation: maturity: `unknown` → `draft`, ga4gh_prefix: `none` → `SL`

### 2.0.0-ballot.2024-08.1 (from 2.0.0.connect.2024-04.1)

**Added:**
- DerivativeMolecule (`DM`)
- Expression
- Terminus (`TM`)
- TraversalBlock

**Modified:**
- Adjacency: maturity: `draft` → `trial use`
- Allele: maturity: `draft` → `trial use`
- CisPhasedBlock: maturity: `draft` → `trial use`
- CopyNumberChange: maturity: `draft` → `trial use`
- CopyNumberCount: maturity: `draft` → `trial use`
- LengthExpression: maturity: `draft` → `trial use`
- LiteralSequenceExpression: maturity: `draft` → `trial use`
- Range: maturity: `draft` → `trial use`
- ReferenceLengthExpression: maturity: `draft` → `trial use`, description: updated
- Residue: maturity: `draft` → `trial use`
- SequenceLocation: maturity: `draft` → `trial use`
- SequenceReference: maturity: `draft` → `trial use`
- SequenceString: maturity: `draft` → `trial use`

### 2.0.0-connect.2024-09.1 (from 2.0.0-ballot.2024-08.1)

**Added:**
- Location

**Modified:**
- Adjacency: maturity: `trial use` → `draft`
- Allele: maturity: `trial use` → `draft`
- CisPhasedBlock: maturity: `trial use` → `draft`
- CopyNumberChange: maturity: `trial use` → `draft`
- CopyNumberCount: maturity: `trial use` → `draft`
- DerivativeMolecule: maturity: `trial use` → `draft`
- Expression: maturity: `trial use` → `draft`
- LengthExpression: maturity: `trial use` → `draft`
- LiteralSequenceExpression: maturity: `trial use` → `draft`
- Range: maturity: `trial use` → `draft`
- ReferenceLengthExpression: maturity: `trial use` → `draft`
- Residue: maturity: `trial use` → `draft`
- SequenceLocation: maturity: `trial use` → `draft`
- SequenceReference: maturity: `trial use` → `draft`
- SequenceString: maturity: `trial use` → `draft`
- Terminus: maturity: `trial use` → `draft`
- TraversalBlock: maturity: `trial use` → `draft`

### 2.0.0-ballot.2024-11.1 (from 2.0.0-connect.2024-09.1)

**Added:**
- residue
- sequenceString

**Removed:**
- Residue
- SequenceString

**Modified:**
- Adjacency: maturity: `draft` → `trial use`, description: updated
- Allele: maturity: `draft` → `trial use`
- CisPhasedBlock: maturity: `draft` → `trial use`
- CopyNumberChange: description: updated
- CopyNumberCount: maturity: `draft` → `trial use`, description: updated
- Expression: maturity: `draft` → `trial use`
- LiteralSequenceExpression: maturity: `draft` → `trial use`
- Location: maturity: `unknown` → `trial use`
- MolecularVariation: maturity: `unknown` → `trial use`
- Range: maturity: `draft` → `trial use`
- ReferenceLengthExpression: maturity: `draft` → `trial use`
- SequenceExpression: maturity: `unknown` → `trial use`
- SequenceLocation: maturity: `draft` → `trial use`
- SequenceReference: maturity: `draft` → `trial use`
- SystemicVariation: maturity: `unknown` → `trial use`
- TraversalBlock: description: updated
- Variation: maturity: `unknown` → `trial use`

### 2.0.0-snapshot.2025-02.1 (from 2.0.0-ballot.2024-11.1)

**Modified:**
- SequenceLocation: description: updated

### 2.0.0 (from 1.3.0)

**Added:**
- Adjacency (`AJ`)
- CisPhasedBlock (`CPB`)
- DerivativeMolecule (`DM`)
- Expression
- LengthExpression
- Range
- ReferenceLengthExpression
- SequenceReference
- Terminus (`TM`)
- TraversalBlock
- residue
- sequenceString

**Removed:**
- CURIE
- ChromosomeLocation
- ComposedSequenceExpression
- CytobandInterval
- DefiniteRange
- DerivedSequenceExpression
- Feature
- Gene
- Genotype
- GenotypeMember
- Haplotype
- HumanCytoband
- IndefiniteRange
- Number
- RepeatedSequenceExpression
- Residue
- Sequence
- SequenceInterval
- SequenceState
- SimpleInterval
- Text
- UtilityVariation
- VariationSet

**Modified:**
- Allele: maturity: `unknown` → `trial use`, ga4gh_prefix: `none` → `VA`
- CopyNumberChange: ga4gh_prefix: `none` → `CX`, description: updated
- CopyNumberCount: maturity: `unknown` → `trial use`, ga4gh_prefix: `none` → `CN`, description: updated
- LiteralSequenceExpression: maturity: `unknown` → `trial use`
- Location: maturity: `unknown` → `trial use`
- MolecularVariation: maturity: `unknown` → `trial use`
- SequenceExpression: maturity: `unknown` → `trial use`
- SequenceLocation: maturity: `unknown` → `trial use`, ga4gh_prefix: `none` → `SL`, description: updated
- SystemicVariation: maturity: `unknown` → `trial use`
- Variation: maturity: `unknown` → `trial use`

### 2.1.0-snapshot.2026-02.1 (from 2.0.1)

**Added:**
- RelativeAllele (`RA`)
- RelativeSequenceLocation (`RSL`)
- SequenceOffsetLocation

**Modified:**
- SequenceExpression: description: updated

