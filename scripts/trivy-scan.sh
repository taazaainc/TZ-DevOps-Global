#!/usr/bin/env bash
# Trivy scan of a built image (+ optional repo scans). Called by .github/actions/trivy-scan. Fails closed.
#
# WHAT BLOCKS: only fixable image vulnerabilities at GATE_SEVERITY (default CRITICAL,HIGH), plus a tool or
# database failure (fails closed). Everything else is report-only unless explicitly switched to "block".
#
#  1. Vulnerability database: downloaded explicitly (retries); the job FAILS if it cannot be updated or
#     is older than MAX_DB_AGE_HOURS. Fresh per-job cache (Trivy locks a shared cache, and a shared
#     cache could carry state from another repo's job).
#  2. Image vulnerabilities: gate = fixable findings at GATE_SEVERITY. Unfixed findings are counted but
#     do not block.
#  3. Image secrets: IMAGE_SECRETS off|report|block (default OFF; Gitleaks is the secret scanner).
#  4. Repo filesystem (dependency lock files): FS_SCAN off|report|block (default report).
#  5. Repo configuration (Dockerfile, Helm, Kubernetes): MISCONFIG off|report (default report).
# The ignore list comes from THIS central repo (policy/trivy). Trivy runs from a neutral folder so it
# never reads trivy.yaml, .trivyignore or trivy-secret.yaml from the scanned repo.
#
# Env in: IMAGE SERVICE REPO MODE(block|warn) GATE_SEVERITY IMAGE_SECRETS FS_SCAN MISCONFIG SCAN_PATH
#         MAX_DB_AGE_HOURS POLICY_DIR WORKSPACE  [DB_REPOSITORY]
set -uo pipefail

MODE="${MODE:-block}"; GATE="${GATE_SEVERITY:-CRITICAL,HIGH}"; SERVICE="${SERVICE:-service}"
IMAGE_SECRETS="${IMAGE_SECRETS:-off}"; FS_SCAN="${FS_SCAN:-report}"; MISCONFIG="${MISCONFIG:-report}"
SCAN_PATH="${SCAN_PATH:-.}"; MAX_AGE="${MAX_DB_AGE_HOURS:-48}"; WORKSPACE="${WORKSPACE:-$PWD}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$MODE" = "warn" ] && { [ "$IMAGE_SECRETS" = block ] && IMAGE_SECRETS=report; [ "$FS_SCAN" = block ] && FS_SCAN=report; }

WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/trivy.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export TRIVY_CACHE_DIR="$WORK/cache"; export TRIVY_NO_PROGRESS=true TRIVY_SKIP_VERSION_CHECK=true
cd "$WORK"                                                   # neutral working folder (see header)

IGN="$POLICY_DIR/${REPO//\//__}.trivyignore.yaml"; [ -f "$IGN" ] || IGN="$POLICY_DIR/_default.trivyignore.yaml"
[ -f "$IGN" ] || { echo "::error::central Trivy ignore list missing"; exit 1; }
case "$SCAN_PATH" in *..*) echo "::error::scan-path must stay inside the workspace"; exit 1 ;; esac
RC=0
bad() { if [ "$MODE" = "block" ]; then echo "::error::$1"; RC=1; else echo "::warning::$1 (mode=warn, not blocking)"; fi; }
SEV="$(printf '%s' "$GATE" | jq -Rc 'split(",")')"

