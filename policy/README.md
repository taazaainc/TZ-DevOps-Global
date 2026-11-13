# policy/: central security settings for every consuming repo

Everything here is read from THIS repo by the scan actions. A scanned repo cannot add its own
exceptions: config files inside the scanned repo (`.gitleaks.toml`, `.gitleaksignore`, `.trivyignore`,
`trivy.yaml`, `trivy-secret.yaml`, inline `gitleaks:allow`) are not used. Changes here need a pull
request approved by a DevOps owner (CODEOWNERS).

| File / folder | Purpose |
|---|---|
| `tool-versions.env` | Gitleaks and Trivy versions with their SHA256 (pinned), minimum versions, the SonarScanner CLI image pinned by digest, and the official Maven images (per Java version) used by the Java scan. Change only through a pull request |
| `trivy/_default.trivyignore.yaml` | Trivy ignore list used when a repo has no file of its own (empty) |
| `trivy/<owner>__<repo>.trivyignore.yaml` | Trivy exceptions for one repo, for example `myorg__my-service.trivyignore.yaml` |
| `gitleaks/_default/.gitleaksignore` | Gitleaks ignore list used when a repo has no folder of its own (empty) |
| `gitleaks/<owner>__<repo>/.gitleaksignore` | Gitleaks exceptions (fingerprints) for one repo |

## How a team asks for an exception
1. Open a pull request to this repo that adds ONE entry (below). Say who asks and why.
2. A DevOps owner reviews and approves. The entry is active for every pipeline run after the merge.
3. Exceptions always expire. Trivy stops honouring an entry after its `expired_at` date.

### Trivy (vulnerability, secret or misconfiguration id)
```yaml
vulnerabilities:
  - id: CVE-2024-12345
    statement: "No fixed package yet; not reachable from outside. Requested by <name>, ticket <id>"
    expired_at: 2027-01-31          # at most 90 days ahead
    # paths: ["usr/lib/foo"]        # optional: limit to files
```

### Gitleaks (a finding that is a false positive, or a real secret that was already ROTATED)
Add the fingerprint from the Gitleaks report to `gitleaks/<owner>__<repo>/.gitleaksignore`, with a comment above it:
```
# requested by <name>, ticket <id>, secret rotated on 2026-11-13, remove after 2027-01-31
<commit>:<file>:<rule>:<line>
```
Never add an entry for a secret that has not been rotated.

## Block or warn
The consuming workflow decides with `fail-on-critical` (Trivy) and `fail-on-secrets` (Gitleaks): `'true'` blocks
(the default), `'false'` only warns for that repo. Org-wide changes go through a PR to the default in the
reusable workflow.
