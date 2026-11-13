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
# The job log has the full detail (plain tables). The job summary gets a short card for developers
# (see card-lib.sh): one status line, then the worst findings and where they come from.
#
# Env in: IMAGE SERVICE REPO MODE(block|warn) GATE_SEVERITY IMAGE_SECRETS FS_SCAN MISCONFIG SCAN_PATH
#         MAX_DB_AGE_HOURS POLICY_DIR WORKSPACE  [DB_REPOSITORY]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/card-lib.sh"

MODE="${MODE:-block}"; GATE="${GATE_SEVERITY:-CRITICAL,HIGH}"; SERVICE="${SERVICE:-service}"
IMAGE_SECRETS="${IMAGE_SECRETS:-off}"; FS_SCAN="${FS_SCAN:-report}"; MISCONFIG="${MISCONFIG:-report}"
SCAN_PATH="${SCAN_PATH:-.}"; MAX_AGE="${MAX_DB_AGE_HOURS:-48}"; WORKSPACE="${WORKSPACE:-$PWD}"
[ "$MODE" = "warn" ] && { [ "$IMAGE_SECRETS" = block ] && IMAGE_SECRETS=report; [ "$FS_SCAN" = block ] && FS_SCAN=report; }

WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/trivy.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
export TRIVY_CACHE_DIR="$WORK/cache"; export TRIVY_NO_PROGRESS=true TRIVY_SKIP_VERSION_CHECK=true
cd "$WORK"                                                   # neutral working folder (see header)

