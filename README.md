# TZ-DevOps-Global

Centralized GitHub Actions and reusable workflows for Taazaa DevOps pipelines.
Logic that is **identical across all repos** lives here — reference it from any repo's workflow instead of duplicating code.

---

## What's Here

| Type | Name | Path | Purpose |
|------|------|------|---------|
| Composite Action | `github-restrictions` | `.github/actions/github-restrictions` | PR gate: branch naming + PR size limits |
| Composite Action | `gitleaks-scan` | `.github/actions/gitleaks-scan` | Secret scanning via GitLeaks |
| Composite Action | `trivy-scan` | `.github/actions/trivy-scan` | Container image vulnerability scan via Trivy |
| Composite Action | `validate-branch` | `.github/actions/validate-branch` | Branch naming only (lightweight, use github-restrictions instead) |
| Reusable Workflow | `check-for-changes` | `.github/workflows/check-for-changes.yml` | Incremental change detection — outputs JSON list of changed services |
| Reusable Workflow | `code-quality-security` | `.github/workflows/code-quality-security.yml` | SonarQube + Trivy + GitLeaks scan per changed service (matrix) |

---

## Reusable Workflows

Reference workflows using `taazaainc/TZ-DevOps-Global/.github/workflows/<name>.yml@master`

### check-for-changes

Reads `variables.json` from the calling repo, diffs the branch, and outputs a JSON array of service objects that have changes.

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `runner` | No | `'["self-hosted"]'` | JSON array of runner labels |
| `variables-json-path` | No | `.github/workflows/variables.json` | Path to variables.json in the calling repo |

**Outputs:**

| Output | Description |
|--------|-------------|
| `changed_services` | JSON array of service objects with changes, or `[]` if none |

**Scan strategy (incremental by default):**
- `pull_request / synchronize` → diffs only the commits in this push (`BEFORE..HEAD`)
- `pull_request / opened or reopened` → full branch scan (`merge-base..HEAD`)
- `push to deploy/*` → only what this merge brought in (`HEAD^..HEAD`)

**Example:**
```yaml
check-for-changes:
  uses: taazaainc/TZ-DevOps-Global/.github/workflows/check-for-changes.yml@master
  with:
    runner: '["self-hosted", "linux", "your-runner-label"]'
```

**variables.json format** — each service entry:
```json
{
  "my-service": {
    "name": "MyService",
    "sonar_key": "MyService_Key",
    "changeset_path": "src/Services/MyService/**",
    "project_path": "src/Services/MyService/MyService.Api/MyService.Api.csproj",
    "image_name": "registry.example.com/myproject/myservice",
    "image_base": "myservice",
    "dockerfile": "src/Services/MyService/Dockerfile",
    "context_path": "src/",
    "helm_path": "charts/myservice",
    "dotnet_version": "8.0"
  }
}
```

Multiple changeset paths (comma-separated):
```json
"changeset_path": "src/Services/MyService/**, src/Shared/Common/**"
```

---

### code-quality-security

Runs SonarQube analysis, Trivy container scan, and GitLeaks secret scan for each changed service in parallel (matrix). Includes a stable `Scan Summary` job suitable for use as a required branch ruleset check.

**Inputs:**

| Input | Required | Description |
|-------|----------|-------------|
| `runner` | No | JSON array of runner labels |
| `changed_services` | No | JSON array from `check-for-changes` output. Pass `[]` to skip. |
| `dotnet_container_image` | Yes | Docker image with .NET SDK + sonar-scanner. Store as `vars.DOTNET_CONTAINER_IMAGE` in caller. |
| `sonar_nodejs_image` | Yes | Docker image for Node.js SonarQube scanning. Store as `vars.SONAR_NODEJS_IMAGE` in caller. |
| `fail-on-critical` | No (`false`) | Set to `'true'` to fail the pipeline when Trivy finds CRITICAL vulnerabilities. |
| `fail-on-secrets` | No (`false`) | Set to `'true'` to fail the pipeline when GitLeaks detects secrets in source code. |

