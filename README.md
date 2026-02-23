# TZ-DevOps-Global

Centralized GitHub Actions and Reusable Workflows for Taazaa DevOps pipelines.
These contain logic that is **identical across all repos and all languages** — reference them from any repo's workflow instead of duplicating the code.

---

## Available Reusable Workflows

| Workflow | Path | Purpose |
|----------|------|---------|
| check-for-changes | `.github/workflows/check-for-changes.yml` | Detect which services changed in a push or PR |

## Available Composite Actions

| Action | Path | Purpose |
|--------|------|---------|
| validate-branch | `.github/actions/validate-branch` | Enforce branch naming conventions on PRs |
| gitleaks-scan | `.github/actions/gitleaks-scan` | Secret scanning via GitLeaks |
| trivy-scan | `.github/actions/trivy-scan` | Container image vulnerability scan via Trivy |

> **Not here:** SonarQube scans, Docker build, Helm deploy — these are repo/language-specific and stay in each repo's own pipeline.

---

## Reusable Workflows

### check-for-changes

Detects which services have changed in a push or pull request by comparing file paths against a `variables.json` service map. Returns a JSON array of changed service objects for use in a downstream matrix job.

#### How It Works

The detection strategy depends on the event type:

| Event | Strategy | Comparison | Result |
|-------|----------|------------|--------|
| PR `opened` / `reopened` | Full branch scan | `merge-base..HEAD` | All services changed since branch diverged from base |
| PR `synchronize` (normal push) | Incremental scan | `event.before..HEAD` | Only services changed in this push |
| PR `synchronize` (force push) | Full branch scan (fallback) | `merge-base..HEAD` | Safe fallback when `before` SHA is missing from history |
| Push to `deploy/*` | Deploy scan | `HEAD^..HEAD` | Only services brought in by this merge/commit |

This means:
- A developer who opens a PR touching 5 services → all 5 scan
- A follow-up push fixing only 1 service → only 1 scans
- A force push → full branch scan (safe fallback, never misses anything)

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `runner` | No | `'["self-hosted"]'` | JSON array of runner labels matching the calling repo's self-hosted runner |
| `variables-json-path` | No | `.github/workflows/variables.json` | Relative path to the service map JSON file in the calling repo |

#### Outputs

| Output | Description |
|--------|-------------|
| `changed_services` | JSON array of service objects that changed. Empty array `[]` if no services changed. |

#### variables.json format

Each repo must have a `variables.json` (at the path specified by `variables-json-path`) with the following structure per service:

```json
{
  "servicekey": {
    "name": "ServiceName",
    "changeset_path": "src/Services/MyService/**",
    "image_base": "myservice",
    "project_path": "src/Services/MyService/MyService.Api",
    "dockerfile": "src/Services/MyService/MyService.Api/Dockerfile",
    "context_path": "./src",
    "helm_path": "helm/base/myproject",
    "sonar_key": "MyOrg_MyProject_ServiceName",
    "dotnet_version": "7",
    "image_name": "registry.example.com/myproject/myservice"
  }
}
```

Multiple changeset paths per service are supported (comma-separated):
```json
"changeset_path": "src/Services/MyService/**, src/Shared/Common/**"
```

#### Usage

```yaml
jobs:
  check-for-changes:
    uses: taazaainc/TZ-DevOps-Global/.github/workflows/check-for-changes.yml@master
    with:
      runner: '["self-hosted", "linux", "your-runner-label"]'
      # variables-json-path: ".github/workflows/variables.json"  # optional, this is the default

  build:
    needs: check-for-changes
    if: needs.check-for-changes.outputs.changed_services != '[]'
    strategy:
      fail-fast: false
      matrix:
        service: ${{ fromJson(needs.check-for-changes.outputs.changed_services) }}
    steps:
      - run: echo "Building ${{ matrix.service.name }}"
```

#### Requirements

- Runner must have: `git`, `jq`, `bash`
- Calling repo must have a valid `variables.json` at the configured path
- `fetch-depth: 0` is handled internally — no extra checkout needed in the caller

---

## Composite Actions

### validate-branch

Enforces branch naming conventions on pull requests. Fails if the PR source branch does not match an allowed prefix. Promotion PRs between `deploy/*` branches are automatically skipped.

Only runs on `pull_request` events — silently skipped on push.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `allowed-prefixes` | No | `feature,bugfix,hotfix,release` | Comma-separated list of allowed branch prefixes |
| `skip-prefixes` | No | `deploy` | Comma-separated list of prefixes that bypass validation entirely (e.g. promotion branches) |

#### Usage

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

Scans the repository for leaked secrets and credentials using GitLeaks. Outputs a JSON report. Optionally fails the pipeline when secrets are found.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `service-name` | Yes | — | Name of the service being scanned (used to name the report file) |
| `gitleaks-version` | No | `8.22.1` | GitLeaks binary version to download |
| `fail-on-secrets` | No | `false` | Set to `'true'` to fail the pipeline when secrets are detected |
| `config-file` | No | `.gitleaks.toml` | Path to a custom GitLeaks config file in the repo |

#### Usage

```yaml
- name: GitLeaks Secret Scanning
  uses: taazaainc/TZ-DevOps-Global/.github/actions/gitleaks-scan@master
  with:
    service-name: ${{ matrix.service.name }}
    # Set to 'true' to fail the pipeline when secrets/credentials are detected.
    # Default is 'false' — scan runs and reports but does not block the pipeline.
    fail-on-secrets: 'true'
```

#### Requirements

- Runner must have: `wget`, `tar`, `jq`, `bash`
- Downloads the GitLeaks binary automatically to `/tmp/gitleaks`

---

### trivy-scan

Scans a pre-built Docker image for vulnerabilities using Trivy. Outputs a JSON report. Optionally fails the pipeline on CRITICAL severity findings.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image-name` | Yes | — | Full image name and tag to scan (e.g. `registry.example.com/myapp:test-42`) |
| `service-name` | Yes | — | Name of the service being scanned (used to name the report file) |
| `severity` | No | `CRITICAL,HIGH` | Comma-separated severity levels to report |
| `fail-on-critical` | No | `false` | Set to `'true'` to fail the pipeline when CRITICAL vulnerabilities are found |

#### Usage

```yaml
- name: Trivy Security Scan
  uses: taazaainc/TZ-DevOps-Global/.github/actions/trivy-scan@master
  with:
    image-name: "${{ matrix.service.image_name }}:test-${{ github.run_number }}"
    service-name: ${{ matrix.service.name }}
    # Set to 'true' to fail the pipeline when CRITICAL vulnerabilities are found.
    # Default is 'false' — scan runs and reports but does not block the pipeline.
    fail-on-critical: 'true'
```

#### Requirements

- Runner must have: Docker with `/var/run/docker.sock` accessible
- The Docker image must be built before calling this action

---

## Versioning

All pipelines reference `@master`. When you need to make a breaking change:
1. Create a tag (e.g. `v2`) on master after the change
2. Update consuming repos to reference `@v2`

For non-breaking changes, push to master via PR — all repos pick it up automatically on next run.

## Branch Protection

The `master` branch is protected by the `TZ-DevOps-Global-Master-Protection` ruleset:
- No direct pushes — all changes must go through a pull request
- 1 approving review required
- Force pushes blocked
- OrganizationAdmin can bypass in emergencies (bypass is logged by GitHub)