IGN="$POLICY_DIR/${REPO//\//__}.trivyignore.yaml"; [ -f "$IGN" ] || IGN="$POLICY_DIR/_default.trivyignore.yaml"
[ -f "$IGN" ] || { echo "::error::central Trivy ignore list missing"; card_row trivy "🔴" "Scan could not run (central ignore list missing)"; exit 1; }
case "$SCAN_PATH" in *..*) echo "::error::scan-path must stay inside the workspace"; card_row trivy "🔴" "Scan could not run (bad scan path)"; exit 1 ;; esac
RC=0
FAILICON="🔴"; [ "$MODE" = "block" ] || FAILICON="🟡"
bad() { if [ "$MODE" = "block" ]; then echo "::error::$1"; RC=1; else echo "::warning::$1 (mode=warn, not blocking)"; fi; }
SEV="$(printf '%s' "$GATE" | jq -Rc 'split(",")')"
# aligned text table: first TSV line is the header
table() { awk -F'\t' '{for(i=1;i<=NF;i++){if(length($i)>w[i])w[i]=length($i);c[NR,i]=$i} n=NR; if(NF>m)m=NF}
  END{for(r=1;r<=n;r++){l="";for(i=1;i<=m;i++)l=l sprintf("%-*s  ",w[i],c[r,i]); print "  " l;
      if(r==1){s="";for(i=1;i<=m;i++){t="";for(k=0;k<w[i];k++)t=t"-";s=s t "  "} print "  " s}}}' ; }

command -v trivy >/dev/null || { echo "::error::trivy is not installed"; card_row trivy "🔴" "Scan could not run (trivy missing)"; exit 1; }
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
[ "$ok" = 1 ] || { echo "::endgroup::"; echo "::error::Trivy vulnerability database could not be downloaded; failing closed"; card_row trivy "🔴" "Scan could not run (vulnerability database not available)"; exit 1; }
META="$TRIVY_CACHE_DIR/db/metadata.json"
[ -f "$META" ] || { echo "::endgroup::"; echo "::error::Trivy DB metadata missing; failing closed"; card_row trivy "🔴" "Scan could not run (vulnerability database problem)"; exit 1; }
UPDATED="$(jq -r '.UpdatedAt' "$META")"
AGE_H="$(jq -r '((now - (.UpdatedAt | sub("\\.[0-9]+";"") | fromdateiso8601)) / 3600 | floor)' "$META")" \
  || { echo "::endgroup::"; echo "::error::cannot read DB age; failing closed"; card_row trivy "🔴" "Scan could not run (vulnerability database problem)"; exit 1; }
echo "Database updated $UPDATED (${AGE_H}h ago, limit ${MAX_AGE}h)"
echo "::endgroup::"
[ "$AGE_H" -le "$MAX_AGE" ] || { echo "::error::Trivy DB is ${AGE_H}h old (limit ${MAX_AGE}h); failing closed"; card_row trivy "🔴" "Scan could not run (vulnerability database too old)"; exit 1; }

# ---- 2) image vulnerabilities (the only blocking check by default)
ALLSEV="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
echo "::group::Image vulnerabilities"
trivy image --image-src docker --scanners vuln --pkg-types os,library --severity "$ALLSEV" \
  --ignorefile "$IGN" --skip-db-update --timeout 15m --format json --output "$WORK/vuln.json" "$IMAGE" 2>&1 | grep -v -E '^[[:space:]]*$|[[:space:]]INFO[[:space:]]'
R="${PIPESTATUS[0]}"
if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/vuln.json" >/dev/null 2>&1; then
  echo "::endgroup::"; bad "Trivy image scan failed to run (exit $R); failing closed"
  card_row trivy "$FAILICON" "Scan could not run (see the log)"
else
  FIXABLE='select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "")'
  CRIT_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$WORK/vuln.json")"
  HIGH_ALL="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$WORK/vuln.json")"
  GATED="$(jq --argjson s "$SEV" "[.Results[]?.Vulnerabilities[]? | $FIXABLE] | length" "$WORK/vuln.json")"
  CF="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | select((.FixedVersion // "") != "")] | length' "$WORK/vuln.json")"
  HF="$(jq --argjson s "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH") | select((.FixedVersion // "") != "")] | length' "$WORK/vuln.json")"
  echo "Counts by severity (all findings, and how many have a fix available):"
  { printf 'SEVERITY\tTOTAL\tFIX AVAILABLE\tBLOCKS?\n'
    for s in CRITICAL HIGH MEDIUM LOW UNKNOWN; do
      jq -r --arg s "$s" --argjson g "$SEV" '[.Results[]?.Vulnerabilities[]? | select(.Severity==$s)] as $v | [$s, ($v|length), ([$v[]|select((.FixedVersion//"")!="")]|length), (if ($g|index($s)) then "yes (if fixable)" else "no" end)] | @tsv' "$WORK/vuln.json"
    done; } | table
  if [ "$GATED" -gt 0 ]; then
    echo; echo "Blocking findings (fixable $GATE):"
    jq -r --argjson s "$SEV" "[\"SEVERITY\",\"CVE\",\"PACKAGE\",\"INSTALLED\",\"FIXED IN\"], (.Results[]? | .Vulnerabilities[]? | $FIXABLE | [.Severity, .VulnerabilityID, (.PkgName|.[0:34]), (.InstalledVersion|.[0:22]), (.FixedVersion|.[0:30])]) | @tsv" "$WORK/vuln.json" | { IFS= read -r h; { echo "$h"; sort -u; } | table; }
    # ---- developer card: what to fix, worst first, and where it comes from
    OSN="$(jq --argjson s "$SEV" "[.Results[]? | select(.Class==\"os-pkgs\") | .Vulnerabilities[]? | $FIXABLE] | length" "$WORK/vuln.json")"
    APPN=$((GATED - OSN))
    EOSL="$(jq -r '.Metadata.OS // {} | if .EOSL then "\(.Family) \(.Name)" else empty end' "$WORK/vuln.json")"
    {
      echo "<details open><summary>What to fix ($GATED), worst first</summary>"; echo
      echo "| | CVE | Package | Installed | Fixed in |"; echo "|---|---|---|---|---|"
      jq -r --argjson s "$SEV" "[.Results[]? | .Vulnerabilities[]? | $FIXABLE] | unique_by(.VulnerabilityID+.PkgName) | sort_by(if .Severity==\"CRITICAL\" then 0 else 1 end, .PkgName) | .[0:15][] | \"| \" + (if .Severity==\"CRITICAL\" or .Severity==\"HIGH\" then \"🔴 \" else \"🟡 \" end) + .Severity + \" | \" + .VulnerabilityID + \" | \" + .PkgName + \" | \" + .InstalledVersion + \" | \" + .FixedVersion + \" |\"" "$WORK/vuln.json"
      [ "$GATED" -gt 15 ] && echo "| | | _and $((GATED - 15)) more: see the job log_ | | |"
      echo; echo "**Where they come from:** $OSN in operating-system packages of the base image, $APPN in app packages."
      [ -n "$EOSL" ] && echo "The base image OS ($EOSL) is no longer supported: upgrade the base image, that fixes most of the OS packages. App packages need a version update."
      echo "</details>"
    } | card_detail trivy
  else
    echo "No fixable $GATE vulnerabilities."
  fi
  echo "::endgroup::"
  [ -n "${GITHUB_OUTPUT:-}" ] && { echo "critical_count=$CRIT_ALL" >> "$GITHUB_OUTPUT"; echo "high_count=$HIGH_ALL" >> "$GITHUB_OUTPUT"; }
  if [ "$GATED" -gt 0 ]; then
    ICON="🔴"; [ "$MODE" = "block" ] || ICON="🟡"
    card_row trivy "$ICON" "$GATED to fix: $CF critical, $HF high"
    bad "Trivy found $GATED fixable $GATE vulnerabilities in the image of $SERVICE"
  else
    card_row trivy "🟢" "No fixable critical or high vulnerabilities"
  fi
fi

# ---- 3) secrets baked into the image (off by default; Gitleaks is the secret scanner)
if [ "$IMAGE_SECRETS" != off ]; then
  echo "::group::Secrets inside the image"
  trivy image --image-src docker --scanners secret --secret-config "" --ignorefile "$IGN" \
    --timeout 15m --format json --output "$WORK/sec.json" "$IMAGE" >/dev/null 2>&1
  R=$?
  if [ "$R" -ne 0 ] || ! jq -e '.SchemaVersion' "$WORK/sec.json" >/dev/null 2>&1; then
    echo "::endgroup::"; bad "Trivy image secret scan failed to run (exit $R); failing closed"
    card_row trivy-secrets "$FAILICON" "Scan could not run (see the log)"
  else
    NS="$(jq '[.Results[]?.Secrets[]?] | length' "$WORK/sec.json")"; echo "Secrets found in the image: $NS"
    [ "$NS" -gt 0 ] && jq -r '["SEVERITY","RULE","FILE"], (.Results[]? | .Target as $t | .Secrets[]? | [.Severity, .RuleID, "\($t):\(.StartLine)"]) | @tsv' "$WORK/sec.json" | { IFS= read -r h; { echo "$h"; sort -u | head -30; } | table; }
    echo "::endgroup::"
    if [ "$NS" -gt 0 ]; then
      ICON="🔴"; [ "$IMAGE_SECRETS" = block ] || ICON="🟡"
      card_row trivy-secrets "$ICON" "$NS secret(s) inside the image. Rotate them and rebuild without them"
      if [ "$IMAGE_SECRETS" = block ]; then bad "Trivy found $NS secret(s) baked into the image; rotate them and rebuild without them"
      else echo "::warning::Trivy found $NS secret(s) in the image (report only)"; fi
    else
      card_row trivy-secrets "🟢" "No secrets inside the image"
    fi
  fi
fi

# ---- 4) repo dependencies (lock files), report only unless FS_SCAN=block (log only, not in the card)
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
    [ "$NF" -gt 0 ] && jq -r --argjson s "$SEV" '["SEVERITY","CVE","PACKAGE","INSTALLED","FIXED IN"], (.Results[]? | .Vulnerabilities[]? | select(.Severity as $x | $s | index($x)) | select((.FixedVersion // "") != "") | [.Severity, .VulnerabilityID, (.PkgName|.[0:34]), (.InstalledVersion|.[0:22]), (.FixedVersion|.[0:30])]) | @tsv' "$WORK/fs.json" | { IFS= read -r h; { echo "$h"; sort -u | head -30; } | table; }
    echo "::endgroup::"
    if [ "$NF" -gt 0 ] && [ "$FS_SCAN" = block ]; then bad "Trivy found $NF fixable $GATE dependency vulnerabilities in the repo"; fi
  fi
fi

# ---- 5) configuration (report only, log only), grouped by rule so it stays short
if [ "$MISCONFIG" != off ] && [ -d "$TARGET" ]; then
  echo "::group::Configuration issues (HIGH/CRITICAL, report only)"
  trivy fs --scanners misconfig --severity HIGH,CRITICAL --ignorefile "$IGN" --timeout 10m \
    --format json --output "$WORK/mis.json" "$TARGET" >/dev/null 2>&1
  if [ "$?" -eq 0 ] && jq -e '.SchemaVersion' "$WORK/mis.json" >/dev/null 2>&1; then
    NM="$(jq '[.Results[]?.Misconfigurations[]?] | length' "$WORK/mis.json")"
    echo "Configuration issues: $NM (grouped by rule)"
    [ "$NM" -gt 0 ] && jq -r '["SEVERITY","RULE","FILES","WHAT"], ([.Results[]? | .Target as $t | .Misconfigurations[]? | {id:.ID,sev:.Severity,t:$t,title:.Title}] | group_by(.id)[] | [.[0].sev, .[0].id, (length|tostring), (.[0].title|.[0:60])]) | @tsv' "$WORK/mis.json" | { IFS= read -r h; { echo "$h"; sort -t$'\t' -k1,1 -k3,3nr | head -15; } | table; }
  else
    echo "Trivy configuration scan did not run (report only)"
  fi
  echo "::endgroup::"
fi

[ "$RC" -eq 0 ] && echo "Trivy: gate passed" || echo "Trivy: gate FAILED"
exit "$RC"
