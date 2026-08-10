#!/usr/bin/env python3
"""Build manifest.json for a GKS delta release from {dataset}.gks_change_log.

Usage: build-delta-manifest.py <release_date> <dataset_version> <output_path>
"""
import json
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
PROJECT = "clingen-dev"


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

    rows = bq_json(
        f"SELECT table_name, change_type, pk, "
        f"CAST(baseline_release AS STRING) AS baseline_release, "
        f"CAST(compare_release AS STRING) AS compare_release "
        f"FROM `{ds}.gks_change_log` "
        f"WHERE table_name IN ({','.join(repr(t) for t in TABLE_SECTION)})"
    )

    pv = bq_json(f"SELECT ANY_VALUE(audit_stamp) AS a FROM `{ds}.gks_pipeline_version`")
    pipeline_version = pv[0]["a"] if pv and pv[0].get("a") else None

    baseline = compare = None
    sections = {}
    for r in rows:
        sec = TABLE_SECTION[r["table_name"]]
        s = sections.setdefault(sec, {"added": 0, "updated": 0, "deleted": []})
        ct = r["change_type"]
        if ct == "A":
            s["added"] += 1
        elif ct == "U":
            s["updated"] += 1
        elif ct == "D":
            s["deleted"].append(r["pk"])
        baseline = baseline or r["baseline_release"]
        compare = compare or r["compare_release"]

    totals = {"A": 0, "U": 0, "D": 0}
    for s in sections.values():
        totals["A"] += s["added"]; totals["U"] += s["updated"]; totals["D"] += len(s["deleted"])

    manifest = {
        "release": release,
        "baseline_release": baseline,   # null on the first release
        "compare_release": compare or release,
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
