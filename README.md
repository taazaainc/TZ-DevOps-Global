# TZ-DevOps-Global

Centralized GitHub Actions and reusable workflows for Taazaa DevOps pipelines.
Logic that is **identical across all repos** lives here — reference it from any repo's workflow instead of duplicating code.

> **This repository is public.** Never commit credentials, internal hostnames, registry or image names, project or customer names, IP addresses or run ids. Callers pass those as variables and secrets. Every change goes through a pull request approved by a DevOps owner (CODEOWNERS).

---

## What's Here

| Type | Name | Path | Purpose |
|------|------|------|---------|
| Composite Action | `github-restrictions` | `.github/actions/github-restrictions` | PR gate: branch naming + forbidden file detection + PR size limits |
| Composite Action | `gitleaks-scan` | `.github/actions/gitleaks-scan` | Secret scanning via Gitleaks (latest push and the PR's net change, central config and exceptions) |
| Composite Action | `trivy-scan` | `.github/actions/trivy-scan` | Container image vulnerability scan via Trivy (blocks fixable CRITICAL and HIGH) |
| Composite Action | `sonar-scan-cli` | `.github/actions/sonar-scan-cli` | SonarQube analysis with the official SonarScanner CLI image (pinned), for any non-.NET language; coverage reports picked up automatically |
| Composite Action | `sonar-quality-gate` | `.github/actions/sonar-quality-gate` | Waits for THIS run's Sonar analysis and checks its quality gate (fails closed) |
| Composite Action | `scan-card` | `.github/actions/scan-card` | One short result card per service on the job summary page |
| Composite Action | `validate-branch` | `.github/actions/validate-branch` | Branch naming only (lightweight, use github-restrictions instead) |
| Reusable Workflow | `check-for-changes` | `.github/workflows/check-for-changes.yml` | Incremental change detection — outputs JSON list of changed services |
| Reusable Workflow | `code-quality-security` | `.github/workflows/code-quality-security.yml` | Gitleaks, then Trivy, then SonarQube, per changed service (matrix) |

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

Runs GitLeaks, a Docker build with a Trivy scan, and SonarQube analysis for each changed service (matrix). **Order: GitLeaks, then Trivy, then Sonar.** Each security scan runs even if an earlier step failed, so a failing Sonar can never hide a secret or vulnerability result; the job still ends red if any step failed. Includes a stable `Scan Summary` job suitable for use as a required branch ruleset check.

**Inputs:**

| Input | Required | Description |
|-------|----------|-------------|
| `runner` | No | JSON array of runner labels |
| `changed_services` | No | JSON array from `check-for-changes` output. Pass `[]` to skip. |
| `base_container_image` | Yes | Job container image (.NET SDK, docker CLI). Store as `vars.BASE_CONTAINER_IMAGE` in the caller. |
| `sonar_nodejs_image` | No | **Deprecated**: accepted but no longer used. Non-.NET services are scanned with the official SonarScanner CLI image pinned in `policy/tool-versions.env`. |
| `sonar_java_image` | No | Docker image for Java SonarQube scanning (only for services with `scanner_type: "java"`). |
| `fail-on-critical` | No | Controls whether Trivy CRITICAL CVEs block the pipeline. See **Enabling / Disabling Trivy & GitLeaks blocking** below. |
| `fail-on-secrets` | No | Controls whether GitLeaks secret findings block the pipeline. See **Enabling / Disabling Trivy & GitLeaks blocking** below. |

**Secrets required:**

| Secret | Description |
|--------|-------------|
| `SONAR_TOKEN` | SonarQube authentication token |
| `SONAR_HOST_URL` | SonarQube server URL |
| `TCR_USERNAME` | Container registry username (for pulling build container + Trivy image) |
| `TCR_PASSWORD` | Container registry password |
| `PRE_BUILD_AWS_ACCESS_KEY_ID` / `PRE_BUILD_AWS_SECRET_ACCESS_KEY` | Optional: only for repos whose pre-build hook downloads files before the Docker build |
| `NEXUS_USERNAME` / `NEXUS_PASSWORD` | Optional: only for Java services that pull from a private Nexus |

**Tool versions and exceptions are central:** Gitleaks and Trivy are installed fresh in every job from `policy/tool-versions.env` (pinned versions, SHA256 verified). The SonarScanner CLI image is pinned by digest in the same file. Ignore lists live in `policy/` (see `policy/README.md`). `vars.TRIVY_IMAGE` and `vars.SONAR_NODEJS_IMAGE` are no longer used.

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

- Omit `scanner_type` (or set `null`) → .NET scanning path (sonar-scanner via dotnet, in the job container)
- `scanner_type: "nodejs"`, `"generic"`, `"python"` or `"go"` → the official SonarScanner CLI (`sonar-scan-cli` action). It analyses JavaScript/TypeScript (Angular, React, Node), Python, Go, PHP, Ruby, HTML/CSS, YAML, Docker and more from source, with no image per language
- `scanner_type: "java"` → Java scanning path with `sonar_java_image`

**SonarQube analysis for non-.NET services (`sonar-scan-cli`):**
- Same analysis settings for every service: project key and name (`sonar_key`), sources (`project_path`), project version (branch and run number), git SCM.
- **Coverage is automatic**: when the tests wrote `lcov.info` (JS/TS), `coverage.xml` (Python, Cobertura) or `coverage.out` (Go) anywhere under the service folder, it is passed to Sonar. Without tests the scan still runs, without coverage. No change in the calling repo is needed when teams add tests.
- **Isolation**: the scanner runs in a throwaway container as a non-root user with all Linux capabilities dropped and `no-new-privileges`. No host folder is mounted: the code is streamed into the container (without `node_modules`), and only the scanner's report comes back. The token is passed by environment name, never on a command line.
- A failed scan fails the step and shows on the result card. The quality gate step then checks the gate of **this** run's analysis (it waits for Sonar to finish processing; no fixed sleep).
- To move to a newer scanner: update `SONAR_SCANNER_CLI_IMAGE` (tag and digest) in `policy/tool-versions.env` through a pull request.

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
    base_container_image: ${{ vars.BASE_CONTAINER_IMAGE }}
    # sonar_nodejs_image is no longer needed (still accepted, ignored)
    # fail-on-critical: 'false'  # override only if you need to bypass CRITICAL blocking for this repo
    # fail-on-secrets: 'false'   # override only if you need to bypass secret detection blocking for this repo
  secrets:
    SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
    SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
    TCR_USERNAME: ${{ secrets.TCR_USERNAME }}
    TCR_PASSWORD: ${{ secrets.TCR_PASSWORD }}
```

**Enabling / Disabling Trivy & GitLeaks blocking:**

The org-wide default for both is **blocking (`true`)**. There are two ways to change this:

**Option A — Disable org-wide (affects ALL repos):**

Edit `code-quality-security.yml` in this repo. Find these two lines and change `'true'` → `'false'`:

```yaml
# Line ~278 — Trivy
fail-on-critical: ${{ inputs.fail-on-critical || 'true' }}

# Line ~289 — GitLeaks
fail-on-secrets: ${{ inputs.fail-on-secrets || 'true' }}
```

Effect: All repos stop being blocked by Trivy CRITICALs / GitLeaks secrets. Scans still run and are reported in the job log and summary, but the pipeline does not fail.

**Option B — Bypass for ONE specific repo only:**

In that repo's caller workflow, pass the override explicitly under `with:`:

```yaml
code-quality-security:
  uses: taazaainc/TZ-DevOps-Global/.github/workflows/code-quality-security.yml@master
  with:
    ...
    fail-on-critical: 'false'   # ← bypasses Trivy blocking for this repo only
    fail-on-secrets: 'false'    # ← bypasses GitLeaks blocking for this repo only
```

Effect: Only this repo is bypassed. All other repos still enforce blocking.

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

Scans a pre-built **local** Docker image with Trivy. Fails closed. Settings, version and ignore list are central; nothing is read from the scanned repo.

- Vulnerability database is downloaded in the job; the job fails if the download fails or the DB is older than `max-db-age-hours`.
- Blocks **only** on fixable CRITICAL and HIGH image vulnerabilities (`gate-severity`), or when Trivy or its database fail. Unfixed findings are counted but do not block. Secrets in the image are off by default (`image-secrets`).
- Also reports dependency vulnerabilities from the repo's lock files (`fs-scan`) and Dockerfile / Helm / Kubernetes configuration issues (`misconfig`).
- Ignore list: `policy/trivy/<owner>__<repo>.trivyignore.yaml` (entries need an expiry date).
- Use an image tag that is unique per job (the reusable workflow uses `scan-<run id>-<attempt>-<job index>`).

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `image-name` | Yes | — | Full local image name with tag |
| `service-name` | Yes | — | Used in messages |
| `fail-on-critical` | No | `true` | `true` blocks, `false` only warns (name kept for compatibility) |
| `gate-severity` | No | `CRITICAL,HIGH` | Severities that block (fixable findings only) |
| `image-secrets` | No | `off` | `off` / `report` / `block` (Gitleaks is the secret scanner) |
| `fs-scan` | No | `report` | `off` / `report` / `block` |
| `misconfig` | No | `report` | `off` / `report` |
| `scan-path` | No | `.` | Folder in the workspace for the repo scans |
| `max-db-age-hours` | No | `48` | Fail if the database is older |
| `severity`, `trivy-image`, `registry`, `registry-username`, `registry-password` | No | — | **Deprecated, ignored** |

**Example:**
```yaml
- name: Trivy Security Scan
  uses: taazaainc/TZ-DevOps-Global/.github/actions/trivy-scan@master
  with:
    image-name: "${{ matrix.service.image_name }}:${{ env.SCAN_IMAGE_TAG }}"
    service-name: ${{ matrix.service.name }}
    scan-path: ${{ matrix.service.context_path || '.' }}
```

---

### gitleaks-scan

Scans the commits of a pull request for secrets. Fails closed. Version, config and ignore list are central; a repo-local `.gitleaks.toml`, `.gitleaksignore` or inline `gitleaks:allow` is not accepted.

- First scan of a PR (opened, reopened, or after a force-push): the whole PR (`base..head`).
- Later pushes: only the commits of that push, so a secret that was found, fixed and pushed again does not block twice.
- Every run also scans the files the PR changes (net change), so nothing unscanned can be merged.
- When a secret is found: **rotate it first**; removing it from the file does not undo the exposure.
- Ignore list: `policy/gitleaks/<owner>__<repo>/.gitleaksignore` (add only after the secret is rotated).

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `service-name` | Yes | — | Used in messages |
| `fail-on-secrets` | No | `true` | `true` blocks, `false` only warns |
| `gitleaks-version`, `config-file` | No | — | **Deprecated, ignored** (version and config are central) |

**Example:**
```yaml
- name: GitLeaks Secret Scanning
  uses: taazaainc/TZ-DevOps-Global/.github/actions/gitleaks-scan@master
  with:
    service-name: ${{ matrix.service.name }}
```

---

### sonar-quality-gate

Checks the SonarQube quality gate **of the analysis this run just submitted**. It replaces "sleep 30 seconds, then read the project status", which could return the status of an older analysis while Sonar was still processing the new report.

How it works (same flow as SonarSource's own quality-gate action):
1. Reads the `report-task.txt` the scanner wrote in this run (must be newer than the job's Sonar start marker, and match the project key).
2. Polls the background task (`api/ce/task`) until it is `SUCCESS`, `FAILED` or `CANCELED` (default limit 600 s).
3. Takes the `analysisId` of that task and reads the gate of exactly that analysis (`api/qualitygates/project_status?analysisId=`).
4. `OK` passes, `WARN` passes with a warning, `ERROR` fails and lists the failed conditions; anything else (no gate on the project, unknown, timeout, missing report, server unreachable) **fails**.

Needs `SONAR_TOKEN` and `SONAR_HOST_URL` in the job environment.

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `project-key` | Yes | — | Sonar project key of the service |
| `service-name` | No | — | Used in messages |
| `timeout-seconds` | No | `600` | Maximum wait for Sonar to process the report |
| `fail-on-gate` | No | `true` | `false` only warns |

---

### scan-card

Publishes one short result card per service on the run's summary page, for developers: one status line per check (🟢 passed, 🔴 failed or critical/high, 🟡 warning), then only what to fix (worst findings first, and where they come from). No tool versions or policy text; those stay in the job log. Use `mode: init` at the start of the job and `mode: publish` at the end with `if: always()`. The scan actions fill the card themselves.

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
