#!/usr/bin/env bash
# Trivy scan of a built image (+ optional repo scans). Called by .github/actions/trivy-scan. Fails closed.
#
#  1. Vulnerability database: downloaded explicitly (retries); the job FAILS if it cannot be updated or
#     is older than MAX_DB_AGE_HOURS. Fresh per-job cache (Trivy locks a shared cache, and a shared
#     cache could carry state from another repo's job).
#  2. Image vulnerabilities: gate = fixable findings at GATE_SEVERITY (default CRITICAL,HIGH).
#     Unfixed findings are listed for people but do not block.
#  3. Image secrets (files baked into layers, e.g. .env): blocks.
#  4. Repo filesystem (dependency lock files): FS_SCAN off|report|block (default report).
#  5. Repo configuration (Dockerfile, Helm, Kubernetes): MISCONFIG off|report (default report).
# The ignore list comes from THIS central repo (policy/trivy). Trivy runs from a neutral folder so it
# never reads trivy.yaml, .trivyignore or trivy-secret.yaml from the scanned repo.
#
# Env in: IMAGE SERVICE REPO MODE(block|warn) GATE_SEVERITY IMAGE_SECRETS FS_SCAN MISCONFIG SCAN_PATH
#         MAX_DB_AGE_HOURS POLICY_DIR WORKSPACE  [DB_REPOSITORY]
set -uo pipefail

MODE="${MODE:-block}"; GATE="${GATE_SEVERITY:-CRITICAL,HIGH}"; SERVICE="${SERVICE:-service}"
IMAGE_SECRETS="${IMAGE_SECRETS:-block}"; FS_SCAN="${FS_SCAN:-report}"; MISCONFIG="${MISCONFIG:-report}"
SCAN_PATH="${SCAN_PATH:-.}"; MAX_AGE="${MAX_DB_AGE_HOURS:-48}"; WORKSPACE="${WORKSPACE:-$PWD}"
[ "$MODE" = "warn" ] && { IMAGE_SECRETS=report; [ "$FS_SCAN" = block ] && FS_SCAN=report; }

WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/trivy.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export TRIVY_CACHE_DIR="$WORK/cache"; export TRIVY_NO_PROGRESS=true
cd "$WORK"                                                   # neutral working folder (see header)

IGN="$POLICY_DIR/${REPO//\//__}.trivyignore.yaml"; [ -f "$IGN" ] || IGN="$POLICY_DIR/_default.trivyignore.yaml"
[ -f "$IGN" ] || { echo "::error::central Trivy ignore list missing"; exit 1; }
case "$SCAN_PATH" in *..*) echo "::error::scan-path must stay inside the workspace"; exit 1 ;; esac
RC=0
bad() { if [ "$MODE" = "block" ]; then echo "::error::$1"; RC=1; else echo "::warning::$1 (mode=warn, not blocking)"; fi; }
sev_json() { printf '%s' "$1" | jq -Rc 'split(",")'; }
SEV="$(sev_json "$GATE")"

command -v trivy >/dev/null || { echo "::error::trivy is not installed"; exit 1; }
echo "Trivy: $(trivy --version | head -n1) | gate: $GATE (fixable) | ignore list: $(basename "$IGN") | mode: $MODE"

# ---- 1) database: must succeed and be fresh
ok=0
for i in 1 2 3; do
  if trivy image --download-db-only --no-progress ${DB_REPOSITORY:+--db-repository "$DB_REPOSITORY"}; then ok=1; break; fi
  echo "DB download attempt $i failed"; sleep $((i*10))
done
[ "$ok" = 1 ] || { echo "::error::Trivy vulnerability database could not be downloaded; failing closed"; exit 1; }
META="$TRIVY_CACHE_DIR/db/metadata.json"
[ -f "$META" ] || { echo "::error::Trivy DB metadata missing; failing closed"; exit 1; }
UPDATED="$(jq -r '.UpdatedAt' "$META")"
AGE_H="$(jq -r '((now - (.UpdatedAt | sub("\\.[0-9]+";"") | fromdateiso8601)) / 3600 | floor)' "$META")" \
  || { echo "::error::cannot read DB age; failing closed"; exit 1; }
