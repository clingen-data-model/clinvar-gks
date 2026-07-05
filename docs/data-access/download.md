# Downloads

ClinVar-GKS releases are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

Each release includes a gzip-compressed JSON bundle file containing all variations, statements, propositions, conditions, and supporting reference data for a ClinVar release. Typed Parquet files (one per bundle section) are also available for analytical workloads.

---

## Latest Release

Download the most recent releases using the stable URLs below:

| Format | Download | Description |
| --- | --- | --- |
| Monthly (JSON) | [clinvar-gks_00-latest.json.gz](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz) | Latest monthly release (first weekly of each month) |
| Weekly (JSON) | [clinvar-gks_00-latest_weekly.json.gz](https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz) | Latest weekly release |
| Parquet | See [download instructions](#download) | Typed Parquet files (one per bundle section), always latest release |

### Download with curl

```bash
# Latest monthly release (JSON bundle)
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

# Latest weekly release (JSON bundle)
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz

# Decompress
gunzip clinvar-gks_00-latest.json.gz

# Download a single Parquet section (e.g., SCV statements)
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/parquet/scv.parquet

# Download all Parquet files
for section in sequenceReference location allele copyNumberCount copyNumberChange \
               gene variation condition conditionSet submitter proposition \
               evidenceLine scv vcv rcv; do
  curl -O "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/parquet/${section}.parquet"
done
```

### Download with Python

```python
import urllib.request

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# Download latest monthly release
urllib.request.urlretrieve(
    f"{BASE}/datasets/clinvar-gks_00-latest.json.gz",
    "clinvar-gks_00-latest.json.gz"
)

# Download a specific monthly release
urllib.request.urlretrieve(
    f"{BASE}/datasets/clinvar-gks_2026-06.json.gz",
    "clinvar-gks_2026-06.json.gz"
)

# Download a specific weekly release
urllib.request.urlretrieve(
    f"{BASE}/datasets/weekly/clinvar-gks_2026-0614.json.gz",
    "clinvar-gks_2026-0614.json.gz"
)

# Download an archived release from a prior year
urllib.request.urlretrieve(
    f"{BASE}/archives/2025/clinvar-gks_2025-03.json.gz",
    "clinvar-gks_2025-03.json.gz"
)

# Download a Parquet section
urllib.request.urlretrieve(
    f"{BASE}/datasets/parquet/scv.parquet",
    "scv.parquet"
)
```

---

## Browse All Releases

The file browser below shows all available releases organized by year and month. It is populated from the release index and updated automatically with each weekly upload.

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

  function buildTree(data) {
    var container = document.getElementById("r2-tree");
    var datasets = data.datasets || {};
    var archives = data.archives || {};
    var hasContent = false;

    // Current releases
    if ((datasets.monthly && datasets.monthly.length) || (datasets.weekly && datasets.weekly.length)) {
      hasContent = true;
      var section = el("div", {className: "r2-section"});
      section.appendChild(el("div", {className: "r2-section-title", text: "Current Releases"}));

      var mGroup = renderFileGroup("Monthly", datasets.monthly, true);
      if (mGroup) section.appendChild(mGroup);

      var wGroup = renderFileGroup("Weekly", datasets.weekly, true);
      if (wGroup) section.appendChild(wGroup);

      container.appendChild(section);
    }

    // Parquet files (static list — always the same 15 sections at fixed paths)
    var parquetSections = [
      "sequenceReference", "location", "allele", "copyNumberCount", "copyNumberChange",
      "gene", "variation", "condition", "conditionSet", "submitter",
      "proposition", "evidenceLine", "scv", "vcv", "rcv"
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
  clinvar-gks_00-latest.json.gz         latest monthly release (stable URL)
  clinvar-gks_YYYY-MM.json.gz           monthly releases (current year)

datasets/weekly/
  clinvar-gks_00-latest_weekly.json.gz  latest weekly release (stable URL)
  clinvar-gks_YYYY-MMDD.json.gz         weekly releases (current month only)

datasets/parquet/
  {section}.parquet                     typed Parquet files (always latest release)

archives/{YYYY}/
  clinvar-gks_YYYY-MM.json.gz           monthly releases from prior years
```

---

## Parquet Files

Typed Parquet files are produced alongside each release and uploaded to `datasets/parquet/`. Unlike JSON bundles, Parquet files are not versioned — they are overwritten on each release and always represent the latest data.

Each Parquet file contains one bundle section with typed, query-friendly columns extracted from the JSON objects. Every section includes an `id` column (the object identifier) and a `data` column (the full JSON object as a string), plus additional typed columns for key fields — enabling efficient filtering and aggregation without parsing JSON.

Available Parquet files (15 sections):

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
| `proposition.parquet` | Proposition records (SCV, VCV, and RCV) |
| `evidenceLine.parquet` | Evidence line records (SCV, VCV, and RCV) |
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

# Or download all 15 sections
for section in sequenceReference location allele copyNumberCount copyNumberChange \
               gene variation condition conditionSet submitter proposition \
               evidenceLine scv vcv rcv; do
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
| `proposition_id` | string | FK to `proposition.parquet` |
| `classification` | string | Classification label (e.g., "Pathogenic") |
| `strength` | string | Evidence strength (e.g., "definitive", "likely") |
| `direction` | string | Evidence direction ("supports", "disputes", "neutral") |
| `confidence` | string | Submission level label (e.g., "criteria provided") |
| `has_evidence_lines` | list\<string\> | FK references to `evidenceLine.parquet` |
| `extensions` | string | JSON array of extensions |
| `data` | string | Full JSON object |

SCV statements include additional columns: `description`, `contributions`, `reported_in`, `specified_by`.

The `proposition` section includes `subject_variant`, `predicate`, `object_condition`, `object_condition_set`, `type`, and qualifier columns — enabling JOINs across statements, variants, and conditions without parsing JSON.

Every section includes `id` and `data` at minimum. Run `DESCRIBE` in DuckDB to see the full schema for any section.

#### Joining Parquet Sections

The typed columns make cross-section JOINs fast and readable — most analytical queries can be answered without parsing JSON. However, some data is only available in the `data` column (the full JSON string), which requires JSON extraction functions.

**What typed columns give you:** Efficient filtering, grouping, and JOINs on the most commonly queried fields. The query below finds all pathogenic SCVs for a specific gene, joining three sections purely on typed columns:

```sql
-- All pathogenic SCVs for BRCA1, with submitter and condition
SELECT
    s.id AS scv_id,
    s.classification,
    s.direction,
    s.confidence,
    p.predicate,
    p.object_condition AS condition_id
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
WHERE s.classification = 'Pathogenic'
  AND p.subject_variant = 'clinvar:17661';
```

**Where you hit limits:** Fields like condition names, submitter names, gene symbols, HGVS expressions, and extension values are not extracted into typed columns — they live inside the `data` JSON string. To access them, use DuckDB's `json_extract_string`:

```sql
-- Same query but with condition name and submitter name resolved
SELECT
    s.id AS scv_id,
    s.classification,
    json_extract_string(c.data, '$.name') AS condition_name,
    json_extract_string(s.data, '$.contributions[0].agent.name') AS submitter
FROM 'scv.parquet' s
JOIN 'proposition.parquet' p ON s.proposition_id = p.id
JOIN 'condition.parquet' c ON p.object_condition = c.id
WHERE s.classification = 'Pathogenic'
  AND p.subject_variant = 'clinvar:17661';
```

JSON extraction is slower than typed column access, but DuckDB handles it efficiently for analytical queries. For bulk processing where you need many nested fields, load the `data` column into your application and parse the full JSON objects there.

**Summary:**

| Approach | Best for | Tradeoff |
| --- | --- | --- |
| Typed columns only | Filtering, counting, grouping, JOINs | Fast, but limited to extracted fields |
| Typed columns + `json_extract_string` | Ad-hoc exploration needing a few nested fields | Slightly slower; syntax is verbose |
| Parse `data` column in application code | Bulk processing needing many nested fields | Full flexibility; requires application-side JSON parsing |

---

## Release Cadence

New releases are published weekly, typically within 1-2 days of each ClinVar XML release.

**Monthly releases** represent the most current data available at the start of each month. When the first release of a new month is uploaded, the previous month's final weekly release is promoted as that new month's official monthly release and the `00-latest` pointer is updated. Weekly releases within a month do not affect the monthly release or latest pointer.

At month boundaries, the prior month's weekly files are deleted — only the current month's weeklies are retained in `datasets/weekly/`. At year boundaries, the prior year's monthly files are moved to `archives/{YYYY}/`. All monthly archives are retained indefinitely.

---

## Feedback

This project is in active development and we welcome community feedback. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date and specific records involved
