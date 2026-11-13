#!/usr/bin/env bash
# Sonar analysis for Java (Maven by default, Gradle or any build via BUILD_COMMAND) with official tools only:
#   1. build and test in the official Maven image (Eclipse Temurin JDK), version taken from the project
#   2. analyse with the official SonarScanner CLI image (Java 21) from source, compiled classes and the JaCoCo report
# Both images are pinned by digest in policy/tool-versions.env. No custom image, no credentials in a repository.
#
# Why two containers and a Docker volume: no host folder is mounted into any container (host-path mounts from
# CI job containers are unreliable). The code is streamed into a throwaway volume, the build writes target/ there,
# the scanner reads the same volume, the volume is removed at the end.
#
# Flexibility (everything has a default; a repo's own sonar-project.properties always wins for the keys it sets):
#   JAVA_VERSION     auto = from the pom (java.version, maven.compiler.release/source/target); 8, 11, 17 or 21
#   BUILD_TOOL       auto (pom.xml = maven, gradle files = gradle) | maven | gradle
#   RUN_TESTS        true (default) | false
#   MAVEN_ARGS       extra Maven arguments, for example a profile: -Pci
#   SETTINGS_FILE    optional Maven settings file inside the repo (may use ${env.NEXUS_USERNAME} and ${env.NEXUS_PASSWORD})
#   BUILD_COMMAND    full override of the build command (runs in the build image from the project folder)
#   EXTRA_SONAR_ARGS extra scanner arguments
# Coverage: JaCoCo is added from the command line when the poms do not configure it; the XML report is found
# automatically. Tests: failing unit tests do NOT stop the Sonar analysis (so a single flaky test cannot hide the
# Sonar result); they are reported in the output "test-failures" and the workflow fails the job afterwards.
#
# Env in: SONAR_HOST_URL SONAR_TOKEN PROJECT_KEY SOURCES PROJECT_VERSION SERVICE WORKSPACE POLICY_FILE
#         NEXUS_USERNAME NEXUS_PASSWORD (optional, passed to the build by name)  GITHUB_OUTPUT (optional)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/card-lib.sh"

fail() { card_row sonar "🔴" "$2"; echo "::error::$1"; exit 1; }
[ -n "${SONAR_TOKEN:-}" ]    || fail "SONAR_TOKEN is not set" "Sonar is not configured (no token)"
[ -n "${SONAR_HOST_URL:-}" ] || fail "SONAR_HOST_URL is not set" "Sonar is not configured (no host)"
[ -n "${PROJECT_KEY:-}" ]    || fail "project key is empty" "Sonar project key is missing"
WORKSPACE="${WORKSPACE:-$PWD}"; SERVICE="${SERVICE:-service}"; SOURCES="${SOURCES:-.}"; SOURCES="${SOURCES%/}"; [ -n "$SOURCES" ] || SOURCES="."
RUN_TESTS="${RUN_TESTS:-true}"; BUILD_TOOL="${BUILD_TOOL:-auto}"; JAVA_VERSION="${JAVA_VERSION:-auto}"
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }
out test-failures 0
pol() { sed -n "s/^$1=//p" "${POLICY_FILE:-/dev/null}" 2>/dev/null | tr -d '\r' | head -n1; }

PD="$WORKSPACE/$SOURCES"
[ -d "$PD" ] || fail "project folder '$SOURCES' does not exist in the checkout" "The Java project folder was not found"

# ---- 1) build tool
if [ "$BUILD_TOOL" = auto ]; then
  if [ -f "$PD/pom.xml" ]; then BUILD_TOOL=maven
  elif [ -f "$PD/gradlew" ] || ls "$PD"/build.gradle* >/dev/null 2>&1; then BUILD_TOOL=gradle
  elif [ -n "${BUILD_COMMAND:-}" ]; then BUILD_TOOL=custom
  else fail "no pom.xml or Gradle build in '$SOURCES' (set build_tool or build_command)" "No Maven or Gradle build found"; fi
