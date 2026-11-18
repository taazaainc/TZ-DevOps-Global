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
#   SETTINGS_FILE    optional Maven settings file inside the repo (may use ${env.NEXUS_USERNAME} and ${env.NEXUS_PASSWORD});
#                    when set, it has full control and no settings are generated
#   MAVEN_PRIVATE_REPO_IDS  optional, comma separated Maven repository ids that need the NEXUS credentials although the
#                    project poms do not declare them (for example ids declared only by a parent pom in a private repository)
#   BUILD_COMMAND    full override of the build command (runs in the build image from the project folder)
#   EXTRA_SONAR_ARGS extra scanner arguments
# Coverage: JaCoCo is added from the command line when the poms do not bind it (also when it is only declared in
# pluginManagement or an inactive profile); a literal argLine in the Surefire/Failsafe configuration is bypassed with the
# JaCoCo agent through JAVA_TOOL_OPTIONS; every JaCoCo XML report is found automatically, and when tests live in a separate
# module one report is built from all execution data; Gradle gets JaCoCo through an init script. Tests: failing unit tests do NOT stop the Sonar analysis (so a single flaky test cannot hide the
# Sonar result); they are reported in the output "test-failures" and the workflow fails the job afterwards.
#
# Private Maven repositories: when NEXUS_USERNAME and NEXUS_PASSWORD are set and no settings file is given, a Maven
# settings file is generated INSIDE the build container (never in the repository, never on a command line, mode 600,
# removed at the end). It holds one <server> per repository id found in <repositories>, <pluginRepositories> and
# <distributionManagement> of the project poms whose URL host is not a well-known public host (PUBLIC_MAVEN_HOSTS
# below), plus MAVEN_PRIVATE_REPO_IDS. Username and password are the placeholders ${env.NEXUS_USERNAME} and
# ${env.NEXUS_PASSWORD}: Maven reads the values from the container environment, no secret is written to disk.
# Ids that are property placeholders are skipped. The credentials are never configured for public hosts.
#
# Build log: for Maven only the command line, warnings and errors, a test summary per module and the build result
# are printed; when the build fails the last 200 lines of the full output follow (BUILD_COMMAND and Gradle keep the full log).
#
# Test hooks (harmless, off by default): TZ_TEST_STOP_AFTER_BUILD=1 stops after a successful build, before the scanner
# (used by the local tests); TZ_SHOW_SETTINGS=1 prints the generated settings file (placeholders only, no secret).
#
# Env in: SONAR_HOST_URL SONAR_TOKEN PROJECT_KEY SOURCES PROJECT_VERSION SERVICE WORKSPACE POLICY_FILE
#         NEXUS_USERNAME NEXUS_PASSWORD (optional, passed to the build by name)  GITHUB_OUTPUT (optional)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/card-lib.sh"

# Hosts that never get the private repository credentials (space separated, exact host names).
PUBLIC_MAVEN_HOSTS="repo.maven.apache.org repo1.maven.org central.sonatype.com plugins.gradle.org jitpack.io maven.google.com dl.google.com repo.spring.io oss.sonatype.org s01.oss.sonatype.org packages.confluent.io repository.jboss.org repo.jenkins-ci.org repository.apache.org maven.pkg.github.com"

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
    IFS= read -r -d '' BUILD_SCRIPT <<'EOS' || true
set -u
cd "/ws/$SRC_DIR" || exit 90
TZ_SETTINGS=""
trap '[ -z "$TZ_SETTINGS" ] || rm -f "$TZ_SETTINGS"' EXIT

