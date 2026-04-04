# Downloads

!!! warning "Early Adopter Release"
    ClinVar-GKS datasets are in an **early adopter** phase. Data structures and
    output formats may change as we incorporate community feedback and align with
    evolving GA4GH GKS specifications. Please report issues and suggestions via
    the [GitHub issue tracker](https://github.com/clingen-data-model/clinvar-gks/issues).

ClinVar-GKS datasets are hosted on Cloudflare R2 object storage. All downloads are free with no authentication required and no egress fees.

---

## Latest Release

The `current/` directory always contains the most recent weekly release with stable filenames:

| Dataset | URL |
| --- | --- |
| Categorical Variants | `https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar_gks_variation.jsonl.gz` |
| SCV Statements | `https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar_gks_scv_by_ref.jsonl.gz` |
| Release Manifest | `https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/manifest.json` |

The `manifest.json` file contains metadata about the current release — release date, schema version, and the list of published files.

### Download with curl

```bash
# Download latest categorical variants
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar_gks_variation.jsonl.gz

# Download latest SCV statements
curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/clinvar_gks_scv_by_ref.jsonl.gz

# Check which release is current
curl -s https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/current/manifest.json | python3 -m json.tool
```

### Download with Python

```python
import urllib.request, json

BASE = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev"

# Check current release metadata
with urllib.request.urlopen(f"{BASE}/current/manifest.json") as r:
    manifest = json.loads(r.read())
    print(f"Release: {manifest['release_date']} ({manifest['schema_version']})")

# Download a dataset
urllib.request.urlretrieve(
    f"{BASE}/current/clinvar_gks_variation.jsonl.gz",
    "clinvar_gks_variation.jsonl.gz"
)
```

---

## Browse All Releases

The file browser below is populated from the release index and updated automatically with each weekly upload.

<div id="r2-browser" markdown>

<noscript>

JavaScript is required to browse releases interactively. Use the release index directly:

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
.r2-year, .r2-month { margin: 0; padding: 0; }
.r2-year > summary, .r2-month > summary {
  cursor: pointer; font-weight: 600; padding: 0.15rem 0;
  color: var(--md-default-fg-color);
  list-style: none;
}
.r2-year > summary::before, .r2-month > summary::before {
  content: "▸ "; color: var(--md-default-fg-color--light);
}
.r2-year[open] > summary::before, .r2-month[open] > summary::before {
  content: "▾ ";
}
.r2-release { padding: 0.2rem 0 0.2rem 1.2rem; border-left: 1px solid var(--md-default-fg-color--lightest); margin-left: 0.4rem; }
.r2-release-header { font-weight: 600; color: var(--md-default-fg-color); margin-bottom: 0.15rem; }
.r2-file { padding-left: 1.2rem; }
.r2-file a { text-decoration: none; color: var(--md-typeset-a-color); }
.r2-file a:hover { text-decoration: underline; }
.r2-badge {
  display: inline-block; font-size: 0.7rem; padding: 0.05rem 0.35rem;
  border-radius: 3px; margin-left: 0.4rem; vertical-align: middle;
  background: var(--md-accent-fg-color); color: var(--md-accent-bg-color);
}
.r2-current { margin-bottom: 1.5rem; padding: 0.8rem; border: 1px solid var(--md-accent-fg-color); border-radius: 4px; }
.r2-current-title { font-weight: 700; font-size: 0.95rem; margin-bottom: 0.4rem; }
</style>

<script>
(function() {
  var INDEX_URL = "https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/index.json";

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

  function renderFile(baseUrl, path, filename) {
    var url = baseUrl + "/" + path + filename;
    var div = el("div", {className: "r2-file"});
    div.appendChild(el("a", {href: url, text: filename}));
    return div;
  }

  function renderRelease(baseUrl, release, isCurrent) {
    var div = el("div", {className: "r2-release"});
    var header = el("div", {className: "r2-release-header"});
    header.appendChild(el("span", {text: release.date}));
    header.appendChild(el("span", {
      text: release.version,
      style: {marginLeft: "0.6rem", fontWeight: "normal", color: "var(--md-default-fg-color--light)"}
    }));
    if (isCurrent) header.appendChild(el("span", {className: "r2-badge", text: "latest"}));
    div.appendChild(header);

    var files = release.files || [];
    files.forEach(function(f) { div.appendChild(renderFile(baseUrl, release.path, f)); });
    div.appendChild(renderFile(baseUrl, release.path, "manifest.json"));
    return div;
  }

  function buildTree(data) {
    var container = document.getElementById("r2-tree");
    var releases = data.releases || [];
    var baseUrl = data.base_url || "";

    if (releases.length === 0) {
      container.innerHTML = "<p>No releases found.</p>";
      container.style.display = "block";
      return;
    }

    // Current release highlight
    var latest = releases[releases.length - 1];
    var currentDiv = el("div", {className: "r2-current"});
    currentDiv.appendChild(el("div", {className: "r2-current-title", html: "Current Release <span class='r2-badge'>latest</span>"}));
    var stableFiles = ["clinvar_gks_variation.jsonl.gz", "clinvar_gks_scv_by_ref.jsonl.gz", "manifest.json"];
    stableFiles.forEach(function(f) {
      var url = baseUrl + "/current/" + f;
      var row = el("div", {className: "r2-file"});
      row.appendChild(el("a", {href: url, text: f}));
      currentDiv.appendChild(row);
    });
    currentDiv.appendChild(el("div", {
      style: {marginTop: "0.3rem", fontSize: "0.78rem", color: "var(--md-default-fg-color--light)"},
      text: "Release " + latest.date + " (" + latest.version + ") \u2014 stable URLs, always the most recent data"
    }));
    container.appendChild(currentDiv);

    // Group by year and month
    var years = {};
    releases.forEach(function(r) {
      var y = r.date.substring(0, 4);
      var m = r.date.substring(0, 7);
      if (!years[y]) years[y] = {};
      if (!years[y][m]) years[y][m] = [];
      years[y][m].push(r);
    });

    // Archive heading
    container.appendChild(el("div", {
      style: {fontWeight: "700", fontSize: "0.95rem", marginBottom: "0.4rem"},
      text: "Archived Releases"
    }));

    // Render years in reverse order, most recent month open
    var sortedYears = Object.keys(years).sort().reverse();
    var firstYear = true;
    sortedYears.forEach(function(y) {
      var yearDetails = el("details", {className: "r2-year"});
      if (firstYear) yearDetails.setAttribute("open", "");
      yearDetails.appendChild(el("summary", {text: y}));

      var sortedMonths = Object.keys(years[y]).sort().reverse();
      var firstMonth = true;
      sortedMonths.forEach(function(m) {
        var monthDetails = el("details", {className: "r2-month"});
        if (firstYear && firstMonth) monthDetails.setAttribute("open", "");
        monthDetails.appendChild(el("summary", {text: m}));

        var monthReleases = years[y][m].sort(function(a, b) { return b.date.localeCompare(a.date); });
        monthReleases.forEach(function(r) {
          monthDetails.appendChild(renderRelease(baseUrl, r, r === latest));
        });
        yearDetails.appendChild(monthDetails);
        firstMonth = false;
      });
      container.appendChild(yearDetails);
      firstYear = false;
    });

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
      errDiv.textContent = "Unable to load release index. Use the curl command above to access index.json directly. (" + err.message + ")";
    });
})();
</script>

---

## Release Cadence

New datasets are published weekly, typically within 1-2 days of each ClinVar XML release. The `current/` files are overwritten with each new release. Archived releases are retained indefinitely.

---

## File Sizes

Typical compressed file sizes per release:

| Dataset | Approximate Size |
| --- | --- |
| `variation` | ~1.5 GB |
| `scv_by_ref` | ~2.0 GB |

Total download for a full weekly release is approximately 3.5 GB.

---

## Programmatic Access

The storage endpoint is S3-compatible. Tools that support custom S3 endpoints can access the bucket directly:

```bash
# Using AWS CLI (no credentials needed for public reads)
aws s3 ls s3://clinvar-gks/current/ \
  --endpoint-url https://09208aa33790838db213a21f630c33e7.r2.cloudflarestorage.com \
  --no-sign-request
```

The release index can be fetched programmatically to discover all available releases:

```bash
curl -s https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/index.json | python3 -m json.tool
```

---

## Feedback

This project is in active development and we welcome feedback from early adopters. If you encounter data quality issues, have questions about the output format, or want to suggest improvements:

- Open an issue on [GitHub](https://github.com/clingen-data-model/clinvar-gks/issues)
- Include the release date (from `manifest.json`) and the dataset file involved
