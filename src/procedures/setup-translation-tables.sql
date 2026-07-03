-- =============================================================================
-- Setup Translation Tables
-- =============================================================================
-- Creates and populates persistent lookup/translation tables used by GKS
-- procedures. These tables are not release-specific and should be refreshed
-- only when mappings change.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- gks_xref_iri_templates
-- Maps a database/namespace key and type to one or more IRI templates.
-- Used wherever xref (db, id) pairs need to be expanded into IRI arrays.
--
-- Columns:
--   db                 - lookup key matching the source xref.db or namespace
--   type               - xref type qualifier (e.g. 'primary', 'MIM', 'Allelic variant').
--                        Default is 'primary'. When a type-specific row exists for a
--                        given db, only those rows are used for that (db, type) pair.
--   system             - code system URL (e.g. 'https://www.omim.org/'). Default is NULL.
--   template           - URL template with a single %s placeholder for the id
--   id_extract_pattern - optional regex applied to the raw id before substitution
--                        (e.g. '\\d+' to strip a prefix like 'MONDO:0001234' → '0001234')
--   id_replace_pattern - optional regex for REGEXP_REPLACE on the raw id
--   id_replacement     - replacement string used with id_replace_pattern
--                        (e.g. pattern '\\.' and replacement '#' turns '616101.0002' → '616101#0002')
--   Note: id_extract_pattern and id_replace_pattern are mutually exclusive per row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `clinvar_ingest.gks_xref_iri_templates` (
  category STRING NOT NULL,
  db STRING NOT NULL,
  type STRING,
  system STRING,
  template STRING NOT NULL,
  id_extract_pattern STRING,
  id_replace_pattern STRING,
  id_replacement STRING
);

