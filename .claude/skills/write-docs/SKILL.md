---
name: write-docs
description: Write or edit MkDocs documentation pages for the ClinVar-GKS project. Use when creating new documentation, editing existing pages, or adding new sections. Ensures consistent structure, formatting, and tone across all docs.
argument-hint: [page-type] [topic]
allowed-tools: Read, Grep, Glob, Edit, Write
---

# ClinVar-GKS MkDocs Documentation Writer

You are writing documentation for the ClinVar-GKS project using MkDocs with the Material theme. Follow these patterns exactly to maintain consistency with existing pages.

## Technology Stack

- **MkDocs** with **Material for MkDocs** theme
- Site served under `/clinvar-gks/` prefix (set by `site_url` in `mkdocs.yml`)
- Build command: `mkdocs build --strict` (catches broken links and warnings)
- Local dev server: `mkdocs serve -a localhost:8000`

### Available Markdown Extensions

These are configured in `mkdocs.yml` — use them freely:

- `tables` — standard markdown tables
- `admonition` — `!!! note`, `!!! warning`, etc.
- `pymdownx.highlight` — syntax-highlighted code blocks
- `pymdownx.superfences` — fenced code inside admonitions
- `pymdownx.details` — collapsible blocks (`??? note`)
- `attr_list` — HTML attributes on markdown elements
- `toc` with `permalink: true` — auto table of contents

## Page Types

### 1. Procedure Index Page

**Path pattern:** `docs/pipeline/{section}/index.md`
**Purpose:** Documents a BigQuery stored procedure

```markdown
# procedure_name Procedure

## Overview

One paragraph: what the procedure does, what spec it implements, what the output is for.

The procedure accepts a single parameter — `on_date DATE` — which identifies the ClinVar release schema to process.

---

## Workflow

The procedure executes the following steps sequentially within a loop over the target schema(s) identified by the `on_date` parameter.

### Step 1: Build `table_name`

Description of what this step does, including:
- Bullet points for key derivations or logic
- **Bold terms** for important concepts

**Output:** `table_name` — brief description of the table.

### Step 2: Build `next_table`

...

---

## Output Tables

| Table | Description |
|---|---|
| `table_name` | One-line description |

---

## Dependencies

- **UDFs**: `clinvar_ingest.function_name`, ...
- **Source Tables**: `table1`, `table2`, ...
- **Upstream Procedures**: `procedure_name`, ...
- **Downstream Consumers**: `procedure_name`, export pipeline
```

Rules:
- Title = procedure name in `snake_case` + "Procedure" (or a descriptive title matching the nav entry)
- Step headings: `### Step N:` or `### Step Na/Nb:` for sub-steps
- Every step ends with bold `**Output:**` naming the table
- Cross-reference sub-pages: `See [Page Title](filename.md) for full field documentation.`
- `---` horizontal rules between Overview, Workflow, Output Tables, Dependencies

#### Internal vs Downstream Tables

Distinguish between **downstream tables** (consumed by other procedures or pipelines) and **internal tables** (used only within the procedure to build the final output):

- **Downstream tables** get their own sub-pages with full field documentation and appear in the Output Tables section and mkdocs.yml nav
- **Internal tables** are described inline within their workflow step, do not get separate pages, and do not appear in Output Tables. Their `**Output:**` line says "Internal temporary table consumed by Step N."
- Internal tables should use `CREATE TEMP TABLE` in BigQuery SQL (no schema prefix, session-scoped). This prevents intermediate data from persisting unnecessarily in the dataset
- If an internal step has important logic (e.g., a precedence hierarchy), document it inline in the workflow step rather than on a separate page

#### Navigation Titles

Use descriptive nav titles in `mkdocs.yml`, not raw table names:
```yaml
# Good
- Sequence Locations: pipeline/variation-identity/variation-loc.md
- HGVS Expressions: pipeline/variation-identity/variation-hgvs.md

# Avoid
- variation_loc: pipeline/variation-identity/variation-loc.md
```

### 2. Table Documentation Page

**Path pattern:** `docs/pipeline/{section}/table-name.md`
**Purpose:** Documents a single output table's fields and behavior

```markdown
# table_name Table

## Overview

One paragraph: which procedure creates this table, what it contains, and its purpose.

---

## Fields

| Field | Type | Description |
|---|---|---|
| `field_name` | TYPE | Description with examples in `backticks`. |

---

## Row Granularity

One row per **field1 + field2** combination. Additional dedup/ranking explanation if needed.

---

## Notes

Optional subsections for behavioral details beyond field descriptions.
```

Rules:
- Title = table name in `snake_case` + "Table"
- Field types use BigQuery types: `STRING`, `INT64`, `BOOL`, `ARRAY<STRUCT<...>>`
- Include example values in backticks: `` `GRCh38` ``, `` `NC_000001.11` ``
- Bold the key in Row Granularity: `**variation_id + accession**`

### 3. Extension Reference Page

**Purpose:** Documents JSON extensions within a data structure

