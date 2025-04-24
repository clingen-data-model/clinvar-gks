# clinvar-gks

ClinVar GKS is a data transformation project being resourced by the ClinGen driver project.  This project and team aims to stand up and maintain a running pipeline process which will convert all clinvar release data to its GA4GH GKS standard equivalent. It is being developed with the intent to run automatically to create sibling release datasets whenever ClinVar publishes a new release on the ClinVar ftp site (typically once a week).  It also intends to support inclusion of 100% of the data records and elements that are provided in the ClinVar released datasets. 

## Implementation Roadmap
This project has the added complexity of driving the GKS VA-Spec, Cat-VRS and VRS specification efforts. As such, it requires a methodical pace to prioritizing areas of the ClinVar release to focus on to establish a foundation and gain some stability in the schemas with which the remaining data can eventually be included in the pipeline.

The general plan is to apply, iterate, test and harden the schemas related to variation, categorical variation and the submitted classifications or SCVs in ClinVar. By starting with the SCVs, we capture the *source* of data that ClinVar utilizes to derive all the higher order data and statements (e.g. RCVs and VCVs and their aggregated classifications). As the data and schemas receive validation from both the GKS product groups and the implementers the RCV and VCV records will be designed and implemented and the ancillary data elements not included in the first versions will be added to get to the 100% data inclusion objective.

In order to assure the initial roll out of SCVs as GA4GH GKS standard so that the data would be of substantive utility to ClinGen and other community members. As such the following list represent the initial subset of data attributes that are being included in the first releases of the transformed datasets.

## VA-Spec/Cat-VRS 1.0 Releases
Coming May 2025, early work in progress and example JSON outpu can be found in the `examples` folder.
Documentation on the rules and policies are also a work in progress and being updated in the `docs` folder.


## Pilot Releases
Apr 2024 Connect release (tag: 1.0.0.connect.2024-04.1) based on VA-Spec/Cat-VRS Apr.2024 pre-release

  - The First Full ClinVar-GKS Pilot Dataset
  ClinVar Release 2024-04-07 (json.gz files)
  
    - Variations : all 2.8M+ in CatVar format
    https://bit.ly/clinvar-variation-20240407
    
    - SCVs : all 4.1M+ in VA Statement format
    https://bit.ly/clinvar-scvs-20240407  (w/ variations)

