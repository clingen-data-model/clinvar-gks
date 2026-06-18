# R2 Directory Restructure Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the R2 upload script and documentation to implement a new directory structure with monthly/weekly datasets, automatic archival, and stable "latest" symlink files.

**Architecture:** The upload script (`upload-gks-to-r2.sh`) is rewritten to manage a structured R2 layout with `datasets/`, `datasets/weekly/`, `archives/`, and `release_notes/` folders. On each upload, the script detects month and year boundaries by listing existing R2 contents, then performs the appropriate file movements, copies, and uploads. Documentation pages are updated to reflect the new paths and naming conventions.

**Tech Stack:** Bash (upload script), AWS CLI (R2 S3-compatible API), MkDocs (documentation)

---

## R2 Directory Structure

```
R2 bucket root/
├── README.txt                                      # folder structure guide
├── release_notes/
│   └── yyyymmdd-description.txt                    # pipeline change notes
├── datasets/
│   ├── clinvar-gks_yyyy-mm.json.gz                 # monthly files (current year)
│   ├── clinvar-gks_00-latest.json.gz               # copy of most recent monthly
│   └── weekly/
│       ├── clinvar-gks_yyyy-mmdd.json.gz           # weekly files (current month)
│       └── clinvar-gks_00-latest_weekly.json.gz    # copy of most recent weekly
└── archives/
    └── yyyy/
        ├── clinvar-gks_yyyy-mm.json.gz             # monthly files from prior years
        └── weekly/
            └── clinvar-gks_yyyy-mmdd.json.gz       # weekly files from prior months
```

## Naming Conventions

| Type | Pattern | Example |
|---|---|---|
| Weekly file | `clinvar-gks_yyyy-mmdd.json.gz` | `clinvar-gks_2026-0614.json.gz` |
| Latest weekly | `clinvar-gks_00-latest_weekly.json.gz` | (stable name) |
| Monthly file | `clinvar-gks_yyyy-mm.json.gz` | `clinvar-gks_2026-06.json.gz` |
| Latest monthly | `clinvar-gks_00-latest.json.gz` | (stable name) |

The `00-` prefix on "latest" files ensures they sort before dated files in directory listings.

## Upload Logic

Each invocation uploads a single weekly release. The script auto-detects boundaries:

**Every upload:**
1. Upload weekly file to `datasets/weekly/clinvar-gks_yyyy-mmdd.json.gz`
2. Copy to `datasets/weekly/clinvar-gks_00-latest_weekly.json.gz`

**First upload of a new month** (detected when existing weekly files have a different month):
1. Move previous month's dated weekly files to `archives/{prev_year}/weekly/`
2. Delete the old `clinvar-gks_00-latest_weekly.json.gz`
3. Upload new weekly file + latest weekly copy
4. Copy file to `datasets/clinvar-gks_yyyy-mm.json.gz` (new monthly)
5. Update `datasets/clinvar-gks_00-latest.json.gz`

**First upload of a new year** (extends new-month logic):
1. Move previous year's dated monthly files from `datasets/` to `archives/{prev_year}/`
2. Then perform all new-month steps above

---

## File Map

| Action | File | Purpose |
|---|---|---|
| Rewrite | `src/scripts/upload-gks-to-r2.sh` | New R2 directory logic |
| Create | `src/scripts/r2-readme.txt` | Source for R2 root README.txt |
| Modify | `docs/pipeline/export.md:72-93` | Update Step 3 (Upload to R2) |
| Modify | `docs/data-access/index.md` | Replace current/ and archive references |
| Modify | `docs/data-access/download.md` | Replace current/ references, add archive examples |
| Modify | `docs/data-access/output-files.md:25-45` | Update naming conventions |

---

## Chunk 1: Upload Script

### Task 1: Create R2 README source file

**Files:**
- Create: `src/scripts/r2-readme.txt`

- [ ] **Step 1: Write the README content**