fi
case "$BUILD_TOOL" in maven|gradle|custom) ;; *) fail "unknown build tool '$BUILD_TOOL'" "Unknown build tool";; esac

# ---- 2) Java version
detect_java() {
  local v="" k
  for k in maven.compiler.release release java.version maven.compiler.target maven.compiler.source; do
    if [ -f "$PD/pom.xml" ]; then v="$(grep -hoE "<$k>[0-9.]+</$k>" "$PD/pom.xml" 2>/dev/null | head -n1 | sed -E 's/<[^>]+>//g')"; fi
    [ -n "$v" ] && { echo "$v ($k)"; return; }
  done
  for k in maven.compiler.release release java.version maven.compiler.target maven.compiler.source; do
    v="$(grep -rhoE --include=pom.xml "<$k>[0-9.]+</$k>" "$PD" 2>/dev/null | sed -E 's/<[^>]+>//g; s/^1\.//' | sort -n | tail -n1)"
    [ -n "$v" ] && { echo "$v ($k, highest of the module poms)"; return; }
  done
  v="$(grep -rhoE --include=build.gradle --include=build.gradle.kts "(JavaVersion\.VERSION_|JavaLanguageVersion\.of\()[0-9_.]+" "$PD" 2>/dev/null | head -n1 | grep -oE "[0-9][0-9_.]*" | tr '_' '.')"
  [ -n "$v" ] && { echo "$v (gradle)"; return; }
  echo "17 (default)"
}
if [ "$JAVA_VERSION" = auto ]; then
  d="$(detect_java)"; raw="${d%% *}"; how="${d#* }"
else raw="$JAVA_VERSION"; how="input"; fi
raw="${raw#1.}"; major="${raw%%.*}"; major="${major//[^0-9A-Za-z._-]/}"
case "$major" in
  8) JV=8;; 9|10|11) JV=11;; 12|13|14|15|16|17) JV=17;; 18|19|20|21) JV=21;;
  *) fail "Java $major is not supported by the pinned build images (8, 11, 17, 21): set java_version or the image in policy/tool-versions.env" "Java version $major is not supported yet";;
esac
BUILD_IMAGE="${MAVEN_IMAGE:-$(pol "MAVEN_IMAGE_$JV")}"
SCANNER_IMAGE="${SCANNER_IMAGE:-$(pol SONAR_SCANNER_CLI_IMAGE)}"
JACOCO="$(pol JACOCO_VERSION)"; JACOCO="${JACOCO:-0.8.12}"
[ -n "$BUILD_IMAGE" ]   || fail "no build image for Java $JV in policy/tool-versions.env" "Sonar scan setup error (build image)"
[ -n "$SCANNER_IMAGE" ] || fail "no scanner image in policy/tool-versions.env" "Sonar scan setup error (scanner image)"
if [ -n "${IGNORED_IMAGE:-}" ]; then echo "Note: the caller's sonar_java_image input is no longer used; the central pinned official images are used."; fi
echo "Project: $PROJECT_KEY | folder: $SOURCES | build: $BUILD_TOOL | Java $JV (from $how)"
echo "Build image: $BUILD_IMAGE"; echo "Scanner image: $SCANNER_IMAGE"

pull() { local i; for i in 1 2 3; do docker pull -q "$1" >/dev/null 2>&1 && return 0; sleep $((i * 5)); done; docker image inspect "$1" >/dev/null 2>&1; }
pull "$BUILD_IMAGE"   || fail "could not pull the build image" "The Java build image could not be downloaded"
pull "$SCANNER_IMAGE" || fail "could not pull the scanner image" "The Sonar scanner image could not be downloaded"

