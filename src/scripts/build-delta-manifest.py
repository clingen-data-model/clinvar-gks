#!/usr/bin/env python3
"""Build manifest.json for a GKS delta release from {dataset}.gks_change_log.

Usage: build-delta-manifest.py <release_date> <dataset_version> <output_path>
"""
import json
import os
import subprocess
import sys

# dict table_name -> bundle section (mirrors assemble-gks-dicts.py SECTIONS)
TABLE_SECTION = {
    "gks_dict_sequence_reference": "sequenceReference",
    "gks_dict_location": "location",
    "gks_dict_allele": "allele",
    "gks_dict_copy_number_count": "copyNumberCount",
    "gks_dict_copy_number_change": "copyNumberChange",
    "gks_dict_gene": "gene",
    "gks_dict_variation": "variation",
    "gks_dict_condition": "condition",
    "gks_dict_condition_set": "conditionSet",
    "gks_dict_submitter": "submitter",
    "gks_dict_proposition": "proposition",
    "gks_dict_vcv_proposition": "proposition",
    "gks_dict_rcv_proposition": "proposition",
    "gks_dict_evidence_line": "evidenceLine",
    "gks_dict_vcv_evidence_line": "evidenceLine",
    "gks_dict_rcv_evidence_line": "evidenceLine",
    "gks_dict_scv": "scv",
    "gks_dict_vcv": "vcv",
    "gks_dict_rcv": "rcv",
}

# The 3 proposition dicts are delivered as 4 datatype-homogeneous bundle sections (Phase 2), so a
# proposition change-log row maps to a section by its ROW CONTENT, not just its table. Each key encodes
# its type code ({scv}-CODE / accession-...-PROPTYPE-...), so a type change is a new key (A) + old key
# gone (D) — never a group-migrating U — so A/U resolve the group from the CURRENT table and D from the
# BASELINE table. This CASE mirrors export-gks-dicts.sh PROP_GROUP_CASE + assemble SECTIONS.
PROP_TABLES = ("gks_dict_proposition", "gks_dict_vcv_proposition", "gks_dict_rcv_proposition")
GROUP_SECTION_CASE = """CASE
    WHEN COALESCE(JSON_VALUE(p.value,'$.customPropositionType'), JSON_VALUE(p.value,'$.type')) LIKE 'Clinvar%' THEN 'varcustom-proposition'
    WHEN COALESCE(JSON_VALUE(p.value,'$.customPropositionType'), JSON_VALUE(p.value,'$.type')) = 'VariantOncogenicityProposition' THEN 'vartumor-proposition'
    WHEN COALESCE(JSON_VALUE(p.value,'$.customPropositionType'), JSON_VALUE(p.value,'$.type')) = 'VariantTherapeuticResponseProposition' THEN 'vartherapy-proposition'
    WHEN COALESCE(JSON_VALUE(p.value,'$.customPropositionType'), JSON_VALUE(p.value,'$.type')) IN
      ('VariantPathogenicityProposition','VariantClinicalSignificanceProposition','VariantDiagnosticProposition','VariantPrognosticProposition') THEN 'varcond-proposition'
    ELSE ERROR(FORMAT('unmapped proposition type for delivery grouping: %t', COALESCE(JSON_VALUE(p.value,'$.customPropositionType'), JSON_VALUE(p.value,'$.type'))))
  END"""
PROJECT = os.environ.get("CLOUDSDK_CORE_PROJECT", "clingen-dev")


def bq_json(sql):
    out = subprocess.run(
        ["bq", "query", f"--project_id={PROJECT}", "--use_legacy_sql=false",
         "--format=json", "--quiet", "--nouse_cache", sql],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout or "[]")


def main():
    if len(sys.argv) != 4:
        sys.exit("Usage: build-delta-manifest.py <release_date> <dataset_version> <output_path>")
    release, version, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    ds = f"clinvar_{release.replace('-', '_')}_{version}"

    # Derive baseline/compare from schema_on (NOT from change-log rows) so a zero-change
    # release still reports its true baseline instead of a spurious null (which is reserved
    # for the genuine first release, where prev_release_date IS NULL).
    rel = bq_json(
        f"SELECT CAST(release_date AS STRING) AS compare, "
        f"CAST(prev_release_date AS STRING) AS baseline "
        f"FROM `clinvar_ingest.schema_on`(DATE '{release}')"
    )
    compare = rel[0]["compare"] if rel else release
    baseline = rel[0]["baseline"] if rel else None   # null only on the true first release

    # Non-proposition tables: section is fixed by TABLE_SECTION.
    nonprop = [t for t in TABLE_SECTION if t not in PROP_TABLES]
    rows = bq_json(
        f"SELECT table_name, change_type, pk "
        f"FROM `{ds}.gks_change_log` "
        f"WHERE table_name IN ({','.join(repr(t) for t in nonprop)})"
    )

    # Proposition tables: resolve each changed key to its group section by row content.
    # A/U keys exist in the CURRENT tables; D keys exist only in the BASELINE tables.
    prop_in = ",".join(repr(t) for t in PROP_TABLES)
    cur_union = " UNION ALL ".join(
        f"SELECT key, value FROM `{ds}.{t}`" for t in PROP_TABLES)
    prop_sql = (
        f"SELECT cl.change_type, cl.pk, {GROUP_SECTION_CASE} AS section "
        f"FROM `{ds}.gks_change_log` cl JOIN ({cur_union}) p ON p.key = cl.pk "
        f"WHERE cl.table_name IN ({prop_in}) AND cl.change_type IN ('A','U')"
    )
    if baseline:
        base_ds = f"clinvar_{baseline.replace('-', '_')}_{version}"
        base_union = " UNION ALL ".join(
            f"SELECT key, value FROM `{base_ds}.{t}`" for t in PROP_TABLES)
        prop_sql += (
            f" UNION ALL SELECT cl.change_type, cl.pk, {GROUP_SECTION_CASE} AS section "
            f"FROM `{ds}.gks_change_log` cl JOIN ({base_union}) p ON p.key = cl.pk "
            f"WHERE cl.table_name IN ({prop_in}) AND cl.change_type = 'D'"
        )
    prop_rows = bq_json(prop_sql)

    pv = bq_json(f"SELECT ANY_VALUE(audit_stamp) AS a FROM `{ds}.gks_pipeline_version`")
    pipeline_version = pv[0]["a"] if pv and pv[0].get("a") else None

    sections = {}
    for r in ([{"table_name": None, **pr} for pr in prop_rows] + rows):
        sec = r["section"] if r.get("section") else TABLE_SECTION[r["table_name"]]
        s = sections.setdefault(sec, {"added": 0, "updated": 0, "deleted": []})
        ct = r["change_type"]
        if ct == "A":
            s["added"] += 1
        elif ct == "U":
            s["updated"] += 1
        elif ct == "D":
            s["deleted"].append(r["pk"])

    totals = {"A": 0, "U": 0, "D": 0}
    for s in sections.values():
        totals["A"] += s["added"]; totals["U"] += s["updated"]; totals["D"] += len(s["deleted"])

    manifest = {
        "release": release,
        "baseline_release": baseline,   # null only on the genuine first release
        "compare_release": compare,
        "pipeline_version": pipeline_version,
        "checkpoint_full": None,        # filled by the uploader from current R2 monthly state
        "sections": dict(sorted(sections.items())),
        "counts": totals,
    }
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=False)
    print(f"  wrote {out_path}: {totals}")


if __name__ == "__main__":
    main()