```text
ClinVar-GKS Data Distribution
==============================

This bucket contains ClinVar data transformed into GA4GH GKS format
(VRS, Cat-VRS, VA-Spec). Files are gzip-compressed JSON bundles.

Directory Structure
-------------------

datasets/
  Monthly dataset files for the current year.
  clinvar-gks_00-latest.json.gz  — always the most recent monthly release.
  clinvar-gks_yyyy-mm.json.gz    — monthly release for a specific month.

datasets/weekly/
  Weekly dataset files for the current month.
  clinvar-gks_00-latest_weekly.json.gz  — always the most recent weekly release.
  clinvar-gks_yyyy-mmdd.json.gz         — weekly release for a specific date.

archives/
  Prior years' monthly and weekly files, organized by year.
  archives/yyyy/                        — monthly files for that year.
  archives/yyyy/weekly/                 — weekly files for that year.

release_notes/
  Pipeline change notes describing additions, fixes, or structural changes
  to the GKS output format. Named yyyymmdd-description.txt.

Quick Start
-----------

Download the latest release:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/clinvar-gks_00-latest.json.gz

Download the latest weekly:
  curl -O https://pub-9c5470edadb8496fb0abbf396291660b.r2.dev/datasets/weekly/clinvar-gks_00-latest_weekly.json.gz

Documentation: https://clingen-data-model.github.io/clinvar-gks/
Source: https://github.com/clingen-data-model/clinvar-gks
```

- [ ] **Step 2: Commit**

```bash
git add src/scripts/r2-readme.txt
git commit -m "Add R2 bucket README source file"
```

### Task 2: Rewrite upload-gks-to-r2.sh

**Files:**
- Rewrite: `src/scripts/upload-gks-to-r2.sh`

- [ ] **Step 1: Write the new upload script**

The script must:
- Accept `<export_date> <dataset_version> [--dry-run]` as CLI args
- Validate date format (YYYY-MM-DD)
- Download bundle from GCS (same source logic as current script)
- Derive `YYYY`, `MM`, `DD`, `MMDD` from export_date
- Define helper functions: `r2_upload`, `r2_copy`, `r2_ls`, `r2_rm`
- Implement the three-path upload logic:
  1. **Detect state**: list `datasets/weekly/` to find existing dated files, extract their month
  2. **Year rollover**: if current year > existing monthly file years, move dated monthly files to `archives/{old_year}/`, move weekly files to `archives/{old_year}/weekly/`
  3. **Month rollover**: if current month > existing weekly file month, move dated weekly files to `archives/{year}/weekly/`, then upload monthly file + update latest
  4. **Always**: upload weekly file + update latest weekly
- Upload `r2-readme.txt` to root `README.txt` (idempotent, always overwrite)
- Print summary of all actions taken

Key implementation details for the helper functions:

```bash
# r2_copy: use aws s3 cp with s3-to-s3 copy (no download needed)
r2_copy() {
  local src="$1" dest="$2"
  aws s3 cp "s3://${R2_BUCKET}/${src}" "s3://${R2_BUCKET}/${dest}" \
    --endpoint-url "${R2_ENDPOINT}" --profile "${R2_PROFILE}" --quiet
}

# r2_ls: list objects with a prefix, return just the keys
r2_ls() {
  local prefix="$1"
  aws s3 ls "s3://${R2_BUCKET}/${prefix}" \
    --endpoint-url "${R2_ENDPOINT}" --profile "${R2_PROFILE}" \
    2>/dev/null | awk '{print $NF}'
}

# r2_rm: delete a single object
r2_rm() {
  local key="$1"
  aws s3 rm "s3://${R2_BUCKET}/${key}" \
    --endpoint-url "${R2_ENDPOINT}" --profile "${R2_PROFILE}" --quiet
}
```

Month detection logic:

```bash
# List existing weekly files (dated only, not latest)
EXISTING_WEEKLY=$(r2_ls "datasets/weekly/clinvar-gks_" | grep -v "00-latest" || true)

# Extract month from first existing file (yyyy-mmdd -> mm)
if [[ -n "$EXISTING_WEEKLY" ]]; then
  FIRST_FILE=$(echo "$EXISTING_WEEKLY" | head -1)
  # clinvar-gks_2026-0607.json.gz -> 2026-06
  EXISTING_MONTH=$(echo "$FIRST_FILE" | sed 's/clinvar-gks_\([0-9]\{4\}-[0-9]\{2\}\).*/\1/')
  EXISTING_YEAR=$(echo "$EXISTING_MONTH" | cut -d- -f1)
fi
```

- [ ] **Step 2: Test with --dry-run**

```bash
./src/scripts/upload-gks-to-r2.sh 2026-06-14 v2_5_0 --dry-run
```