VOL="tz-java-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}-$$-$RANDOM-$(date +%s)"
OUT="$(mktemp)"
LABEL="tz-sonar-java=$VOL"
cleanup() {
  docker ps -aq --filter "label=$LABEL" 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1
  docker volume rm -f "$VOL" >/dev/null 2>&1
  rm -f "$OUT"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
docker volume create "$VOL" >/dev/null || fail "could not create the build volume" "Sonar scan setup error (volume)"

# ---- 3) code into the volume (no host mount; node_modules and old scanner folders are not copied)
tar -C "$WORKSPACE" --exclude=node_modules --exclude=.scannerwork -cf - . \
  | docker run --rm -i --label "$LABEL" -v "$VOL:/ws" --entrypoint sh "$BUILD_IMAGE" -c 'tar -xf - -C /ws --no-same-owner'
copy_rc=("${PIPESTATUS[@]}")
{ [ "${copy_rc[0]}" -eq 0 ] && [ "${copy_rc[1]}" -eq 0 ]; } || fail "could not copy the code into the build volume" "The Sonar scan could not read the code"

# ---- 4) build and test (official Maven image, runs as root inside a throwaway container, volume only)
case "$BUILD_TOOL" in
  maven)
    BUILD_SCRIPT='set -u
cd "/ws/$SRC_DIR" || exit 90
ARGS=(-B -ntp)
if [ -n "${SETTINGS_FILE:-}" ]; then
  [ -f "/ws/$SETTINGS_FILE" ] || { echo "settings file not found in the repository: $SETTINGS_FILE"; echo "TZ-BUILD-RC=92"; exit 0; }
  ARGS+=(-s "/ws/$SETTINGS_FILE")
fi
read -r -a EXTRA <<< "${TZ_MAVEN_ARGS:-}"
if [ "$RUN_TESTS" = true ]; then ARGS+=(-Dmaven.test.failure.ignore=true); else ARGS+=(-DskipTests); fi
GOALS=(clean)
if grep -rq --include=pom.xml "jacoco-maven-plugin" .; then echo "JaCoCo is configured in the poms: using it"; GOALS+=(verify)
else GOALS+=("org.jacoco:jacoco-maven-plugin:$JACOCO:prepare-agent" verify "org.jacoco:jacoco-maven-plugin:$JACOCO:report"); fi
GOALS+=(org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies)
echo "+ mvn ${ARGS[*]} ${GOALS[*]} ${EXTRA[*]:-}"
mvn "${ARGS[@]}" "${GOALS[@]}" "${EXTRA[@]}"
echo "TZ-BUILD-RC=$?"'
    ;;
  gradle)
    BUILD_SCRIPT='set -u
cd "/ws/$SRC_DIR" || exit 90
chmod +x ./gradlew 2>/dev/null
if [ -x ./gradlew ]; then G=./gradlew; else echo "no Gradle wrapper found: add ./gradlew to the repository or use build_command"; echo "TZ-BUILD-RC=91"; exit 0; fi
if [ "$RUN_TESTS" = true ]; then $G --no-daemon --continue build; else $G --no-daemon -x test build; fi
rc=$?
if [ "$rc" -ne 0 ] && [ "$RUN_TESTS" = true ] && find . -path "*/build/classes" -type d | grep -q .; then echo "Gradle reported failures (failing tests); the compiled classes exist, so the analysis continues"; rc=0; fi
echo "TZ-BUILD-RC=$rc"'
    ;;
  custom)
    BUILD_SCRIPT='set -u
cd "/ws/$SRC_DIR" || exit 90
bash -c "$BUILD_COMMAND"
echo "TZ-BUILD-RC=$?"'
    ;;