# Maven settings with credentials for the private repositories of the project (see the header of the script)
gen_settings() {
  local flat recs rec id url host i name val extra v ids="" pub="" priv="" forced="" final=""
  flat="$(find /ws \( -name node_modules -o -name target -o -name .git \) -prune -o -name pom.xml -type f -print0 2>/dev/null \
    | xargs -0 -r cat 2>/dev/null | tr '\r\n\t' '   ' | sed -E 's/<!--([^-]|-[^-])*-->//g')"
  recs="$(printf '%s' "$flat" | sed -E 's#</(repository|pluginRepository|snapshotRepository)>#&\n#g' \
    | sed -nE 's#^.*<(repository|pluginRepository|snapshotRepository)>(.*)</\1>$#\2#p')"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    id="$(printf '%s' "$rec" | sed -nE 's#.*<id>[[:space:]]*([^<]*[^<[:space:]])[[:space:]]*</id>.*#\1#p' | head -n1)"
    url="$(printf '%s' "$rec" | sed -nE 's#.*<url>[[:space:]]*([^<]*[^<[:space:]])[[:space:]]*</url>.*#\1#p' | head -n1)"
    [ -n "$id" ] && [ -n "$url" ] || continue
    if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "[tz] repository id skipped (not a literal id): $id"; continue; fi
    for i in 1 2 3; do   # resolve ${property} in the URL from the poms, only to find the host
      [[ "$url" == *'${'* ]] || break
      name="$(printf '%s' "$url" | sed -nE 's#^.*\$\{([A-Za-z0-9_.-]+)\}.*$#\1#p')"
      [ -n "$name" ] || break
      val="$(printf '%s' "$flat" | grep -oE "<${name//./[.]}>[^<]*</${name//./[.]}>" | head -n1 | sed -E 's#^<[^>]*>##; s#<[^>]*>$##; s#^ +##; s# +$##')"
      [ -n "$val" ] || break
      url="${url//\$\{$name\}/$val}"
    done
    if [[ "$url" == *'${'* ]]; then echo "[tz] repository $id skipped (URL is a property that cannot be resolved; use MAVEN_PRIVATE_REPO_IDS)"; continue; fi
    host="$(printf '%s' "$url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s|[/?#].*$||; s#^.*@##; s#:[0-9]*$##' | tr 'A-Z' 'a-z')"
    [ -n "$host" ] || continue
    case " $TZ_PUBLIC_HOSTS " in *" $host "*) pub="$pub $id";; *) priv="$priv $id";; esac
  done <<< "$recs"
  IFS=',' read -r -a extra <<< "${TZ_PRIVATE_IDS:-}"
  for v in "${extra[@]}"; do
    v="${v//[[:space:]]/}"; [ -n "$v" ] || continue
    if [[ ! "$v" =~ ^[A-Za-z0-9._-]+$ ]] || [ "$v" = central ]; then echo "[tz] MAVEN_PRIVATE_REPO_IDS entry ignored: $v"; continue; fi
    forced="$forced $v"
  done
  for id in $(printf '%s\n' $priv | sort -u); do
    case " $pub " in *" $id "*) echo "[tz] repository $id also points to a public host: no credentials for it";; *) final="$final $id";; esac
  done
  for id in $forced; do case " $final " in *" $id "*) ;; *) final="$final $id";; esac; done
  ids="$(printf '%s\n' $final | sort -u | tr '\n' ' ')"; ids="${ids% }"
  if [ -z "$ids" ]; then
    echo "[tz] Maven credentials: no private repository id found in the poms (parent pom only? set MAVEN_PRIVATE_REPO_IDS); no server entries added"
    return 0
  fi
  umask 077
  TZ_SETTINGS="$(mktemp /tmp/tz-maven-settings.XXXXXX)"
  {
    echo '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"><servers>'
    for id in $ids; do
      echo "<server><id>$id</id><username>\${env.NEXUS_USERNAME}</username><password>\${env.NEXUS_PASSWORD}</password></server>"
    done
    echo '</servers></settings>'
  } > "$TZ_SETTINGS"
  chmod 600 "$TZ_SETTINGS"
  echo "[tz] Maven credentials: settings generated in the build container (placeholders for NEXUS_USERNAME and NEXUS_PASSWORD) for repository ids: $ids"
  if [ "${TZ_SHOW_SETTINGS:-}" = 1 ]; then echo "[tz] settings file mode: $(stat -c %a "$TZ_SETTINGS")"; sed 's/^/[tz] settings| /' "$TZ_SETTINGS"; fi
}

ARGS=(-B -ntp -Dstyle.color=never -Dmaven.test.redirectTestOutputToFile=true)
if [ -n "${SETTINGS_FILE:-}" ]; then
  [ -f "/ws/$SETTINGS_FILE" ] || { echo "settings file not found in the repository: $SETTINGS_FILE"; echo "TZ-BUILD-RC=92"; exit 0; }
  ARGS+=(-s "/ws/$SETTINGS_FILE")
  echo "[tz] Maven settings file from the repository: $SETTINGS_FILE (no settings generated)"
elif [ -n "${NEXUS_USERNAME:-}" ] && [ -n "${NEXUS_PASSWORD:-}" ]; then
  gen_settings
  [ -z "$TZ_SETTINGS" ] || ARGS+=(-s "$TZ_SETTINGS")
