# Downloads

ClinVar-GKS releases are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

Distribution follows a **full + delta** model:

- The complete **monthly full bundle** — a gzip-compressed JSON file (plus typed Parquet, one file per section) — is published once a month. It contains every variation, statement, proposition, condition, and supporting reference record for that release.
- A **weekly delta** is published for every ClinVar release. Each delta carries only the records that were added or updated since the prior release, in the same section structure as the full bundle, alongside a `manifest.json` that lists per-section adds, updates, and deletes.

A consumer that wants the current state takes the latest monthly full and replays the weekly deltas published since it. See [Weekly Deltas](#weekly-deltas) for the replay model.

---

## Latest Release

Download the most recent full bundle and the most recent weekly delta using the stable URLs below:

| Product | Download | Description |
| --- | --- | --- |
| Monthly full (JSON) | [clinvar-gks_00-latest.json.gz](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz) | Latest monthly full bundle |
| Weekly delta (JSON) | [clinvar-gks-delta_00-latest.json.gz](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/clinvar-gks-delta_00-latest.json.gz) | Latest weekly delta (added + updated records) |
| Delta manifest | [manifest.json](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/manifest.json) | Per-section adds, updates, and deletes for the latest delta |
| Parquet (full) | See [download instructions](#download) | Typed Parquet files (one per bundle section), always latest monthly full |

### Download with curl

```bash
# Latest monthly full bundle (JSON)
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

# Latest weekly delta + its manifest
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/clinvar-gks-delta_00-latest.json.gz
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/deltas/00-latest/manifest.json

# Decompress
gunzip clinvar-gks_00-latest.json.gz

# Download a single Parquet section (e.g., SCV statements)
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/parquet/scv.parquet

# Download all Parquet files
for section in sequenceReference location allele copyNumberCount copyNumberChange \
               gene variation condition conditionSet submitter \
               proposition vcv_proposition rcv_proposition \
               evidenceLine vcv_evidenceLine rcv_evidenceLine \
               scv vcv rcv; do
  curl -O "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/parquet/${section}.parquet"
done
```

### Download with Python

```python
import urllib.request

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# Download latest monthly full bundle
urllib.request.urlretrieve(
    f"{BASE}/datasets/clinvar-gks_00-latest.json.gz",
    "clinvar-gks_00-latest.json.gz"
)

# Download a specific monthly full bundle
urllib.request.urlretrieve(
    f"{BASE}/datasets/clinvar-gks_2026-06.json.gz",
    "clinvar-gks_2026-06.json.gz"
)

# Download the latest weekly delta + manifest
urllib.request.urlretrieve(
    f"{BASE}/deltas/00-latest/clinvar-gks-delta_00-latest.json.gz",
    "clinvar-gks-delta_00-latest.json.gz"
)
urllib.request.urlretrieve(
    f"{BASE}/deltas/00-latest/manifest.json",
    "manifest.json"
)

# Download a specific weekly delta (release 2026-07-06 -> dir 2026-0706)
urllib.request.urlretrieve(
    f"{BASE}/deltas/2026-0706/clinvar-gks-delta_2026-0706.json.gz",
    "clinvar-gks-delta_2026-0706.json.gz"
)

# Download an archived full bundle from a prior year
urllib.request.urlretrieve(
    f"{BASE}/archives/2025/clinvar-gks_2025-03.json.gz",
    "clinvar-gks_2025-03.json.gz"
)

# Download a Parquet section from the monthly full
urllib.request.urlretrieve(
    f"{BASE}/datasets/parquet/scv.parquet",
    "scv.parquet"
)
```

---

## Weekly Deltas

A weekly delta is published for every ClinVar release under `deltas/<YYYY-MMDD>/`. Each release directory contains three artifact kinds:

```text
deltas/2026-0706/
  clinvar-gks-delta_2026-0706.json.gz   added + updated records (same section structure as the full bundle)
  manifest.json                         per-section adds, updates, and deletes for this release
  parquet/<section>.parquet             typed Parquet for the changed records only
```

The most recent delta is mirrored at `deltas/00-latest/` under stable filenames (`clinvar-gks-delta_00-latest.json.gz`, `manifest.json`, `parquet/<section>.parquet`).

### Delta Bundle

The delta bundle has the **same shape as the monthly full** — a single JSON object with bundle sections at the root, each a keyed collection of objects. The difference is content: a delta contains only the records **added or updated** since its baseline release. Sections with no additions or updates are absent from the delta bundle. **Deleted records are not present in the bundle** — they are listed only in the manifest.

### manifest.json

The manifest describes exactly what changed and which full bundle the delta chain roots at:

```json
{
  "release": "2026-07-06",
  "baseline_release": "2026-06-29",
  "compare_release": "2026-07-06",
  "pipeline_version": "clinvar-gks vX.Y.Z @ 2026-07-06T00:00:00Z",
  "checkpoint_full": { "path": "datasets/clinvar-gks_2026-06.json.gz", "release": "2026-06" },
  "sections": {
    "allele":  { "added": 812,  "updated": 34,  "deleted": ["ga4gh:VA.oldDigest1"] },
    "scv":     { "added": 1203, "updated": 517, "deleted": ["clinvar.submission:SCV000000001.1"] },
    "vcv":     { "added": 44,   "updated": 96,  "deleted": [] }
  },
  "counts": { "A": 2063, "U": 647, "D": 2 }
}
```

| Field | Description |
| --- | --- |
| `release` | The ClinVar release date this delta represents |
| `baseline_release` | The prior release this delta was diffed against — `null` only on the very first release |
| `compare_release` | The release the changes are computed to (equals `release`) |
| `pipeline_version` | The pipeline build stamp that produced the delta |
| `checkpoint_full` | The monthly full bundle this delta chain replays onto — `{path, release}`; `null` before the first monthly full is published |
| `sections` | Per-section change summary — `added` and `updated` counts plus a `deleted` list of primary keys |
| `counts` | Roll-up totals across all sections — `A` (added), `U` (updated), `D` (deleted) |

**Deletes live only in the manifest.** For each section, `deleted` is the list of keys that must be removed; the delta bundle itself carries only the added and updated records.

### Consumer Replay Model

To reconstruct the current state, bootstrap from the monthly full that the latest delta's manifest names in `checkpoint_full`, then replay the contiguous weekly deltas published after it. For each delta, apply the manifest's deletes first, then upsert every record present in the delta bundle — section by section.

`checkpoint_full` tells you *which* monthly full to start from (`{path, release}`, where `release` is the `YYYY-MM` of the full). Replay only the deltas from later months — the deltas within the checkpoint's own month are already reflected in the monthly full. Verify chain integrity as you replay: each delta's `baseline_release` must equal the previous delta's `compare_release`. A mismatch means a weekly release is missing from the chain — re-bootstrap from the monthly full rather than applying a partial chain.

```python
import gzip
import json
import urllib.request

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"


def fetch_json(url):
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def fetch_json_gz(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(gzip.decompress(r.read()))


# 1. The latest delta's manifest names the monthly full to bootstrap from.
latest = fetch_json(f"{BASE}/deltas/00-latest/manifest.json")
checkpoint = latest["checkpoint_full"]        # {"path": "datasets/clinvar-gks_2026-06.json.gz",
                                              #  "release": "2026-06"}  (None on initial rollout,
                                              #  before any monthly full exists)

# 2. Load that monthly full as the baseline state: {section: {key: record}}.
state = fetch_json_gz(f"{BASE}/{checkpoint['path']}")
checkpoint_month = checkpoint["release"]      # "2026-06"

# 3. From the index, take the dated weekly deltas published AFTER the checkpoint month,
#    oldest -> newest. (A delta dir is named YYYY-MMDD packed as "2026-0706", so the first
#    7 chars are its YYYY-MM.) Skip the "latest" mirror and any delta in the checkpoint
#    month or earlier — those are already folded into the monthly full.
index = fetch_json(f"{BASE}/index.json")
deltas = sorted(
    (d for d in index["deltas"]
     if d["release"] != "latest" and d["release"][:7] > checkpoint_month),
    key=lambda d: d["release"],
)

# 4. Replay each delta onto the baseline, verifying the chain as we go.
prev_compare = None
for d in deltas:
    manifest = fetch_json(f"{BASE}/{d['manifest']}")

    # Chain check: after the first, each delta must build on the previous compare_release.
    # The first delta builds on the checkpoint month's final release. A mismatch => a
    # missing week; re-bootstrap from the monthly full.
    if prev_compare is not None and manifest["baseline_release"] != prev_compare:
        raise SystemExit(
            f"broken chain before {manifest['release']}: re-bootstrap from a monthly full"
        )

    dirname = d["path"].strip("/").split("/")[-1]            # "2026-0706"
    delta = fetch_json_gz(f"{BASE}/{d['path']}clinvar-gks-delta_{dirname}.json.gz")

    # 4a. Apply deletes (manifest only), then 4b. upsert added + updated records.
    for section, info in manifest["sections"].items():
        target = state.setdefault(section, {})
        for pk in info["deleted"]:
            target.pop(pk, None)
    for section, records in delta.items():
        state.setdefault(section, {}).update(records)

    prev_compare = manifest["compare_release"]

# `state` now reflects the most recent weekly release.
```

---

## Browse All Releases

The file browser below shows all available releases — monthly full bundles, weekly deltas, and archives. It is populated from the release index and updated automatically with each weekly delta and monthly full upload.

<div id="r2-browser" markdown>

<noscript>

JavaScript is required to browse releases interactively. You can fetch the release index directly:

```bash
curl -s https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/index.json | python3 -m json.tool
```

</noscript>

<p id="r2-loading" style="color: var(--md-default-fg-color--light); font-style: italic;">Loading release index...</p>
<div id="r2-error" style="display: none; padding: 0.8rem; border-left: 3px solid var(--md-accent-fg-color); margin: 1rem 0;"></div>
<div id="r2-tree" style="display: none;"></div>

</div>

<style>
#r2-tree { font-family: var(--md-code-font-family); font-size: 0.82rem; line-height: 1.6; }
.r2-folder { margin: 0; padding: 0; }
.r2-folder > summary {
  cursor: pointer; font-weight: 600; padding: 0.15rem 0;
  color: var(--md-default-fg-color);
  list-style: none;
}
.r2-folder > summary::before {
  content: "\25b8 "; color: var(--md-default-fg-color--light);
}
.r2-folder[open] > summary::before {
  content: "\25be ";
}
.r2-group { padding-left: 1.2rem; border-left: 1px solid var(--md-default-fg-color--lightest); margin-left: 0.4rem; }
.r2-file { padding: 0.1rem 0 0.1rem 0.4rem; }
.r2-file a { text-decoration: none; color: var(--md-typeset-a-color); }
.r2-file a:hover { text-decoration: underline; }
.r2-size { color: var(--md-default-fg-color--light); font-size: 0.75rem; margin-left: 0.5rem; }
.r2-badge {
  display: inline-block; font-size: 0.68rem; padding: 0.05rem 0.35rem;
  border-radius: 3px; margin-left: 0.4rem; vertical-align: middle;
  background: var(--md-accent-fg-color); color: var(--md-accent-bg-color);
}
.r2-section { margin-bottom: 1.5rem; }
.r2-section-title { font-weight: 700; font-size: 0.95rem; margin-bottom: 0.4rem; border-bottom: 1px solid var(--md-default-fg-color--lightest); padding-bottom: 0.2rem; }
</style>

<script>
(function() {
  var INDEX_URL = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/index.json";
  var BASE_URL = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev";

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function(k) {
      if (k === "text") e.textContent = attrs[k];
      else if (k === "html") e.innerHTML = attrs[k];
      else if (k === "className") e.className = attrs[k];
      else if (k === "style") Object.assign(e.style, attrs[k]);
      else e.setAttribute(k, attrs[k]);
    });
    if (children) children.forEach(function(c) { if (c) e.appendChild(c); });
    return e;
  }

  function formatSize(bytes) {
    if (!bytes) return "";
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MB";
    return (bytes / 1073741824).toFixed(2) + " GB";
  }

  function renderFile(file) {
    var div = el("div", {className: "r2-file"});
    var url = BASE_URL + "/" + file.path;
    div.appendChild(el("a", {href: url, text: file.name}));
    if (file.size) {
      div.appendChild(el("span", {className: "r2-size", text: formatSize(file.size)}));
    }
    if (file.latest) {
      div.appendChild(el("span", {className: "r2-badge", text: "latest"}));
    }
    return div;
  }

  function renderFileGroup(label, files, open) {
    if (!files || files.length === 0) return null;
    var folder = el("details", {className: "r2-folder"});
    if (open) folder.setAttribute("open", "");
    folder.appendChild(el("summary", {text: label}));
    var group = el("div", {className: "r2-group"});
    files.forEach(function(f) { group.appendChild(renderFile(f)); });
    folder.appendChild(group);
    return folder;
  }

  function renderDelta(d) {
    var div = el("div", {className: "r2-file"});
    var dirname = d.path.replace(/^deltas\//, "").replace(/\/$/, "");
    var bundleUrl = BASE_URL + "/" + d.path + "clinvar-gks-delta_" + dirname + ".json.gz";
    div.appendChild(el("a", {href: bundleUrl, text: dirname}));
    div.appendChild(el("span", {className: "r2-size"}, [
      el("a", {href: BASE_URL + "/" + d.manifest, text: "manifest.json"})
    ]));
    if (d.latest) {
      div.appendChild(el("span", {className: "r2-badge", text: "latest"}));
    }
    return div;
  }

  function renderDeltaGroup(label, deltas, open) {
    if (!deltas || deltas.length === 0) return null;
    var folder = el("details", {className: "r2-folder"});
    if (open) folder.setAttribute("open", "");
    folder.appendChild(el("summary", {text: label}));
    var group = el("div", {className: "r2-group"});
    deltas.forEach(function(d) { group.appendChild(renderDelta(d)); });
    folder.appendChild(group);
    return folder;
  }

  function buildTree(data) {
    var container = document.getElementById("r2-tree");
    var datasets = data.datasets || {};
    var archives = data.archives || {};
    var hasContent = false;

    // Monthly full bundles
    if (datasets.monthly && datasets.monthly.length) {
      hasContent = true;
      var section = el("div", {className: "r2-section"});
      section.appendChild(el("div", {className: "r2-section-title", text: "Monthly Full Bundles"}));

      var mGroup = renderFileGroup("datasets/", datasets.monthly, true);
      if (mGroup) section.appendChild(mGroup);

      container.appendChild(section);
    }

    // Weekly deltas — each entry links to its delta bundle and manifest
    var deltas = (data.deltas || []).slice().sort(function(a, b) {
      if (a.release === "latest") return -1;
      if (b.release === "latest") return 1;
      return b.release.localeCompare(a.release);
    });
    if (deltas.length) {
      hasContent = true;
      var dSection = el("div", {className: "r2-section"});
      dSection.appendChild(el("div", {className: "r2-section-title", text: "Weekly Deltas"}));
      var dGroup = renderDeltaGroup("deltas/", deltas, true);
      if (dGroup) dSection.appendChild(dGroup);
      container.appendChild(dSection);
    }

    // Parquet files (static list — always the same 19 sections at fixed paths)
    var parquetSections = [
      "sequenceReference", "location", "allele", "copyNumberCount", "copyNumberChange",
      "gene", "variation", "condition", "conditionSet", "submitter",
      "proposition", "vcv_proposition", "rcv_proposition",
      "evidenceLine", "vcv_evidenceLine", "rcv_evidenceLine",
      "scv", "vcv", "rcv"
    ];
    var parquetFiles = parquetSections.map(function(s) {
      return {name: s + ".parquet", path: "datasets/parquet/" + s + ".parquet"};
    });
    hasContent = true;
    var pSection = el("div", {className: "r2-section"});
    pSection.appendChild(el("div", {className: "r2-section-title", text: "Parquet Files"}));
    var pGroup = renderFileGroup("datasets/parquet/", parquetFiles, false);
    if (pGroup) pSection.appendChild(pGroup);
    container.appendChild(pSection);

    // Archives by year
    var years = Object.keys(archives).sort().reverse();
    if (years.length > 0) {
      hasContent = true;
      var aSection = el("div", {className: "r2-section"});
      aSection.appendChild(el("div", {className: "r2-section-title", text: "Archived Releases"}));

      years.forEach(function(year, i) {
        var yearData = archives[year];
        var yearFolder = el("details", {className: "r2-folder"});
        if (i === 0) yearFolder.setAttribute("open", "");
        yearFolder.appendChild(el("summary", {text: year}));

        var yGroup = el("div", {className: "r2-group"});
        var mGroup = renderFileGroup("Monthly", yearData.monthly, i === 0);
        if (mGroup) yGroup.appendChild(mGroup);
        yearFolder.appendChild(yGroup);

        aSection.appendChild(yearFolder);
      });

      container.appendChild(aSection);
    }

    if (!hasContent) {
      container.innerHTML = "<p>No releases found in the index.</p>";
    }

    container.style.display = "block";
  }

  fetch(INDEX_URL)
    .then(function(r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function(data) {
      document.getElementById("r2-loading").style.display = "none";
      buildTree(data);
    })
    .catch(function(err) {
      document.getElementById("r2-loading").style.display = "none";
      var errDiv = document.getElementById("r2-error");
      errDiv.style.display = "block";
      errDiv.textContent = "Unable to load release index. The file browser will be available once the first index.json is published. Use the download links above to access releases directly. (" + err.message + ")";
    });
})();
</script>

---

## Directory Structure

```text
datasets/
  clinvar-gks_00-latest.json.gz              latest monthly full bundle (stable URL)
  clinvar-gks_YYYY-MM.json.gz                monthly full bundles (current year)

datasets/parquet/
  {section}.parquet                          typed Parquet for the latest monthly full

deltas/00-latest/
  clinvar-gks-delta_00-latest.json.gz        latest weekly delta bundle (stable URL)
  manifest.json                              latest delta manifest
  parquet/{section}.parquet                  typed Parquet for the latest delta

deltas/YYYY-MMDD/
  clinvar-gks-delta_YYYY-MMDD.json.gz        weekly delta bundle (added + updated records)
  manifest.json                              per-release change manifest
  parquet/{section}.parquet                  typed Parquet for the changed records

archives/{YYYY}/
  clinvar-gks_YYYY-MM.json.gz                monthly full bundles from prior years

index.json                                   release index (datasets, archives, deltas)
```

---

## Parquet Files

Typed Parquet files are produced alongside each release and uploaded to `datasets/parquet/`. Unlike JSON bundles, Parquet files are not versioned — they are overwritten on each release and always represent the latest data.

Each Parquet file contains one bundle section with typed, query-friendly columns extracted from the JSON objects. Every section includes an `id` column (the object identifier) and a `data` column (the full JSON object as a string), plus additional typed columns for key fields — enabling efficient filtering and aggregation without parsing JSON.

Available Parquet files (19 sections):

| File | Description |
| --- | --- |
| `sequenceReference.parquet` | NCBI RefSeq sequence references |
| `location.parquet` | VRS SequenceLocation records |
| `allele.parquet` | VRS Allele records |
| `copyNumberCount.parquet` | VRS CopyNumberCount records |
| `copyNumberChange.parquet` | VRS CopyNumberChange records |
| `gene.parquet` | Gene records (MappableConcept with NCBI Gene / HGNC codings) |
| `variation.parquet` | CategoricalVariant records (Cat-VRS) |
| `condition.parquet` | Condition records (traits) |
| `conditionSet.parquet` | ConditionSet records (trait sets) |
| `submitter.parquet` | Submitter organization records |
| `proposition.parquet` | SCV proposition records |
| `vcv_proposition.parquet` | VCV proposition records |
| `rcv_proposition.parquet` | RCV proposition records |
| `evidenceLine.parquet` | SCV evidence line records |
| `vcv_evidenceLine.parquet` | VCV evidence line records |
| `rcv_evidenceLine.parquet` | RCV evidence line records |
| `scv.parquet` | SCV statement records |
| `vcv.parquet` | VCV aggregate statement records |
| `rcv.parquet` | RCV aggregate statement records |

### Working with Parquet Files

Download the Parquet files you need, then query them locally. The R2 hosting has rate limits and is designed for file downloads, not as a remote query endpoint for tools like DuckDB.

#### Download

Download individual sections or all files at once:

```bash
BASE="https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/parquet"
mkdir -p clinvar-gks-parquet && cd clinvar-gks-parquet

# Download specific sections
curl -O "${BASE}/scv.parquet"
curl -O "${BASE}/proposition.parquet"
curl -O "${BASE}/condition.parquet"

# Or download all 19 sections
for section in sequenceReference location allele copyNumberCount copyNumberChange \
               gene variation condition conditionSet submitter \
               proposition vcv_proposition rcv_proposition \
               evidenceLine vcv_evidenceLine rcv_evidenceLine \
               scv vcv rcv; do
  curl -O "${BASE}/${section}.parquet"
done
```

#### DuckDB

[DuckDB](https://duckdb.org/) is the fastest way to explore Parquet files — it queries them directly with no data loading step.

```bash
# Install DuckDB
brew install duckdb   # macOS
# or: pip install duckdb
```

```bash
# Query SCV statements
duckdb -c "
  SELECT id, classification, direction, strength, confidence
  FROM 'scv.parquet'
  WHERE classification = 'Pathogenic'
  LIMIT 10;
"
```

```bash
# Count classifications across all SCVs
duckdb -c "
  SELECT classification, direction, COUNT(*) as n
  FROM 'scv.parquet'
  GROUP BY classification, direction
  ORDER BY n DESC;
"
```

```bash
# Join SCVs with propositions to find pathogenic variants for a specific condition
duckdb -c "
  SELECT s.id, s.classification, p.predicate, p.object_condition
  FROM 'scv.parquet' s
  JOIN 'proposition.parquet' p ON s.proposition_id = p.id
  WHERE s.classification = 'Pathogenic'
    AND p.object_condition LIKE '%clinvar.trait:9580%'
  LIMIT 10;
"
```

```bash
# Inspect the schema of any section
duckdb -c "DESCRIBE SELECT * FROM 'scv.parquet';"
```

DuckDB also works from Python:

```python
import duckdb

df = duckdb.sql("""
    SELECT id, classification, direction, strength, confidence
    FROM 'scv.parquet'
    WHERE classification = 'Pathogenic'
    LIMIT 100
""").df()

print(df)
```

#### pandas / pyarrow

```python
import pandas as pd

# Load a section into a DataFrame
scv = pd.read_parquet("scv.parquet")

# Filter pathogenic SCVs
pathogenic = scv[scv["classification"] == "Pathogenic"]
print(f"{len(pathogenic)} pathogenic SCVs")

# Access the full JSON when you need nested fields
import json
record = json.loads(pathogenic.iloc[0]["data"])
print(record["proposition"])
```

#### Column Reference

Statement sections (`scv`, `vcv`, `rcv`) share a common set of typed columns:

| Column | Type | Description |
| --- | --- | --- |
| `id` | string | Statement identifier |
| `type` | string | Statement type |
| `proposition_id` | string | FK to proposition Parquet (`proposition` for SCV, `vcv_proposition` for VCV, `rcv_proposition` for RCV) |
| `classification` | string | Classification label (e.g., "Pathogenic") |
| `strength` | string | Evidence strength (e.g., "definitive", "likely") |
| `direction` | string | Evidence direction ("supports", "disputes", "neutral") |
| `confidence` | string | Submission level label (e.g., "criteria provided") |
| `has_evidence_lines` | list\<string\> | FK references to evidence line Parquet (`evidenceLine` for SCV, `vcv_evidenceLine` for VCV, `rcv_evidenceLine` for RCV) |
| `extensions` | string | JSON array of extensions |
| `data` | string | Full JSON object |

SCV statements include additional columns: `description`, `contributions`, `reported_in`, `specified_by`.

The `proposition` section includes `subject_variant`, `predicate`, `object_condition`, `object_condition_set`, `type`, and qualifier columns — enabling JOINs across statements, variants, and conditions without parsing JSON.

Every section includes `id` and `data` at minimum. Run `DESCRIBE` in DuckDB to see the full schema for any section.

#### Example Queries

These examples demonstrate cross-section JOINs using typed columns. Most analytical queries can be answered without parsing JSON — the proposition's `gene_context_qualifier` struct carries the gene symbol and NCBI Gene ID directly, and the condition's `primary_coding` struct carries the MedGen code.

**All SCVs for a gene — detailed view:**

```sql
-- SCVs for BRCA1: classification, review status, condition
SELECT
    s.id AS scv_id,
    s.classification,
    s.direction,
    s.strength,
    s.confidence AS review_status,
    p.gene_context_qualifier.name AS gene,
    c.name AS condition_name,
    c.primary_coding.code AS condition_code
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
LEFT JOIN 'condition.parquet' c ON p.object_condition = c.id
WHERE p.gene_context_qualifier.name = 'BRCA1'
ORDER BY s.classification;
```

**Classification summary for a gene:**

```sql
-- Count SCVs by classification and review status for BRCA2
SELECT
    p.gene_context_qualifier.name AS gene,
    s.classification,
    s.confidence AS review_status,
    s.direction,
    COUNT(*) AS scv_count
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
WHERE p.gene_context_qualifier.name = 'BRCA2'
GROUP BY ALL
ORDER BY scv_count DESC;
```

**Restrict to submissions with criteria provided:**

```sql
-- Only expert panel and criteria-provided SCVs for a gene
SELECT
    s.id AS scv_id,
    s.classification,
    s.confidence AS review_status,
    c.name AS condition_name
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
LEFT JOIN 'condition.parquet' c ON p.object_condition = c.id
WHERE p.gene_context_qualifier.name = 'TP53'
  AND s.confidence IN ('criteria provided', 'reviewed by expert panel')
ORDER BY s.classification;
```

**Cross-gene comparison — classification breakdown for multiple genes:**

```sql
-- Compare pathogenicity classification distributions across genes
SELECT
    p.gene_context_qualifier.name AS gene,
    s.classification,
    COUNT(*) AS n
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
WHERE p.gene_context_qualifier.name IN ('BRCA1', 'BRCA2', 'TP53', 'MLH1')
  AND s.confidence = 'criteria provided'
GROUP BY gene, s.classification
ORDER BY gene, n DESC;
```

**Accessing fields not in typed columns:**

Some fields — like submitter names, HGVS expressions, and assertion methods — are only available in the `data` column (full JSON string). Use DuckDB's `json_extract_string` to access them:

```sql
-- SCVs with submitter name and assertion method (from JSON)
SELECT
    s.id AS scv_id,
    s.classification,
    p.gene_context_qualifier.name AS gene,
    json_extract_string(s.data, '$.contributions[0].agent.name') AS submitter,
    json_extract_string(s.data, '$.specifiedBy.name') AS method
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
WHERE p.gene_context_qualifier.name = 'BRCA1'
  AND s.classification = 'Pathogenic'
  AND s.confidence = 'reviewed by expert panel'
LIMIT 20;
```

**Summary:**

| Approach | Best for | Tradeoff |
| --- | --- | --- |
| Typed columns only | Filtering, counting, grouping, JOINs on classification, gene, condition, review status | Fast; covers most analytical questions |
| Typed columns + `json_extract_string` | Ad-hoc queries needing submitter names, HGVS, methods | Slightly slower; syntax is verbose |
| Parse `data` column in application code | Bulk processing needing many nested fields | Full flexibility; requires application-side JSON parsing |

---

## Release Cadence

A **weekly delta** is published for every ClinVar release, typically within 1-2 days of each ClinVar XML release. Each delta lands under `deltas/<YYYY-MMDD>/` and is mirrored at `deltas/00-latest/`.

A **monthly full bundle** is published once a month. The full for a given month corresponds to the last release of that month and is published retroactively — when the first release of the next month runs. That upload writes `datasets/clinvar-gks_YYYY-MM.json.gz` and updates the `datasets/clinvar-gks_00-latest.json.gz` pointer along with `datasets/parquet/`. Each delta manifest's `checkpoint_full` records which monthly full its chain replays onto.

At year boundaries, the prior year's monthly full bundles are moved to `archives/{YYYY}/`. All monthly archives are retained indefinitely.

There is no weekly full bundle — weekly changes are distributed as deltas only. Consumers that need the full weekly state reconstruct it by replaying deltas onto the latest monthly full, as shown in [Consumer Replay Model](#consumer-replay-model).

---

## Feedback

This project is in active development and we welcome community feedback. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date and specific records involved