Verify output shows the expected upload plan without executing any uploads.

- [ ] **Step 3: Commit**

```bash
git add src/scripts/upload-gks-to-r2.sh
git commit -m "Rewrite R2 upload script with new directory structure"
```

---

## Chunk 2: Documentation Updates

### Task 3: Update export.md Step 3

**Files:**
- Modify: `docs/pipeline/export.md:72-93`

- [ ] **Step 1: Replace the "Upload to R2" section**

Replace the Step 3 content starting at line 72 with updated usage, flag descriptions (`--dry-run` only, remove `--skip-current`), and the new directory structure description:

- Usage: `./src/scripts/upload-gks-to-r2.sh <export_date> <dataset_version> [--dry-run]`
- Describe the three R2 locations: `datasets/` (monthly), `datasets/weekly/` (weekly), `archives/` (prior years/months)
- Document automatic month/year rollover behavior
- Update the Full Example section at the bottom

- [ ] **Step 2: Commit**

```bash
git add docs/pipeline/export.md
git commit -m "Update export.md with new R2 directory structure"
```

### Task 4: Update data-access/index.md

**Files:**
- Modify: `docs/data-access/index.md`

- [ ] **Step 1: Replace current/ references and archive stub**

- Replace `current/` URL with `datasets/` URL
- Replace curl example to use `clinvar-gks_00-latest.json.gz`
- Replace the "Archives" stub with actual content describing `archives/{yyyy}/` structure
- Update "Release Schedule" to describe the monthly/weekly cadence and rollover
- Remove `release_notes` section from here (that content is pipeline-specific, not consumer-facing)

- [ ] **Step 2: Commit**

```bash
git add docs/data-access/index.md
git commit -m "Update data access page with new R2 paths"
```

### Task 5: Update download.md

**Files:**
- Modify: `docs/data-access/download.md`

- [ ] **Step 1: Rewrite download page**

- Replace "Latest Release" section: `datasets/weekly/clinvar-gks_00-latest_weekly.json.gz` for latest weekly, `datasets/clinvar-gks_00-latest.json.gz` for latest monthly
- Replace "Archives" stub with examples for `archives/{yyyy}/`
- Update Python example to use new paths
- Keep Feedback section unchanged

- [ ] **Step 2: Commit**

```bash
git add docs/data-access/download.md
git commit -m "Update download page with new R2 directory paths"
```

### Task 6: Update output-files.md naming conventions

**Files:**
- Modify: `docs/data-access/output-files.md:25-46`

- [ ] **Step 1: Replace File Naming Convention section**

Replace the three naming subsections (Current Release, Weekly Releases, Archives) with:

- **Latest Release**: `clinvar-gks_00-latest.json.gz` (stable filename, always the most recent monthly)
- **Latest Weekly**: `clinvar-gks_00-latest_weekly.json.gz` (stable filename, always the most recent weekly)
- **Weekly Releases**: `clinvar-gks_yyyy-mmdd.json.gz`
- **Monthly Releases**: `clinvar-gks_yyyy-mm.json.gz`

Update the `gunzip` example commands to use `clinvar-gks_00-latest.json.gz` instead of `clinvar-gks-current.json.gz`.

- [ ] **Step 2: Commit**

```bash
git add docs/data-access/output-files.md
git commit -m "Update output file naming conventions for new R2 structure"
```

### Task 7: Validate docs build

- [ ] **Step 1: Run mkdocs build**

```bash
mkdocs build --strict 2>&1
```

Only pre-existing warnings (output-reference/classes broken links) should appear. No new warnings from our changes.

- [ ] **Step 2: Final commit if any fixes needed**

---

## Summary of Changes

| File | Change |
|---|---|
| `src/scripts/upload-gks-to-r2.sh` | Full rewrite — new directory layout, month/year rollover, `--dry-run` support |
| `src/scripts/r2-readme.txt` | New — source file for R2 root README.txt |
| `docs/pipeline/export.md` | Update Step 3 with new R2 paths and behavior |
| `docs/data-access/index.md` | Replace `current/` and archive stubs with `datasets/` paths |
| `docs/data-access/download.md` | Rewrite with new download URLs and archive examples |
| `docs/data-access/output-files.md` | Update naming convention section |