fi
read -r -a EXTRA <<< "${TZ_MAVEN_ARGS:-}"
if [ "$RUN_TESTS" = true ]; then ARGS+=(-Dmaven.test.failure.ignore=true); else ARGS+=(-DskipTests); fi
GOALS=(clean)
# coverage (JaCoCo): TZ-COVERAGE-BEGIN
TZ_TOOLS=/ws/.tz-tools; TZ_COV=/ws/.tz-coverage; mkdir -p "$TZ_TOOLS" "$TZ_COV"
if [ "$RUN_TESTS" = true ]; then
  # the JaCoCo agent and command line tool, fetched like any other Maven artifact (same settings, same Nexus)
  for a in "org.jacoco:org.jacoco.agent:$JACOCO:jar:runtime" "org.jacoco:org.jacoco.cli:$JACOCO:jar:nodeps"; do
    (cd /tmp && mvn "${ARGS[@]}" -q org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy -Dartifact="$a" -DoutputDirectory="$TZ_TOOLS" -Dmdep.stripVersion=true >/dev/null 2>&1) || echo "[tz] note: could not fetch $a (coverage fallbacks are limited)"
  done
fi
JC_POM=0
if grep -rq --include=pom.xml "jacoco-maven-plugin" .; then
  JC_POM=1
  # a plugin that is only declared (pluginManagement) or sits in an inactive profile produces nothing: then add it ourselves
  if mvn "${ARGS[@]}" -q help:effective-pom -Doutput=/tmp/tz-effective-pom.xml >/dev/null 2>&1 && ! sed "/<pluginManagement>/,/<\/pluginManagement>/d; /<profiles>/,/<\/profiles>/d" /tmp/tz-effective-pom.xml | grep -q "<goal>prepare-agent"; then
    JC_POM=0; echo "[tz] JaCoCo is declared in the poms but not bound to the build (pluginManagement or an inactive profile): adding it from the command line"
  fi
fi
if [ "$RUN_TESTS" = true ] && [ -s "$TZ_TOOLS/org.jacoco.agent-runtime.jar" ] && grep -rh --include=pom.xml "<argLine>" . | grep -vqE "@[{]argLine[}]|[$][{]argLine[}]"; then
  # a literal <argLine> in the Surefire/Failsafe configuration replaces the agent that JaCoCo adds: attach the agent to every forked JVM instead
  echo "[tz] A <argLine> in a pom overrides the JaCoCo agent: attaching the agent through JAVA_TOOL_OPTIONS (report built from its execution data)"
  export JAVA_TOOL_OPTIONS="-javaagent:$TZ_TOOLS/org.jacoco.agent-runtime.jar=destfile=$TZ_COV/jacoco.exec,append=true"
  GOALS+=(verify -Djacoco.skip=true)
elif [ "$JC_POM" = 1 ]; then echo "[tz] JaCoCo is configured in the poms: using it"; GOALS+=(verify -Djacoco.skip=false)
else GOALS+=("org.jacoco:jacoco-maven-plugin:$JACOCO:prepare-agent" verify "org.jacoco:jacoco-maven-plugin:$JACOCO:report" -Djacoco.skip=false); fi
# coverage (JaCoCo): TZ-COVERAGE-END
GOALS+=(org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies -Dsilent=true)
echo "+ mvn ${ARGS[*]} ${GOALS[*]} ${EXTRA[*]:-}"
mvn "${ARGS[@]}" "${GOALS[@]}" "${EXTRA[@]}"
echo "TZ-BUILD-RC=$?"
EOS
    ;;
  gradle)
    BUILD_SCRIPT='set -u
cd "/ws/$SRC_DIR" || exit 90
chmod +x ./gradlew 2>/dev/null
if [ -x ./gradlew ]; then G=./gradlew; else echo "no Gradle wrapper found: add ./gradlew to the repository or use build_command"; echo "TZ-BUILD-RC=91"; exit 0; fi
# coverage (JaCoCo) for Gradle: an init script (nothing is edited in the repository) applies the jacoco plugin when the build does not
# and makes every Test task produce the XML report (build/reports/jacoco/test/jacocoTestReport.xml)
printf "%s\n" "allprojects { p ->" "  p.plugins.withId(\"java\") {" "    if (!p.plugins.hasPlugin(\"jacoco\")) { p.pluginManager.apply(\"jacoco\"); p.jacoco.toolVersion = \"$JACOCO\" }" "    p.tasks.matching { it.name == \"jacocoTestReport\" }.configureEach { try { it.reports.xml.required = true } catch (Throwable e) { it.reports.xml.enabled = true } }" "    p.tasks.withType(Test).configureEach { it.finalizedBy(\"jacocoTestReport\") }" "  }" "}" > /tmp/tz-jacoco.init.gradle
if [ "$RUN_TESTS" = true ]; then $G --no-daemon --continue -I /tmp/tz-jacoco.init.gradle build; else $G --no-daemon -x test build; fi
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
# Maven: the live log shows only the command line, warnings and errors, the test summary per module and the build result.
# The full output is kept (temporary file) and its last 200 lines are printed when the build fails.
IFS= read -r -d '' AWK_FILTER <<'EOS' || true
function show(s) { print s; fflush() }
/^\[tz\] / || /^\+ mvn / || /^settings file not found/ { show($0); next }
/^\[INFO\] Building [^ ]+ [^ ]+( +\[[0-9]+\/[0-9]+\])?$/ && $3 !~ /:$/ { mod = $3; next }
/^\[(INFO|WARNING|ERROR)\] Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$/ {
  s = $0; sub(/^\[[A-Z]+\] /, "", s); m = (mod == "" ? "project" : mod); show("[tests] " m ": " s); next }
