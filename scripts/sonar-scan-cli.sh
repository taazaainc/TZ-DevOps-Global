#!/usr/bin/env bash
# Sonar analysis with the OFFICIAL SonarScanner CLI image (sonarsource/sonar-scanner-cli), pinned by digest
# in policy/tool-versions.env. Language independent: JavaScript/TypeScript (Angular, React, Node), Python, Go,
# PHP, Ruby, HTML/CSS, YAML, Docker, Terraform and more are analysed from source. No custom image per language.
#
# Replaces the old custom image (SonarScanner 5.0.1 on Java 17), which SonarQube 13.x rejects
# ("Java 17 is not supported"). Same analysis as before: same project key, name, sources, version, git SCM.
#
# Coverage: added automatically when the tests produced a report under the service folder
#   lcov.info     -> sonar.javascript.lcov.reportPaths   (JS/TS)
#   coverage.xml  -> sonar.python.coverage.reportPaths   (Python, Cobertura XML)
#   coverage.out  -> sonar.go.coverage.reportPaths       (Go)
# No report found = analysis without coverage (not an error).
#
# Isolation: throwaway container (--rm), image user (uid 1000, not root), no Linux capabilities,
# no privilege escalation, token passed by environment name only (never on a command line),
# work folder inside the workspace so the quality gate step finds report-task.txt of THIS run.
#
# Env in (from the action): SONAR_HOST_URL SONAR_TOKEN PROJECT_KEY SOURCES PROJECT_VERSION SERVICE
#   HOST_WORKSPACE (host path of the workspace, for the docker mount)  WORKSPACE (same folder as seen here)
#   SCANNER_IMAGE (optional override)  IGNORED_IMAGE (old caller input, only reported)  POLICY_FILE
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/card-lib.sh"

fail() { card_row sonar "🔴" "$2"; echo "::error::$1"; exit 1; }
[ -n "${SONAR_TOKEN:-}" ]    || fail "SONAR_TOKEN is not set" "Sonar is not configured (no token)"
[ -n "${SONAR_HOST_URL:-}" ] || fail "SONAR_HOST_URL is not set" "Sonar is not configured (no host)"
[ -n "${PROJECT_KEY:-}" ]    || fail "project key is empty" "Sonar project key is missing"
[ -n "${HOST_WORKSPACE:-}" ] || fail "host workspace path is empty" "Sonar scan setup error"
WORKSPACE="${WORKSPACE:-$PWD}"; SERVICE="${SERVICE:-service}"; SOURCES="${SOURCES:-.}"; SOURCES="${SOURCES%/}"

if [ -z "${SCANNER_IMAGE:-}" ] && [ -f "${POLICY_FILE:-}" ]; then
  SCANNER_IMAGE="$(sed -n 's/^SONAR_SCANNER_CLI_IMAGE=//p' "$POLICY_FILE" | tr -d '\r' | head -n1)"
fi
[ -n "${SCANNER_IMAGE:-}" ] || fail "no scanner image configured (policy/tool-versions.env)" "Sonar scan setup error"
if [ -n "${IGNORED_IMAGE:-}" ]; then
  echo "Note: the caller's sonar_nodejs_image input is no longer used; the central pinned official scanner is used."
fi

# coverage reports written by the tests, relative to the workspace root (= /usr/src in the scanner container)
src_rel="$SOURCES"; [ -d "$WORKSPACE/$src_rel" ] || src_rel="."
cov() {
  (cd "$WORKSPACE" && find "$src_rel" -type f -name "$1" \
      -not -path '*/node_modules/*' -not -path '*/.scannerwork/*' -not -path '*/.git/*' 2>/dev/null \
    | sed 's#^\./##' | sort | paste -sd, -)
}
args=(
  "-Dsonar.projectKey=$PROJECT_KEY"
  "-Dsonar.projectName=$PROJECT_KEY"
  "-Dsonar.sources=$SOURCES"
  "-Dsonar.projectVersion=${PROJECT_VERSION:-unknown}"
  "-Dsonar.scm.provider=git"
  "-Dsonar.scanner.skipJreProvisioning=true"
)
found=""
v="$(cov lcov.info)";    [ -n "$v" ] && args+=("-Dsonar.javascript.lcov.reportPaths=$v") && found="$found lcov:$v"
v="$(cov coverage.xml)"; [ -n "$v" ] && args+=("-Dsonar.python.coverage.reportPaths=$v") && found="$found python:$v"
v="$(cov coverage.out)"; [ -n "$v" ] && args+=("-Dsonar.go.coverage.reportPaths=$v")     && found="$found go:$v"
if [ -n "$found" ]; then echo "Coverage reports:$found"
else echo "Coverage reports: none found (tests that write coverage/lcov.info, coverage.xml or coverage.out are picked up automatically)"; fi

echo "Scanner image: $SCANNER_IMAGE"
echo "Project: $PROJECT_KEY | sources: $SOURCES | version: ${PROJECT_VERSION:-unknown}"
pulled=0
for i in 1 2 3; do docker pull -q "$SCANNER_IMAGE" >/dev/null 2>&1 && { pulled=1; break; }; sleep $((i * 5)); done
[ "$pulled" = 1 ] || docker image inspect "$SCANNER_IMAGE" >/dev/null 2>&1 \
  || fail "could not pull $SCANNER_IMAGE" "The Sonar scanner image could not be downloaded"

docker run --rm \
  --cap-drop ALL --security-opt no-new-privileges \
  -e SONAR_HOST_URL -e SONAR_TOKEN \
  -e SCANNER_WORKDIR_PATH=/usr/src/.scannerwork \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  -v "$HOST_WORKSPACE:/usr/src" \
  "$SCANNER_IMAGE" "${args[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "Sonar scan failed for $SERVICE (scanner exit code $rc): see the scanner output above" "The Sonar scan failed (scanner error, see the step log)"
fi
echo "Sonar scan finished for $SERVICE; the quality gate step checks the result."