echo "Trivy DB updated $UPDATED (${AGE_H}h ago, limit ${MAX_AGE}h)"
[ "$AGE_H" -le "$MAX_AGE" ] || { echo "::error::Trivy DB is ${AGE_H}h old (limit ${MAX_AGE}h); failing closed"; exit 1; }
{ echo "### Trivy: $SERVICE"; echo "- DB updated $UPDATED (${AGE_H}h ago)"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# ---- 2) image vulnerabilities
ALLSEV="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
trivy image --image-src docker --scanners vuln --pkg-types os,library --severity "$ALLSEV" \
  --ignorefile "$IGN" --skip-db-update --timeout 15m --format json --output "$WORK/vuln.json" "$IMAGE"
R=$?
if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/vuln.json" >/dev/null 2>&1; then
  bad "Trivy image scan failed to run (exit $R); failing closed"
else
  CRIT_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$WORK/vuln.json")"
  HIGH_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$WORK/vuln.json")"
  GATED="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")] | length' "$WORK/vuln.json")"
  echo "Image vulnerabilities: CRITICAL=$CRIT_ALL HIGH=$HIGH_ALL (all) | fixable at $GATE: $GATED"
  echo "- image: CRITICAL=$CRIT_ALL HIGH=$HIGH_ALL; fixable at $GATE: **$GATED**" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [ -n "${GITHUB_OUTPUT:-}" ] && { echo "critical_count=$CRIT_ALL" >> "$GITHUB_OUTPUT"; echo "high_count=$HIGH_ALL" >> "$GITHUB_OUTPUT"; }
  if [ "$GATED" -gt 0 ]; then
    jq -r --argjson s "$SEV" '.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")
        | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' "$WORK/vuln.json" | sort -u | head -60
    bad "Trivy found $GATED fixable $GATE vulnerabilities in $IMAGE"
  fi
fi

# ---- 3) secrets baked into the image
if [ "$IMAGE_SECRETS" != off ]; then
  trivy image --image-src docker --scanners secret --secret-config "" --ignorefile "$IGN" \
    --timeout 15m --format json --output "$WORK/sec.json" "$IMAGE"
  R=$?
  if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/sec.json" >/dev/null 2>&1; then
    bad "Trivy image secret scan failed to run (exit $R); failing closed"
  else
    NS="$(jq '[.Results[]?.Secrets[]?] | length' "$WORK/sec.json")"
    echo "Image secrets: $NS"
    echo "- image secrets: **$NS**" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    if [ "$NS" -gt 0 ]; then
      jq -r '.Results[]? | .Target as $t | .Secrets[]? | "  \(.Severity)\t\(.RuleID)\t\($t):\(.StartLine)"' "$WORK/sec.json" | sort -u | head -30
      if [ "$IMAGE_SECRETS" = block ]; then bad "Trivy found $NS secret(s) baked into the image; rotate them and rebuild without them"
      else echo "::warning::Trivy found $NS secret(s) in the image (report only)"; fi
    fi
  fi
fi

# ---- 4) repo dependencies (lock files)
TARGET="$WORKSPACE/$SCAN_PATH"
if [ "$FS_SCAN" != off ] && [ -d "$TARGET" ]; then
  trivy fs --scanners vuln --pkg-types library --severity "$ALLSEV" --ignorefile "$IGN" --skip-db-update \
    --timeout 15m --format json --output "$WORK/fs.json" "$TARGET"
  R=$?
  if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/fs.json" >/dev/null 2>&1; then
    [ "$FS_SCAN" = block ] && bad "Trivy repo scan failed to run (exit $R); failing closed" || echo "::warning::Trivy repo dependency scan failed to run (report only)"
  else
    NF="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")] | length' "$WORK/fs.json")"
    echo "Repo dependencies: fixable at $GATE: $NF ($FS_SCAN)"
    echo "- repo dependencies: fixable at $GATE **$NF** ($FS_SCAN)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    if [ "$NF" -gt 0 ]; then
      jq -r --argjson s "$SEV" '.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")
          | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)  [\($t)]"' "$WORK/fs.json" | sort -u | head -40
      if [ "$FS_SCAN" = block ]; then bad "Trivy found $NF fixable $GATE dependency vulnerabilities in the repo"
      else echo "::warning::Trivy found $NF fixable $GATE dependency vulnerabilities in the repo (report only)"; fi
    fi
  fi
fi

# ---- 5) configuration (report only)
if [ "$MISCONFIG" != off ] && [ -d "$TARGET" ]; then
  trivy fs --scanners misconfig --severity HIGH,CRITICAL --ignorefile "$IGN" --timeout 10m \
    --format json --output "$WORK/mis.json" "$TARGET"
  if [ "$?" -eq 0 ] && jq -e '.SchemaVersion' "$WORK/mis.json" >/dev/null 2>&1; then
    NM="$(jq '[.Results[]?.Misconfigurations[]?] | length' "$WORK/mis.json")"
    echo "Configuration issues (HIGH/CRITICAL, report only): $NM"
    echo "- configuration issues HIGH/CRITICAL (report only): $NM" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    [ "$NM" -gt 0 ] && jq -r '.Results[]? | .Target as $t | .Misconfigurations[]? | "  \(.Severity)\t\(.ID)\t\($t)  \(.Title)"' "$WORK/mis.json" | sort -u | head -20
  else
    echo "::warning::Trivy configuration scan did not run (report only)"
  fi
fi

[ "$RC" -eq 0 ] && echo "Trivy: gate passed" || echo "Trivy: gate FAILED"
exit "$RC"