esac
[ -n "${BUILD_COMMAND:-}" ] && [ "$BUILD_TOOL" != custom ] && BUILD_SCRIPT='set -u
cd "/ws/$SRC_DIR" || exit 90
bash -c "$BUILD_COMMAND"
echo "TZ-BUILD-RC=$?"'
docker run --rm --label "$LABEL" --security-opt no-new-privileges -v "$VOL:/ws" -e "SRC_DIR=$SOURCES" -e "RUN_TESTS=$RUN_TESTS" -e "JACOCO=$JACOCO" \
  -e "TZ_MAVEN_ARGS=${MAVEN_ARGS:-}" -e "SETTINGS_FILE=${SETTINGS_FILE:-}" -e "BUILD_COMMAND=${BUILD_COMMAND:-}" \
  -e NEXUS_USERNAME -e NEXUS_PASSWORD \
  --entrypoint bash "$BUILD_IMAGE" -c "$BUILD_SCRIPT" 2>&1 | tee "$OUT"
BUILD_RC="$(sed -n 's/^TZ-BUILD-RC=//p' "$OUT" | tail -n1)"
if [ "${BUILD_RC:-1}" -ne 0 ]; then
  fail "the build failed for $SERVICE (exit ${BUILD_RC:-unknown}): see the build output above" "The Java build failed (compile or dependency error, see the step log)"
fi

# unit test results: counted from the Surefire, Failsafe and Gradle XML reports inside the volume
read -r -d '' COUNT_SCRIPT <<'EOS' || true
cd "/ws/$SRC_DIR" 2>/dev/null || { echo "0 0 0 0"; exit 0; }
find . \( -path "*/surefire-reports/TEST-*.xml" -o -path "*/failsafe-reports/TEST-*.xml" -o -path "*/test-results/*/TEST-*.xml" \) -print0 2>/dev/null \
  | xargs -0 -r grep -h -m1 "<testsuite " 2>/dev/null \
  | awk 'function num(re,   s) { if (match($0, re)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); return s + 0 } return 0 }
         { t += num(" tests=\"[0-9]+\""); f += num(" failures=\"[0-9]+\""); e += num(" errors=\"[0-9]+\""); k += num(" skipped=\"[0-9]+\"") }
         END { printf "%d %d %d %d\n", t, f, e, k }'