# aligned text table: first TSV line is the header
table() { awk -F'\t' '{for(i=1;i<=NF;i++){if(length($i)>w[i])w[i]=length($i);c[NR,i]=$i} n=NR; if(NF>m)m=NF}
  END{for(r=1;r<=n;r++){l="";for(i=1;i<=m;i++)l=l sprintf("%-*s  ",w[i],c[r,i]); print "  " l;
      if(r==1){s="";for(i=1;i<=m;i++){t="";for(k=0;k<w[i];k++)t=t"-";s=s t "  "} print "  " s}}}'; }
# markdown table for the job summary: first TSV line is the header
mdtable() { awk -F'\t' '{l="|";for(i=1;i<=NF;i++)l=l " " $i " |"; print l; if(NR==1){s="|";for(i=1;i<=NF;i++)s=s "---|"; print s}}'; }

command -v trivy >/dev/null || { echo "::error::trivy is not installed"; exit 1; }
echo "Trivy $(trivy --version | head -n1 | sed 's/Version: //') | service $SERVICE | blocks on: fixable $GATE image vulnerabilities | mode: $MODE"
echo "Ignore list: $(basename "$IGN") | image secrets: $IMAGE_SECRETS | repo dependencies: $FS_SCAN | configuration: $MISCONFIG"

# ---- 1) database: must succeed and be fresh
echo "::group::Vulnerability database"
ok=0
for i in 1 2 3; do
  trivy image --download-db-only --no-progress ${DB_REPOSITORY:+--db-repository "$DB_REPOSITORY"} 2>&1 | grep -v -E '^[[:space:]]*$|[[:space:]]INFO[[:space:]]'
  [ "${PIPESTATUS[0]}" = 0 ] && { ok=1; break; }      # Trivy's own exit code (grep exits 1 when it filters every line)
  echo "DB download attempt $i failed"; sleep $((i*10))
done
[ "$ok" = 1 ] || { echo "::endgroup::"; echo "::error::Trivy vulnerability database could not be downloaded; failing closed"; exit 1; }
META="$TRIVY_CACHE_DIR/db/metadata.json"
[ -f "$META" ] || { echo "::endgroup::"; echo "::error::Trivy DB metadata missing; failing closed"; exit 1; }
UPDATED="$(jq -r '.UpdatedAt' "$META")"
AGE_H="$(jq -r '((now - (.UpdatedAt | sub("\\.[0-9]+";"") | fromdateiso8601)) / 3600 | floor)' "$META")" \
  || { echo "::endgroup::"; echo "::error::cannot read DB age; failing closed"; exit 1; }
echo "Database updated $UPDATED (${AGE_H}h ago, limit ${MAX_AGE}h)"
echo "::endgroup::"
[ "$AGE_H" -le "$MAX_AGE" ] || { echo "::error::Trivy DB is ${AGE_H}h old (limit ${MAX_AGE}h); failing closed"; exit 1; }
{ echo "### Trivy: $SERVICE"; echo "Database updated ${AGE_H}h ago. Blocks on fixable $GATE image vulnerabilities only."; } >> "$SUMMARY"

# ---- 2) image vulnerabilities (the only blocking check by default)
ALLSEV="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
echo "::group::Image vulnerabilities"
trivy image --image-src docker --scanners vuln --pkg-types os,library --severity "$ALLSEV" \
  --ignorefile "$IGN" --skip-db-update --timeout 15m --format json --output "$WORK/vuln.json" "$IMAGE" 2>&1 | grep -v -E '^[[:space:]]*$|[[:space:]]INFO[[:space:]]'
R="${PIPESTATUS[0]}"
if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/vuln.json" >/dev/null 2>&1; then
  echo "::endgroup::"; bad "Trivy image scan failed to run (exit $R); failing closed"
else
  CRIT_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$WORK/vuln.json")"
  HIGH_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$WORK/vuln.json")"
  GATED="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")] | length' "$WORK/vuln.json")"
  echo "Counts by severity (all findings, and how many have a fix available):"
  { printf 'SEVERITY\tTOTAL\tFIX AVAILABLE\tBLOCKS?\n'
    for s in CRITICAL HIGH MEDIUM LOW UNKNOWN; do
      jq -r --arg s "$s" --argjson g "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity==$s)] as $v | [$s, ($v|length), ([$v[]|select((.FixedVersion//"")!="")]|length), (if ($g|index($s)) then "yes (if fixable)" else "no" end)] | @tsv' "$WORK/vuln.json"
    done; } | table
  if [ "$GATED" -gt 0 ]; then
    echo; echo "Blocking findings (fixable $GATE):"
    jq -r --argjson s "$SEV" '["SEVERITY","CVE","PACKAGE","INSTALLED","FIXED IN"], (.Results[]? | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "") | [.Severity, .VulnerabilityID, (.PkgName|.[0:34]), (.InstalledVersion|.[0:22]), (.FixedVersion|.[0:30])]) | @tsv' "$WORK/vuln.json" | { IFS= read -r h; { echo "$h"; sort -u; } | table; }
    { echo; echo "**Blocking findings (fixable $GATE)**"; echo
      jq -r --argjson s "$SEV" '["Severity","CVE","Package","Installed","Fixed in"], (.Results[]? | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "") | [.Severity, .VulnerabilityID, .PkgName, .InstalledVersion, .FixedVersion]) | @tsv' "$WORK/vuln.json" | { IFS= read -r h; { echo "$h"; sort -u | head -40; } | mdtable; }; } >> "$SUMMARY"
  else
    echo "No fixable $GATE vulnerabilities."
  fi
  echo "::endgroup::"
  [ -n "${GITHUB_OUTPUT:-}" ] && { echo "critical_count=$CRIT_ALL" >> "$GITHUB_OUTPUT"; echo "high_count=$HIGH_ALL" >> "$GITHUB_OUTPUT"; }
  echo "- image: CRITICAL=$CRIT_ALL HIGH=$HIGH_ALL; fixable at $GATE: **$GATED**" >> "$SUMMARY"
  [ "$GATED" -gt 0 ] && bad "Trivy found $GATED fixable $GATE vulnerabilities in the image of $SERVICE"
fi