/^\[INFO\] Reactor Summary/ { inrs = 1 }
inrs && /^\[INFO\] BUILD / { inrs = 0 }
inrs { show($0); next }
/^\[INFO\] (BUILD (SUCCESS|FAILURE)|Total time:)/ { show($0); next }
/^\[ERROR\]/ { if (!($0 in seen)) { seen[$0] = 1; show($0) }; next }
/^\[WARNING\]/ { if (!($0 in seen)) { seen[$0] = 1; nw++; if (nw <= 60) show($0); else if (nw == 61) show("[WARNING] more warnings omitted") }; next }
EOS
FILTER=(cat)
if [ "$BUILD_TOOL" = maven ] && [ -z "${BUILD_COMMAND:-}" ]; then FILTER=(awk "$AWK_FILTER"); fi
docker run --rm --label "$LABEL" --security-opt no-new-privileges -v "$VOL:/ws" -e "SRC_DIR=$SOURCES" -e "RUN_TESTS=$RUN_TESTS" -e "JACOCO=$JACOCO" \
  -e "TZ_MAVEN_ARGS=${MAVEN_ARGS:-}" -e "SETTINGS_FILE=${SETTINGS_FILE:-}" -e "BUILD_COMMAND=${BUILD_COMMAND:-}" \
  -e "TZ_PRIVATE_IDS=${MAVEN_PRIVATE_REPO_IDS:-}" -e "TZ_PUBLIC_HOSTS=$PUBLIC_MAVEN_HOSTS" -e "TZ_SHOW_SETTINGS=${TZ_SHOW_SETTINGS:-}" \
  -e NEXUS_USERNAME -e NEXUS_PASSWORD \
  --entrypoint bash "$BUILD_IMAGE" -c "$BUILD_SCRIPT" 2>&1 | tee "$OUT" | "${FILTER[@]}"
BUILD_RC="$(sed -n 's/^TZ-BUILD-RC=//p' "$OUT" | tail -n1)"
if [ "${BUILD_RC:-1}" -ne 0 ]; then
  if [ "${FILTER[0]}" != cat ]; then echo "----- last 200 lines of the build output"; tail -n 200 "$OUT"; echo "----- end of the build output"; fi
  if grep -qE 'status code: 40[13]|Return code is: 40[13]|401 Unauthorized|403 Forbidden' "$OUT"; then
    if [ -z "${NEXUS_USERNAME:-}" ]; then
      echo "::error::the repository needs credentials: pass NEXUS_USERNAME and NEXUS_PASSWORD to the workflow (secrets: inherit or explicit)"
    else
      echo "::error::the repository rejected the credentials, or its repository id is not declared in the project poms: check NEXUS_USERNAME and NEXUS_PASSWORD, or set MAVEN_PRIVATE_REPO_IDS (comma separated repository ids, for ids declared only in a parent pom)"
    fi
  fi
  fail "the build failed for $SERVICE (exit ${BUILD_RC:-unknown}): see the build output above" "The Java build failed (compile or dependency error, see the step log)"
fi
if [ "${TZ_TEST_STOP_AFTER_BUILD:-}" = 1 ]; then echo "[test hook] TZ_TEST_STOP_AFTER_BUILD=1: stopping after the successful build, no scan"; exit 0; fi