EOS
COUNT_OUT="$(docker run --rm --label "$LABEL" -v "$VOL:/ws:ro" -e "SRC_DIR=$SOURCES" --entrypoint bash "$BUILD_IMAGE" -c "$COUNT_SCRIPT" 2>/dev/null | tail -n1)"
if [[ ! "$COUNT_OUT" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
  echo "::warning::could not read the unit test reports for $SERVICE, so the number of failed tests is unknown"; COUNT_OUT="0 0 0 0"
fi
read -r TESTS TFAIL TERR TSKIP <<< "$COUNT_OUT"
FAILS=$((TFAIL + TERR))
echo "Unit tests: run $TESTS, failed $TFAIL, errors $TERR, skipped $TSKIP"
if [ "$RUN_TESTS" = true ] && [ "$TESTS" -eq 0 ]; then echo "::notice::no unit tests were found for $SERVICE (the scan runs without test results; coverage appears when tests are added)"; fi
out test-failures "$FAILS"
[ "$FAILS" -gt 0 ] && echo "::warning::$FAILS unit test(s) failed for $SERVICE; the Sonar analysis still runs"

# ---- 5) scanner arguments: the repo's own sonar-project.properties wins for every key it sets
PROPS="$WORKSPACE/sonar-project.properties"
has() { [ -f "$PROPS" ] && grep -qE "^[[:space:]]*$1[[:space:]]*[=:]" "$PROPS"; }
args=("-Dsonar.projectKey=$PROJECT_KEY" "-Dsonar.projectVersion=${PROJECT_VERSION:-unknown}" "-Dsonar.scm.provider=git" "-Dsonar.scanner.skipJreProvisioning=true")
# a repository that describes its modules itself (sonar.modules) keeps full control of sources, binaries and tests
MODULES=0; has sonar.modules && MODULES=1
def() {
  if [ "$MODULES" = 1 ]; then case "$1" in sonar.java.*|sonar.sources|sonar.tests|sonar.test.inclusions|sonar.coverage.*|sonar.exclusions) return 0;; esac; fi
  has "$1" || args+=("-D$1=$2")
}
def sonar.projectName "$PROJECT_KEY"
if [ -f "$PROPS" ]; then
  fk="$(sed -nE 's/^[[:space:]]*sonar\.projectKey[[:space:]]*[=:][[:space:]]*//p' "$PROPS" | head -n1 | tr -d '\r')"
  if [ -n "$fk" ] && [ "$fk" != "$PROJECT_KEY" ]; then echo "::warning::sonar-project.properties sets projectKey '$fk'; the central key '$PROJECT_KEY' is used so the quality gate reads the same project"; fi
  fe="$(sed -nE 's/^[[:space:]]*sonar\.exclusions[[:space:]]*[=:][[:space:]]*//p' "$PROPS" | head -n1)"
  if [ -n "$fe" ] && [[ "$fe" != *target* ]]; then echo "::warning::sonar.exclusions in sonar-project.properties does not exclude **/target/**: build outputs may be indexed (slow, noisy)"; fi
fi
if [ "$BUILD_TOOL" = gradle ]; then
  def sonar.java.binaries '**/build/classes/java/main,**/build/classes/kotlin/main'
  def sonar.java.test.binaries '**/build/classes/java/test,**/build/classes/kotlin/test'
  def sonar.coverage.jacoco.xmlReportPaths '**/build/reports/jacoco/**/*.xml'
  def sonar.exclusions '**/build/**,**/src/test/**'
else
  def sonar.java.binaries '**/target/classes'
  def sonar.java.test.binaries '**/target/test-classes'
  def sonar.java.libraries '**/target/dependency/*.jar'
  def sonar.coverage.jacoco.xmlReportPaths '**/target/site/jacoco/jacoco.xml'
  def sonar.exclusions '**/target/**,**/src/test/**'
fi
def sonar.sources "$SOURCES"
def sonar.tests "$SOURCES"
def sonar.test.inclusions '**/src/test/**'
def sonar.java.source "$major"
def sonar.sourceEncoding UTF-8
# shellcheck disable=SC2206
[ -n "${EXTRA_SONAR_ARGS:-}" ] && args+=(${EXTRA_SONAR_ARGS})
if [ -f "$PROPS" ]; then echo "Using the repository's sonar-project.properties (its keys override the defaults)"; fi
echo "Scanner arguments: ${args[*]}"

# ---- 6) scan: official scanner image, volume only, no capabilities, no escalation
docker run --rm --user 0:0 --cap-drop ALL --security-opt no-new-privileges \
  -e SONAR_HOST_URL -e SONAR_TOKEN -e SONAR_USER_HOME=/tmp/.sonar \
  -e SCANNER_WORKDIR_PATH=/usr/src/.scannerwork \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  -v "$VOL:/usr/src" "$SCANNER_IMAGE" "${args[@]}" 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  fail "Sonar scan failed for $SERVICE (scanner exit code $rc): see the scanner output above" "The Sonar scan failed (scanner error, see the step log)"
fi

# ---- 7) hand the report to the quality gate step (it looks in the workspace)
mkdir -p "$WORKSPACE/.scannerwork"
docker run --rm -v "$VOL:/usr/src:ro" --entrypoint cat "$SCANNER_IMAGE" /usr/src/.scannerwork/report-task.txt > "$WORKSPACE/.scannerwork/report-task.txt" 2>/dev/null \
  || true
[ -s "$WORKSPACE/.scannerwork/report-task.txt" ] || { rm -f "$WORKSPACE/.scannerwork/report-task.txt"; fail "the scanner did not write report-task.txt" "The Sonar scan did not produce a report"; }
if [ "$FAILS" -gt 0 ]; then card_row unit-tests "🔴" "$FAILS unit test(s) failed"; fi
echo "Sonar scan finished for $SERVICE; the quality gate step checks the result."
