# TZ-DevOps-Global

Centralized GitHub Composite Actions for Taazaa DevOps pipelines.
These actions contain logic that is **identical across all repos and all languages** — reference them from any repo's workflow instead of duplicating the code.

## Available Actions

| Action | Path | Purpose |
|--------|------|---------|
| validate-branch | `.github/actions/validate-branch` | Enforce branch naming conventions on PRs |
| gitleaks-scan | `.github/actions/gitleaks-scan` | Secret scanning via GitLeaks |
| trivy-scan | `.github/actions/trivy-scan` | Container image vulnerability scan via Trivy |

> **Not here:** SonarQube scans, Docker build, Helm deploy — these are repo/language-specific and stay in each repo's own pipeline.

---

## Usage

Reference actions using `taazaainc/TZ-DevOps-Global/.github/actions/<action-name>@master`

### validate-branch

```yaml
- name: Validate Branch Name
  uses: taazaainc/TZ-DevOps-Global/.github/actions/validate-branch@master
  # No inputs required — uses default prefixes: feature/, bugfix/, hotfix/, release/
```

Override prefixes for a repo with different conventions:
```yaml
- name: Validate Branch Name
  uses: taazaainc/TZ-DevOps-Global/.github/actions/validate-branch@master
  with:
    allowed-prefixes: "feature,bugfix,hotfix,release,fix"
```

---

### gitleaks-scan

```yaml
- name: GitLeaks Secret Scanning
  uses: taazaainc/TZ-DevOps-Global/.github/actions/gitleaks-scan@master
  with:
    service-name: ${{ matrix.service.name }}
    # Optional:
    # gitleaks-version: "8.22.1"
    # fail-on-secrets: "true"
    # config-file: ".gitleaks.toml"
```

---

### trivy-scan

```yaml
- name: Trivy Security Scan
  uses: taazaainc/TZ-DevOps-Global/.github/actions/trivy-scan@master
  with:
    image-name: "${{ env.IMAGE_NAME }}:test-${{ github.run_number }}"
    service-name: ${{ matrix.service.name }}
    # Optional:
    # severity: "CRITICAL,HIGH,MEDIUM"
    # fail-on-critical: "true"
```

---

## Versioning

All pipelines reference `@master`. When you need to make a breaking change:
1. Create a tag (e.g. `v2`) on master after the change
2. Update consuming repos to reference `@v2`

For non-breaking changes, just push to master — all repos pick it up automatically.

## Requirements

- **validate-branch**: No dependencies. Runs on any runner.
- **gitleaks-scan**: Requires `wget`, `tar`, `jq` on runner. Downloads gitleaks binary automatically.
- **trivy-scan**: Requires Docker on runner (`/var/run/docker.sock` mounted). Image must be pre-built before calling this action.