**Secrets required:**

| Secret | Description |
|--------|-------------|
| `SONAR_TOKEN` | SonarQube authentication token |
| `SONAR_HOST_URL` | SonarQube server URL |
| `TCR_USERNAME` | Container registry username (for pulling build container + Trivy image) |
| `TCR_PASSWORD` | Container registry password |

**Trivy image:** Read from `vars.TRIVY_IMAGE` in the calling repo (or org-level variable). Falls back to `aquasec/trivy:latest` if not set. Set this variable to a private registry mirror to avoid Docker Hub rate limits.

**variables.json — additional fields for scanning:**
```json
{
  "my-service": {
    "dotnet_version": "8.0",
    "common_lib_paths": "src/Shared/Common",
    "scanner_type": null
  },
  "my-ui": {
    "scanner_type": "nodejs"
  }
}
```

- Omit `scanner_type` (or set `null`) → .NET scanning path (sonar-scanner via dotnet)
- Set `scanner_type: "nodejs"` → Node.js scanning path (runs SonarQube via Docker container)

**Jobs produced:**
- `<ServiceName>-SCA & Security Scan` — one per changed service (dynamic name, not suitable for required checks)
- `Scan Summary` — **stable name**, always runs, exits 1 if any service failed → **use this as your required check**

**Example:**
```yaml
code-quality-security:
  uses: taazaainc/TZ-DevOps-Global/.github/workflows/code-quality-security.yml@master
  needs: [github-restrictions]
  if: github.event_name == 'pull_request' && (startsWith(github.head_ref, 'feature/') || startsWith(github.head_ref, 'release/'))
  with:
    runner: '["self-hosted", "linux", "your-runner-label"]'
    changed_services: ${{ needs.github-restrictions.outputs.changed_services }}
    dotnet_container_image: ${{ vars.DOTNET_CONTAINER_IMAGE }}
    sonar_nodejs_image: ${{ vars.SONAR_NODEJS_IMAGE }}
    # fail-on-critical: 'true'   # uncomment to block merge on CRITICAL CVEs
    # fail-on-secrets: 'true'    # uncomment to block merge when secrets are detected
  secrets:
    SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
    SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
    TCR_USERNAME: ${{ secrets.TCR_USERNAME }}
    TCR_PASSWORD: ${{ secrets.TCR_PASSWORD }}
```

---

## Composite Actions

Reference actions using `taazaainc/TZ-DevOps-Global/.github/actions/<action-name>@master`

### github-restrictions

Centralized PR gate. Enforces branch naming convention, forbidden file detection, and optional PR size limits. Add new checks here — all repos that call this action inherit them automatically.

**Checks (in order):**

1. **Branch naming** — validates `head_ref` against allowed prefixes
2. **Forbidden files** — blocks PRs containing build artifacts, secrets, IDE folders, OS junk, or compiled files (see list below)
3. **PR size** — optionally enforces max files changed and max lines changed

**Forbidden file patterns detected:**