# ---- 4b) coverage: find the JaCoCo XML reports wherever the build wrote them (any folder, several modules, unit and
# integration tests); when no report has data but execution data exists (agent through argLine override, tests in a
# separate module) build one report from all execution data, all compiled classes and all main sources.
read -r -d '' COV_SCRIPT <<'EOS' || true
cd "/ws/$SRC_DIR" 2>/dev/null || exit 0
NEWER=(); [ -d /ws/.tz-tools ] && NEWER=(-newer /ws/.tz-tools)
find_xml() { grep -rl --include=*.xml -m1 '//JACOCO//DTD Report' . 2>/dev/null | grep -vE '/(node_modules|\.git)/' | while read -r f; do [ -n "$(find "$f" "${NEWER[@]}" 2>/dev/null)" ] && grep -q '<counter type="LINE"' "$f" && echo "$f"; done; }
EXEC="$(find . -type f -name '*.exec' \( -path '*/target/*' -o -path '*/build/*' -o -path './.tz-coverage/*' \) -not -path '*/node_modules/*' 2>/dev/null | head -200 | tr '\n' ' ')"
XML="$(find_xml)"
if [ -z "$XML" ] && [ -n "$EXEC" ] && [ -s /ws/.tz-tools/org.jacoco.cli-nodeps.jar ]; then
  CF=(); SF=()
  while read -r d; do CF+=(--classfiles "$d"); done < <(find . -type d \( -path '*/target/classes' -o -path '*/build/classes/java/main' -o -path '*/build/classes/kotlin/main' \) -not -path '*/node_modules/*')
  while read -r d; do SF+=(--sourcefiles "$d"); done < <(find . -type d \( -path '*/src/main/java' -o -path '*/src/main/kotlin' \) -not -path '*/node_modules/*')
  mkdir -p /ws/.tz-coverage
  if [ "${#CF[@]}" -gt 0 ] && java -jar /ws/.tz-tools/org.jacoco.cli-nodeps.jar report $EXEC "${CF[@]}" "${SF[@]}" --xml /ws/.tz-coverage/jacoco-merged.xml >/tmp/tz-cli.log 2>&1; then
    grep -q '<counter type="LINE"' /ws/.tz-coverage/jacoco-merged.xml && echo "TZ-COV-XML=.tz-coverage/jacoco-merged.xml"
  else echo "TZ-COV-MSG=the JaCoCo report could not be built from the execution data"; tail -n 3 /tmp/tz-cli.log; fi
fi
for f in $XML; do echo "TZ-COV-XML=$(realpath --relative-to=/ws "$f")"; done
echo "TZ-COV-EXEC=$(echo $EXEC | wc -w)"
EOS
COV_OUT="$(docker run --rm --label "$LABEL" -v "$VOL:/ws" -e "SRC_DIR=$SOURCES" --entrypoint bash "$BUILD_IMAGE" -c "$COV_SCRIPT" 2>/dev/null)"
COV_PATHS="$(sed -n 's/^TZ-COV-XML=//p' <<<"$COV_OUT" | paste -sd, -)"   # paths relative to the volume root = scanner base dir
COV_EXEC="$(sed -n 's/^TZ-COV-EXEC=//p' <<<"$COV_OUT" | tail -n1)"; COV_EXEC="${COV_EXEC:-0}"

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
# coverage messages (warnings only; they never fail the scan)
if [ "$RUN_TESTS" = true ] && [ "$BUILD_TOOL" = maven ]; then
  if [ "$TESTS" -gt 0 ] && [ -z "$COV_PATHS" ]; then
    echo "::warning::tests ran for $SERVICE but no JaCoCo coverage data was found (check: JaCoCo skipped in the pom, a plugin configuration that drops the agent, or test code that forks its own JVM); Sonar will show no coverage"
  elif [ "$TESTS" -eq 0 ] && grep -rqE --include=pom.xml '<(skipTests|maven\.test\.skip)>true<' "$PD" 2>/dev/null; then
    echo "::warning::the pom sets skipTests/maven.test.skip=true, so no tests run for $SERVICE and there is no coverage; remove it or set it per profile"
  fi
fi
[ -n "$COV_PATHS" ] && echo "JaCoCo reports passed to Sonar: $COV_PATHS"

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
  def sonar.coverage.jacoco.xmlReportPaths "${COV_PATHS:-**/build/reports/jacoco/**/*.xml}"
  def sonar.exclusions '**/build/**,**/src/test/**'
else
  def sonar.java.binaries '**/target/classes'
  def sonar.java.test.binaries '**/target/test-classes'
  def sonar.java.libraries '**/target/dependency/*.jar'
  def sonar.coverage.jacoco.xmlReportPaths "${COV_PATHS:-**/target/site/jacoco/jacoco.xml}"
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
