#!/usr/bin/env bash
# SonarQube quality gate check for THIS analysis. Replaces "sleep 30, then ask for the project status".
#
# Why: the project status is the result of the LATEST processed analysis. If Sonar is still processing
# this run's report, the old status (from an earlier run or another PR) comes back, so the check can
# pass or fail for the wrong reason. This script follows the documented flow instead:
#   1. read the scanner's report-task.txt (ceTaskUrl) written by THIS run
#   2. poll the background task (api/ce/task) until it is SUCCESS / FAILED / CANCELED
#   3. read the analysisId of that task and ask for the quality gate of THAT analysis
#   4. OK = pass, WARN = pass with a warning, ERROR = fail, anything else (no gate, unknown) = fail
# Same flow as SonarSource's own sonarqube-quality-gate-action.
#
# Env in: SONAR_TOKEN (required)  SONAR_HOST_URL (recommended: the host the runner can reach)
#         PROJECT_KEY  SERVICE  WORKSPACE  TIMEOUT_SEC (default 600)  MODE (block|warn)
#         REPORT_FILE (optional)  START_MARKER (optional file; the report must be newer than it)
set -uo pipefail

MODE="${MODE:-block}"; SERVICE="${SERVICE:-service}"; WORKSPACE="${WORKSPACE:-$PWD}"
TIMEOUT="${TIMEOUT_SEC:-600}"; SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt 0 ] || { echo "::error::invalid timeout '$TIMEOUT'"; exit 1; }

problem() {   # $1 message; blocks in block mode, warns in warn mode
  if [ "$MODE" = "block" ]; then echo "::error::$1"; return 1; fi
  echo "::warning::$1 (mode=warn, not blocking)"; return 0
}
[ -n "${SONAR_TOKEN:-}" ] || { echo "::error::SONAR_TOKEN is not set"; exit 1; }

# ---- 1) find the report written by this run
REPORT="${REPORT_FILE:-}"
if [ -z "$REPORT" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -n "${PROJECT_KEY:-}" ] && ! grep -q "^projectKey=${PROJECT_KEY}\r\?\$" "$f"; then continue; fi
    if [ -n "${START_MARKER:-}" ] && [ -f "$START_MARKER" ] && [ ! "$f" -nt "$START_MARKER" ]; then continue; fi
    REPORT="$f"; break
  done < <(find "$WORKSPACE" -name report-task.txt -not -path '*/node_modules/*' -print0 2>/dev/null | xargs -0 -r ls -t 2>/dev/null)
fi
if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  problem "No fresh Sonar report-task.txt found for project '${PROJECT_KEY:-?}': the scan did not produce a report, so the quality gate cannot be checked"; exit $?
fi
val() { sed -n "s/^$1=//p" "$REPORT" | head -n1 | tr -d '\r'; }
CE_URL="$(val ceTaskUrl)"; SERVER="$(val serverUrl)"; DASH="$(val dashboardUrl)"
[ -n "$CE_URL" ] || { problem "report-task.txt has no ceTaskUrl"; exit $?; }
if [ -n "${SONAR_HOST_URL:-}" ]; then          # use the host we can reach, keep the path the scanner gave us
  SERVER="${SONAR_HOST_URL%/}"; CE_URL="$SERVER/api${CE_URL##*api}"
fi
echo "Sonar report: $(basename "$(dirname "$REPORT")")/report-task.txt | project: ${PROJECT_KEY:-$(val projectKey)}"

api() { curl -fsS --retry 2 --retry-delay 2 --max-time 30 --user "${SONAR_TOKEN}:" "$1"; }

# ---- 2) wait for the background task of THIS analysis
deadline=$((SECONDS + TIMEOUT)); errs=0; status="UNKNOWN"; task=""
while :; do
  if task="$(api "$CE_URL" 2>/dev/null)"; then
    errs=0; status="$(jq -r '.task.status // "UNKNOWN"' <<<"$task" 2>/dev/null || echo UNKNOWN)"
  else
    errs=$((errs + 1)); status="UNREACHABLE"
  fi
  case "$status" in SUCCESS|FAILED|CANCELED) break ;; esac
  [ "$errs" -ge 6 ] && break
  [ "$SECONDS" -ge "$deadline" ] && break
  echo "Sonar background task: $status, waiting..."; sleep 5
done
case "$status" in
  SUCCESS) ;;
  FAILED)   problem "Sonar background task FAILED: $(jq -r '.task.errorMessage // "no message"' <<<"$task")"; exit $? ;;
  CANCELED) problem "Sonar background task was CANCELED"; exit $? ;;
  UNREACHABLE) problem "Sonar server not reachable (6 failed attempts)"; exit $? ;;
  *) problem "Sonar background task did not finish within ${TIMEOUT}s (last status: $status); quality gate result is unknown"; exit $? ;;
esac

# ---- 3) quality gate of THIS analysis
AID="$(jq -r '.task.analysisId // empty' <<<"$task")"
[ -n "$AID" ] || { problem "Sonar task finished without an analysisId"; exit $?; }
if ! resp="$(api "$SERVER/api/qualitygates/project_status?analysisId=${AID}" 2>/dev/null)"; then
  problem "could not read the quality gate of analysis $AID"; exit $?
fi
gate="$(jq -r '.projectStatus.status // "UNKNOWN"' <<<"$resp")"
echo "Quality gate of this analysis: $gate"
{ echo "### Sonar quality gate: $SERVICE"; echo "- status: **$gate** (analysis \`$AID\`)"; [ -n "$DASH" ] && echo "- dashboard: $DASH"; } >> "$SUMMARY"

case "$gate" in
  OK)   echo "Quality gate PASSED for $SERVICE"; exit 0 ;;
  WARN) echo "::warning::Quality gate has warnings for $SERVICE ($DASH)"; exit 0 ;;
  ERROR)
    echo "Failed conditions:"
    jq -r '.projectStatus.conditions[]? | select(.status=="ERROR") | "  - \(.metricKey): actual \(.actualValue // "n/a"), required \(.comparator) \(.errorThreshold)"' <<<"$resp" | head -20
    problem "Quality gate FAILED for $SERVICE ($DASH)"; exit $? ;;
  *)    problem "Quality gate status '$gate' for $SERVICE: no gate is set on the Sonar project, or the result is unknown"; exit $? ;;
esac
