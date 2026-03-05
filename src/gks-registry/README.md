# GKS Schema Registry

A tool that aggregates JSON schema metadata from GA4GH GKS repositories.

## Repositories Tracked

- [gks-core](https://github.com/ga4gh/gks-core)
- [vrs](https://github.com/ga4gh/vrs)
- [cat-vrs](https://github.com/ga4gh/cat-vrs)
- [va-spec](https://github.com/ga4gh/va-spec)

## Usage

### Local Execution

```bash
cd src/gks-registry
pip install -r requirements.txt
python fetch_schemas.py
```

### Full Refresh

```bash
python fetch_schemas.py --full-refresh
```

### Via GitHub Actions

```bash
gh workflow run update-gks-registry.yml
gh workflow run update-gks-registry.yml -f full_refresh=true
```

## Outputs

- `data/registry.json` - Master registry with all repos, releases, schemas
- `data/by-repo/<repo>/<tag>.json` - Per-release JSON files
- `data/by-maturity/<level>.json` - Schemas grouped by maturity
- `docs/README.md` - Overview with summary table
- `docs/maturity-matrix.md` - Cross-repo maturity view
- `docs/release-history.md` - Timeline of all releases

## Configuration

Edit `config.yaml` to add/remove repositories or change paths.
