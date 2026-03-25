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
--   template           - URL template with a single %s placeholder for the id
--   id_extract_pattern - optional regex applied to the raw id before substitution
--                        (e.g. '\\d+' to strip a prefix like 'MONDO:0001234' → '0001234')
--   id_replace_pattern - optional regex for REGEXP_REPLACE on the raw id
--   id_replacement     - replacement string used with id_replace_pattern
--                        (e.g. pattern '\\.' and replacement '#' turns '616101.0002' → '616101#0002')
--   Note: id_extract_pattern and id_replace_pattern are mutually exclusive per row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `clinvar_ingest.gks_xref_iri_templates` (
  db STRING NOT NULL,
  type STRING NOT NULL DEFAULT 'primary',
  template STRING NOT NULL,
  id_extract_pattern STRING,
  id_replace_pattern STRING,
  id_replacement STRING
);

INSERT INTO `clinvar_ingest.gks_xref_iri_templates` (db, type, template, id_extract_pattern, id_replace_pattern, id_replacement)
VALUES
  -- Condition / Trait xrefs
  ('MedGen',                   'primary',           'https://identifiers.org/medgen:%s',                                NULL),
  ('MedGen',                   'primary',           'https://www.ncbi.nlm.nih.gov/medgen/%s',                          NULL),

  ('OMIM',                     'primary',           'https://identifiers.org/mim:%s',                                   NULL),
  ('OMIM',                     'primary',           'https://www.omim.org/entry/%s',                                    NULL),
  ('OMIM',                     'MIM',               'https://identifiers.org/mim:%s',                                   NULL),
  ('OMIM',                     'MIM',               'https://www.omim.org/entry/%s',                                    NULL),
  ('OMIM',                     'Allelic variant',   'https://www.omim.org/entry/%s',                                    NULL, '\\.', '#'),
  ('OMIM',                     'Phenotypic series', 'https://www.omim.org/phenotypicSeries/PS%s',                       NULL),

  ('Human Phenotype Ontology', 'primary',           'https://identifiers.org/%s',                                       NULL),
  ('Human Phenotype Ontology', 'primary',           'https://hpo.jax.org/browse/term/%s',                               NULL),

  ('MONDO',                    'primary',           'https://identifiers.org/mondo:%s',                                 '\\d+'),
  ('MONDO',                    'primary',           'http://purl.obolibrary.org/obo/MONDO_%s',                          '\\d+'),

  ('Orphanet',                 'primary',           'https://identifiers.org/orphanet.ordo:Orphanet_%s',                NULL),
  ('Orphanet',                 'primary',           'http://www.orpha.net/ORDO/Orphanet_%s',                            NULL),

  ('MeSH',                     'primary',           'https://identifiers.org/mesh:%s',                                  NULL),
  ('MeSH',                     'primary',           'https://www.ncbi.nlm.nih.gov/mesh/?term=%s',                       NULL),

  ('EFO',                      'primary',           'https://identifiers.org/efo:%s',                                   '\\d+'),
  ('EFO',                      'primary',           'http://www.ebi.ac.uk/efo/EFO_%s',                                  '\\d+'),
  ('EFO: The Experimental Factor Ontology', 'primary', 'https://identifiers.org/efo:%s',                               '\\d+'),
  ('EFO: The Experimental Factor Ontology', 'primary', 'http://www.ebi.ac.uk/efo/EFO_%s',                              '\\d+'),

  ('Office of Rare Diseases',  'primary',           'https://rarediseases.info.nih.gov/diseases/%s',                    NULL),

  ('GeneReviews',              'primary',           'https://www.ncbi.nlm.nih.gov/books/%s',                            NULL),

  ('SNOMED CT',                'primary',           'https://identifiers.org/snomedct:%s',                              NULL),

  ('Genetic Testing Registry (GTR)', 'primary',     'https://www.ncbi.nlm.nih.gov/gtr/tests/%s',                       NULL),

  ('NCI',                      'primary',           'https://ncit.nci.nih.gov/ncitbrowser/ConceptReport.jsp?dictionary=NCI_Thesaurus&code=%s', NULL),

  ('Decipher',                 'primary',           'https://www.deciphergenomics.org/syndrome/%s',                     NULL),

  ('Medical Genetics Summaries', 'primary',         'https://www.ncbi.nlm.nih.gov/books/%s',                            NULL),

  ('PharmGKB',                 'primary',           'https://www.pharmgkb.org/disease/%s',                              NULL),
  ('PharmGKB',                 'drug',              'https://www.pharmgkb.org/chemical/%s',                             NULL),

  -- Citation sources
  ('pubmed',                   'primary',           'https://pubmed.ncbi.nlm.nih.gov/%s',                              NULL),
  ('pmc',                      'primary',           'https://europepmc.org/article/PMC/%s',                             NULL),
  ('doi',                      'primary',           'https://doi.org/%s',                                               NULL),
  ('bookshelf',                'primary',           'https://www.ncbi.nlm.nih.gov/books/%s',                           NULL),

  -- Gene namespaces
  ('NCBIGene',                 'primary',           'https://identifiers.org/ncbigene:%s',                              NULL),
  ('NCBIGene',                 'primary',           'https://www.ncbi.nlm.nih.gov/gene/%s',                             NULL),
  ('HGNC',                     'primary',           'https://identifiers.org/hgnc:%s',                                  '\\d+'),
  ('HGNC',                     'primary',           'https://www.genenames.org/data/gene-symbol-report/#!/hgnc_id/%s',  '\\d+'),
  ('Gene',                     'primary',           'https://www.ncbi.nlm.nih.gov/gene/%s',                             NULL),

  -- Variation xrefs (Cat-VRS)
  ('clinvar',                  'primary',           'https://identifiers.org/clinvar:%s',                               NULL),
  ('clingen',                  'primary',           'https://reg.clinicalgenome.org/redmine/projects/registry/genboree_registry/by_caid?caid=%s', NULL),
  ('dbvar',                    'primary',           'https://www.ncbi.nlm.nih.gov/dbvar/variants/%s',                   NULL),
  ('dbsnp',                    'primary',           'https://identifiers.org/dbsnp:rs%s',                               NULL),
  ('pharmgkb clinical annotation', 'primary',       'https://www.pharmgkb.org/clinicalAnnotation/%s',                   NULL),
  ('uniprotkb',               'primary',            'https://www.uniprot.org/uniprot/%s',                               NULL),
  ('genetic testing registry (gtr)', 'primary',     'https://www.ncbi.nlm.nih.gov/gtr/tests/%s',                       NULL)
;