| Category | Patterns |
|----------|----------|
| Build artifacts | `bin/`, `obj/`, `dist/`, `build/`, `target/`, `out/` |
| Dependencies | `node_modules/`, `vendor/` |
| Temp / cache | `tmp/`, `temp/`, `cache/`, `logs/`, `__pycache__/` |
| IDE folders | `.idea/`, `.vscode/` |
| OS files | `.DS_Store`, `Thumbs.db` |
| Secrets | `.env`, `.env.*`, `*.pem`, `*.key` |
| Compiled files | `*.class`, `*.pyc`, `*.log` |

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `allowed-prefixes` | `feature,bugfix,hotfix,release` | Comma-separated allowed branch prefixes |
| `skip-prefixes` | `deploy` | Branches bypassing all validation (e.g. deploy/*→deploy/*) |
| `max-files` | `0` (disabled) | Max changed files in a PR (0 = no limit) |
| `max-lines` | `0` (disabled) | Max lines added in a PR (0 = no limit) |
| `size-exempt-label` | `size-exempt` | PR label that bypasses size checks |

**Example:**
```yaml
github-restrictions:
  name: GitHub Restrictions
  runs-on: [self-hosted, linux, your-runner-label]
  steps:
    - uses: taazaainc/TZ-DevOps-Global/.github/actions/github-restrictions@master
```

---

### trivy-scan

Scans a pre-built Docker image for vulnerabilities. Uploads JSON report as a workflow artifact.

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image-name` | Yes | — | Full image name with tag |
| `service-name` | Yes | — | Used for artifact naming |
| `trivy-image` | No | `aquasec/trivy:latest` | Trivy Docker image. Use private mirror to avoid rate limits. |
| `registry-username` | No | — | Registry credentials to pull trivy image |
| `registry-password` | No | — | Registry credentials to pull trivy image |
| `severity` | No | `CRITICAL,HIGH,MEDIUM` | Severity levels to scan |
| `fail-on-critical` | No | `false` | Fail pipeline on CRITICAL findings |

**Example:**
```yaml
- name: Trivy Security Scan
  uses: taazaainc/TZ-DevOps-Global/.github/actions/trivy-scan@master
  with:
    image-name: "${{ env.IMAGE_NAME }}:test-${{ github.run_number }}"
    service-name: ${{ matrix.service.name }}
    trivy-image: ${{ vars.TRIVY_IMAGE || 'aquasec/trivy:latest' }}
    registry-username: ${{ secrets.TCR_USERNAME }}
    registry-password: ${{ secrets.TCR_PASSWORD }}
```

---

### gitleaks-scan

Scans the repository for leaked secrets using GitLeaks.

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `service-name` | Yes | — | Used for artifact naming |
| `gitleaks-version` | No | `8.22.1` | GitLeaks version to download |
| `fail-on-secrets` | No | `false` | Fail pipeline when secrets are found |
| `config-file` | No | — | Path to `.gitleaks.toml` config (uses global config if not set) |

**Example:**
```yaml
- name: GitLeaks Secret Scanning
  uses: taazaainc/TZ-DevOps-Global/.github/actions/gitleaks-scan@master
  with:
    service-name: ${{ matrix.service.name }}
```

---

## Variables & Secrets Strategy

| Value | Where to store | Why |
|-------|---------------|-----|
| `TRIVY_IMAGE` | Org-level variable (`vars.TRIVY_IMAGE`) | All repos get private mirror automatically; repo-level overrides if needed |
| `DOTNET_CONTAINER_IMAGE` | Repo-level variable | Project-specific .NET + sonar-scanner image |
| `SONAR_NODEJS_IMAGE` | Repo-level variable | Project-specific Node.js scanner image |
| `SONAR_TOKEN` | Repo or org secret | SonarQube auth token |
| `SONAR_HOST_URL` | Repo or org secret | SonarQube server URL |
| `TCR_USERNAME` / `TCR_PASSWORD` | Repo or org secret | Container registry credentials |

**Variable precedence:** Repo-level → Org-level → Workflow default. Moving a variable from repo to org level requires no pipeline code changes.

---

## Versioning

All pipelines reference `@master`. When making a breaking change:
1. Tag master (e.g. `v2`) after the change
2. Update consuming repos to reference `@v2`

Non-breaking changes: push to master — all repos pick it up automatically.

---

## Runner Requirements

| Component | Requirements |
|-----------|-------------|
| `check-for-changes` | `git`, `jq` |
| `code-quality-security` | Docker socket (`/var/run/docker.sock`), `jq`, `curl`; runs inside container (`dotnet_container_image`) |
| `github-restrictions` | None — runs on any runner |
| `trivy-scan` | Docker socket, image must be pre-built before calling |
| `gitleaks-scan` | `wget`, `tar`, `jq` — downloads gitleaks binary automatically |