# ---- 3) secrets baked into the image (off by default; Gitleaks is the secret scanner)
if [ "$IMAGE_SECRETS" != off ]; then
  echo "::group::Secrets inside the image"
  trivy image --image-src docker --scanners secret --secret-config "" --ignorefile "$IGN" \
    --timeout 15m --format json --output "$WORK/sec.json" "$IMAGE" >/dev/null 2>&1
  R=$?
  if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/sec.json" >/dev/null 2>&1; then
    echo "::endgroup::"; bad "Trivy image secret scan failed to run (exit $R); failing closed"
  else
    NS="$(jq '[.Results[]?.Secrets[]?] | length' "$WORK/sec.json")"; echo "Secrets found in the image: $NS"
    echo "- image secrets: **$NS**" >> "$SUMMARY"
    [ "$NS" -gt 0 ] && jq -r '["SEVERITY","RULE","FILE"], (.Results[]? | .Target as $t | .Secrets[]? | [.Severity, .RuleID, "\($t):\(.StartLine)"]) | @tsv' "$WORK/sec.json" | { IFS= read -r h; { echo "$h"; sort -u | head -30; } | table; }
    echo "::endgroup::"
    if [ "$NS" -gt 0 ]; then
      if [ "$IMAGE_SECRETS" = block ]; then bad "Trivy found $NS secret(s) baked into the image; rotate them and rebuild without them"
      else echo "::warning::Trivy found $NS secret(s) in the image (report only)"; fi
    fi
  fi
fi

# ---- 4) repo dependencies (lock files), report only unless FS_SCAN=block
TARGET="$WORKSPACE/$SCAN_PATH"
if [ "$FS_SCAN" != off ] && [ -d "$TARGET" ]; then
  echo "::group::Repo dependencies ($FS_SCAN)"
  trivy fs --scanners vuln --pkg-types library --severity "$ALLSEV" --ignorefile "$IGN" --skip-db-update \
    --timeout 15m --format json --output "$WORK/fs.json" "$TARGET" >/dev/null 2>&1
  R=$?
  if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/fs.json" >/dev/null 2>&1; then
    echo "::endgroup::"; [ "$FS_SCAN" = block ] && bad "Trivy repo scan failed to run (exit $R); failing closed" || echo "::warning::Trivy repo dependency scan failed to run (report only)"
  else
    NF="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")] | length' "$WORK/fs.json")"
    echo "Fixable $GATE dependency vulnerabilities: $NF"
    echo "- repo dependencies: fixable at $GATE **$NF** ($FS_SCAN)" >> "$SUMMARY"
    [ "$NF" -gt 0 ] && jq -r --argjson s "$SEV" '["SEVERITY","CVE","PACKAGE","INSTALLED","FIXED IN"], (.Results[]? | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "") | [.Severity, .VulnerabilityID, (.PkgName|.[0:34]), (.InstalledVersion|.[0:22]), (.FixedVersion|.[0:30])]) | @tsv' "$WORK/fs.json" | { IFS= read -r h; { echo "$h"; sort -u | head -30; } | table; }
    echo "::endgroup::"
    if [ "$NF" -gt 0 ] && [ "$FS_SCAN" = block ]; then bad "Trivy found $NF fixable $GATE dependency vulnerabilities in the repo"; fi
  fi
fi

# ---- 5) configuration (report only), grouped by rule so it stays short
if [ "$MISCONFIG" != off ] && [ -d "$TARGET" ]; then
  echo "::group::Configuration issues (HIGH/CRITICAL, report only)"
  trivy fs --scanners misconfig --severity HIGH,CRITICAL --ignorefile "$IGN" --timeout 10m \
    --format json --output "$WORK/mis.json" "$TARGET" >/dev/null 2>&1
  if [ "$?" -eq 0 ] && jq -e '.SchemaVersion' "$WORK/mis.json" >/dev/null 2>&1; then
    NM="$(jq '[.Results[]?.Misconfigurations[]?] | length' "$WORK/mis.json")"
    echo "Configuration issues: $NM (grouped by rule)"
    echo "- configuration issues HIGH/CRITICAL (report only): $NM" >> "$SUMMARY"
    [ "$NM" -gt 0 ] && jq -r '["SEVERITY","RULE","FILES","WHAT"], ([.Results[]? | .Target as $t | .Misconfigurations[]? | {id:.ID,sev:.Severity,t:$t,title:.Title}] | group_by(.id)[] | [.[0].sev, .[0].id, (length|tostring), (.[0].title|.[0:60])]) | @tsv' "$WORK/mis.json" | { IFS= read -r h; { echo "$h"; sort -t$'\t' -k1,1 -k3,3nr | head -15; } | table; }
  else
    echo "Trivy configuration scan did not run (report only)"
  fi
  echo "::endgroup::"
fi

[ "$RC" -eq 0 ] && echo "Trivy: gate passed" || echo "Trivy: gate FAILED"
exit "$RC"