INSERT INTO `clinvar_ingest.gks_xref_iri_templates` (category, db, type, system, template, id_extract_pattern)
VALUES
  -- Condition / Trait xrefs
  ('Condition', 'MedGen',                   NULL,           'https://www.ncbi.nlm.nih.gov/medgen/', 'https://identifiers.org/medgen:%s',                                NULL),
  ('Condition', 'MedGen',                   NULL,           'https://www.ncbi.nlm.nih.gov/medgen/', 'https://www.ncbi.nlm.nih.gov/medgen/%s',                          NULL),

  ('Condition', 'OMIM',                     'MIM',               'https://www.omim.org/', 'https://identifiers.org/mim:%s',                                   NULL),
  ('Condition', 'OMIM',                     'MIM',               'https://www.omim.org/', 'https://www.omim.org/entry/%s',                                    NULL),
  ('Condition', 'OMIM',                     'Phenotypic series', 'https://www.omim.org/phenotypicSeries/', 'https://www.omim.org/phenotypicSeries/%s',                       NULL),

  ('Condition', 'Human Phenotype Ontology', 'primary',           'https://hpo.jax.org/', 'https://identifiers.org/HP:%s',                                       '\\d+'),
  ('Condition', 'Human Phenotype Ontology', 'primary',           'https://hpo.jax.org/', 'http://purl.obolibrary.org/obo/HP_%s',                               '\\d+'),

  ('Condition', 'MONDO',                    NULL,           'https://mondo.monarchinitiative.org/', 'https://identifiers.org/mondo:%s',                                 '\\d+'),
  ('Condition', 'MONDO',                    NULL,           'https://mondo.monarchinitiative.org/', 'http://purl.obolibrary.org/obo/MONDO_%s',                          '\\d+'),

  ('Condition', 'Orphanet',                 NULL,           'https://www.orpha.net/', 'https://identifiers.org/orphanet:%s',                '\\d+'),
  ('Condition', 'Orphanet',                 NULL,           'https://www.orpha.net/', 'http://www.orpha.net/ORDO/Orphanet_%s',                            '\\d+'),

  ('Condition', 'MeSH',                     NULL,           'https://id.nlm.nih.gov/mesh/', 'https://identifiers.org/mesh:%s',                                  NULL),
  ('Condition', 'MeSH',                     NULL,           'https://id.nlm.nih.gov/mesh/', 'https://www.ncbi.nlm.nih.gov/mesh/?term=%s',                       NULL),
  ('Condition', 'MSH',                      NULL,           'https://id.nlm.nih.gov/mesh/', 'https://identifiers.org/mesh:%s',                                  NULL),
  ('Condition', 'MSH',                      NULL,           'https://id.nlm.nih.gov/mesh/', 'https://www.ncbi.nlm.nih.gov/mesh/?term=%s',                       NULL),

  ('Condition', 'EFO',                      NULL,           'https://www.ebi.ac.uk/efo/', 'https://identifiers.org/efo:%s',                                   '\\d+'),
  ('Condition', 'EFO',                      NULL,           'https://www.ebi.ac.uk/efo/', 'http://www.ebi.ac.uk/efo/EFO_%s',                                  '\\d+'),
  ('Condition', 'EFO: The Experimental Factor Ontology', NULL, 'https://www.ebi.ac.uk/efo/', 'https://identifiers.org/efo:%s',                                '\\d+'),
  ('Condition', 'EFO: The Experimental Factor Ontology', NULL, 'https://www.ebi.ac.uk/efo/', 'http://www.ebi.ac.uk/efo/EFO_%s',                               '\\d+'),

  ('Condition', 'GeneReviews',              NULL,           'https://www.ncbi.nlm.nih.gov/books/',  'https://www.ncbi.nlm.nih.gov/books/%s',                            NULL),

  ('Condition', 'SNOMED CT',                NULL,           'https://www.snomed.org/',  'https://identifiers.org/snomedct:%s',                              NULL),

  ('Condition', 'Genetic Testing Registry (GTR)', NULL,     'https://www.ncbi.nlm.nih.gov/gtr/', 'https://www.ncbi.nlm.nih.gov/gtr/tests/%s',                       NULL),

  ('Condition', 'NCI',                      NULL,           'https://ncit.nci.nih.gov/',      'http://purl.obolibrary.org/obo/NCIT_%s', NULL),

  ('Condition', 'Decipher',                 NULL,           'https://www.deciphergenomics.org/',  'https://www.deciphergenomics.org/syndrome/%s',                     NULL),

  ('Condition', 'Medical Genetics Summaries', NULL,         'https://www.ncbi.nlm.nih.gov/books/',  'https://www.ncbi.nlm.nih.gov/books/%s',                            NULL),

  ('Condition', 'PharmGKB',                 NULL,           'https://www.pharmgkb.org/',  'https://www.clinpgx.org/accession/%s',                              NULL),
  ('Condition', 'PharmGKB',                 'drug',         'https://www.pharmgkb.org/',  'https://www.clinpgx.org/accession/%s',                             NULL),

  ('Condition', 'ClinPGx',                 NULL,           'https://www.pharmgkb.org/',   'https://www.clinpgx.org/accession/%s',                              NULL),
  ('Condition', 'ClinPGx',                 'drug',         'https://www.pharmgkb.org/',   'https://www.clinpgx.org/accession/%s',                             NULL),

  -- Citation sources
  ('Citation', 'PubMed',                   NULL,           'https://pubmed.ncbi.nlm.nih.gov/',   'https://pubmed.ncbi.nlm.nih.gov/%s',                              NULL),
  ('Citation', 'pmc',                      NULL,           'https://europepmc.org/',      'https://europepmc.org/article/PMC/%s',                             NULL),
  ('Citation', 'doi',                      NULL,           'https://doi.org/',      'https://doi.org/%s',                                               NULL),
  ('Citation', 'DOI',                      NULL,           'https://doi.org/',      'https://doi.org/%s',                                               NULL),
  ('Citation', 'Bookshelf',                NULL,           'https://www.ncbi.nlm.nih.gov/books/', 'https://www.ncbi.nlm.nih.gov/books/%s',                           NULL),
  ('Citation', 'BookShelf',                NULL,           'https://www.ncbi.nlm.nih.gov/books/', 'https://www.ncbi.nlm.nih.gov/books/%s',                           NULL),

  -- Gene namespaces
  ('Gene', 'NCBIGene',                 NULL,           'https://www.ncbi.nlm.nih.gov/gene/', 'https://identifiers.org/ncbigene:%s',                              NULL),
  ('Gene', 'NCBIGene',                 NULL,           'https://www.ncbi.nlm.nih.gov/gene/', 'https://www.ncbi.nlm.nih.gov/gene/%s',                             NULL),
  ('Gene', 'HGNC',                     NULL,           'https://www.genenames.org/',     'https://identifiers.org/hgnc:%s',                                  '\\d+'),
  ('Gene', 'HGNC',                     NULL,           'https://www.genenames.org/',     'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%s',  '\\d+'),
  ('Gene', 'Gene',                     NULL,           'https://www.ncbi.nlm.nih.gov/gene/', 'https://www.ncbi.nlm.nih.gov/gene/%s',                             NULL),

  -- Variation xrefs (Cat-VRS)
  ('Variation', 'ClinVar',           'Interpreted',        'https://www.ncbi.nlm.nih.gov/clinvar/',  'https://www.ncbi.nlm.nih.gov/clinvar/variation/%s',                NULL),
  ('Variation', 'ClinVar',           'Interpreted',        'https://www.ncbi.nlm.nih.gov/clinvar/',  'https://identifiers.org/clinvar:%s',                               NULL),
  ('Variation', 'ClinVar',           'Included',           'https://www.ncbi.nlm.nih.gov/clinvar/',  'https://www.ncbi.nlm.nih.gov/clinvar/variation/%s',                NULL),
  ('Variation', 'ClinVar',           'Included',           'https://www.ncbi.nlm.nih.gov/clinvar/',  'https://identifiers.org/clinvar:%s',                               NULL),
  
  ('Variation', 'ClinGen',                        NULL,    'https://reg.clinicalgenome.org/',  'https://reg.clinicalgenome.org/redmine/projects/registry/genboree_registry/by_caid?caid=%s', NULL),
  ('Variation', 'dbVar',                          NULL,    'https://www.ncbi.nlm.nih.gov/dbvar/',   'https://www.ncbi.nlm.nih.gov/dbvar/variants/%s',                   NULL),
  ('Variation', 'dbSNP',                          'rs',    'https://www.ncbi.nlm.nih.gov/snp/',           'https://identifiers.org/dbsnp:rs%s',                               NULL),
  ('Variation', 'PharmGKB Clinical Annotation',   NULL,    'https://www.pharmgkb.org/',        'https://www.clinpgx.org/accession/%s',                             NULL),
  ('Variation', 'UniProtKB',                      NULL,    'https://www.uniprot.org/',     'http://purl.uniprot.org/annotation/VAR_%s',                        NULL),
  ('Variation', 'UniProtKB/Swiss-Prot',           NULL,    'https://www.uniprot.org/',         'http://purl.uniprot.org/annotation/VAR_%s',                        NULL),
  ('Tests', 'Genetic Testing Registry (GTR)',     NULL,    'https://www.ncbi.nlm.nih.gov/gtr/',        'https://www.ncbi.nlm.nih.gov/gtr/tests/%s',                        NULL)
;

-- Rows requiring id_replace_pattern / id_replacement (all 6 columns)
INSERT INTO `clinvar_ingest.gks_xref_iri_templates` (category, db, type, system, template, id_extract_pattern, id_replace_pattern, id_replacement)
VALUES
  ('Variation', 'OMIM',                     'Allelic variant',   'https://www.omim.org/', 'https://www.omim.org/entry/%s',                                    NULL, '\\.', '#')
;