```markdown
# Extension Topic Title

## Overview

One paragraph: what extensions are, where they appear, common format.
Mention that most extensions carry simple scalar values, and extensions with
complex value types are documented as custom extension structures below.

---

## Extension Reference

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Extension (section, type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <!-- Simple scalar extension -->
    <tr>
      <td><code>extensionName</code><br><em>ParentNode</em><br>string</td>
      <td>Description of the extension.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "extensionName", "value": "exampleValue" }</code></pre></td>
    </tr>
    <!-- Custom structure extension -->
    <tr>
      <td><code>complexExtName</code><br><em>ParentNode</em><br>array&lt;<a href="#sub-structure-name">ItemType</a>&gt;</td>
      <td>Description. See <a href="#sub-structure-name">Sub-Structure Name</a> custom extension structure below.</td>
    </tr>
    <tr>
      <td colspan="2"><pre><code>{ "name": "complexExtName", "value": [<a href="#sub-structure-name">...</a>] }</code></pre></td>
    </tr>
  </tbody>
</table>

---

## Custom Extension Structures

Extensions with complex value types use structured objects rather than simple
scalars. The structures below define the shape of each custom extension's
`value` field.

### Sub-Structure Name

Description of what this extension contains.

<table>
  <thead>
    <tr>
      <th style="white-space: nowrap; width: 30%;">Field (type)</th>
      <th>Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>fieldName</code><br>valueType</td>
      <td>Description of the field.</td>
    </tr>
  </tbody>
</table>

#### Example

\```json
{
  "fieldName": "exampleValue"
}
\```
```

Rules:
- Use HTML `<table>` for all reference tables (not markdown) to support `<br>` stacking
- Extension reference: first column header is `Extension (section, type)` with `style="white-space: nowrap; width: 30%;"`
- Extension reference: first column stacks three items vertically: `<code>name</code>`, `<em>ParentNode</em>` (italicized), valueType
- Every extension row is followed by a spanning example row: `<td colspan="2"><pre><code>{ "name": "...", "value": ... }</code></pre></td>`
- Example values must use the exact camelCase extension name from the first column
- If the example value would cause horizontal scrolling, truncate with `...`
- For custom structure types, the type in column 1 uses `array&lt;<a href="#anchor">ItemType</a>&gt;` linking to the custom structure subsection
- For custom structure types, the example row shows `[<a href="#anchor">...</a>]` as the truncated value with a link
- Custom extension structures are grouped under a `## Custom Extension Structures` section with H3 subsections
- Each custom structure subsection has an `#### Example` with a full JSON code block showing one realistic entry
- Sub-structure tables: first column header is `Field (type)` with the same width style
- Sub-structure tables: first column stacks two items vertically: `<code>fieldName</code>`, valueType
- Second column is always the description
- Link to sub-structure sections with `<a href="#section-id">Link Text</a>`

### 4. Profile/Reference Page

**Purpose:** Classification mappings, statement types, or reference data

```markdown
# Topic Title

Opening paragraph providing context.

## Section

| Column1 | Column2 | Column3 |
| --- | --- | --- |
| value | value | value |

## Explanatory Section

Prose explaining rules, edge cases, or design decisions.
```

Rules:
- Table separators use `| --- |` (no alignment colons unless right-aligning numbers)
- Empty cells for spanning rows use `|  |`
- Show null values as `\<null\>` with escaped angle brackets

### 5. Stub/Placeholder Page

For sections not yet written:

```markdown
# Section Title

!!! note "Under Construction"
    This page is under active development. Content will be added in upcoming updates.

One sentence describing what the page will contain when complete.
```

## Writing Style

### Tone
- **Technical and direct** — no filler, no conversational language
- **Third person, present tense** — "The procedure extracts..." not "We extract..."
- **Declarative** — state what things are and do
- Avoid "please", "note that", "it is important to", and similar hedging

### Formatting
- **Bold** for emphasis on key terms, concepts, category labels
- **Backticks** for: field names, table names, procedure names, SQL functions, values, types, file paths
- **Code blocks** with language specified for SQL, bash, JSON
- **Em dashes** (` — `) for inline asides, not parentheses
- **Bullet points** for lists of 3+ items
- No trailing periods on bullet items unless they are full sentences
- No emoji anywhere

### Cross-References
- Sibling pages: `[Page Title](filename.md)`
- Sub-pages: `[Page Title](subfolder/filename.md)`
- Parent pages: `[Page Title](../filename.md)`
- Never use absolute paths or URLs for internal links

### Section Separators
- `---` between major sections (Overview, Workflow, Output Tables, Dependencies)
- No `---` between subsections (between Step 1 and Step 2)
- No `---` at the end of a page

## Navigation (`mkdocs.yml`)

### Adding New Pages

Multi-page sections:
```yaml
- Section Name:
  - section/index.md
  - Sub Page: section/sub-page.md
```

Single-page sections:
```yaml
- Page Title: section/page-name.md
```

### File Naming
- kebab-case for all filenames: `catvar-extensions.md`, `variation-loc.md`
- Index files are always `index.md`
- Directory names match nav section slugs: `cat-vrs/`, `variation-identity/`

## JSON Examples

When creating example files in `/examples/`:
- Use `.jsonc` extension for files with comments
- 2-space indentation
- Use realistic data from actual ClinVar variations
- Show complete structures, not fragments

## Checklist Before Finishing

1. Run `mkdocs build --strict` — zero warnings
2. All internal links resolve
3. New pages are added to `nav:` in `mkdocs.yml`
4. Parent index pages reference new sub-pages
5. Consistent formatting with existing pages

---

**Start writing:** $ARGUMENTS
