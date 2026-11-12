#!/usr/bin/env bash
# Gitleaks scan of a pull request. Called by .github/actions/gitleaks-scan. Fails closed.
#
# What it scans
#   1. Commits: the LATEST PUSH of the PR (BEFORE..HEAD). A secret that was found, fixed and pushed
#      again therefore does not block the PR a second time. The WHOLE PR (BASE..HEAD) is scanned when
#      the PR is first opened/reopened, after a force-push/rebase, or when there is no earlier push.
#   2. Net change: the files the PR changes, as they are at HEAD (so nothing that slipped through an
#      unscanned push can be merged). Also refuses inline "gitleaks:allow" comments.
# Config and ignore list come from THIS central repo, never from the scanned repo.
#
# Env in:  EVENT_NAME PR_ACTION BEFORE_SHA BASE_SHA HEAD_SHA PR_NUMBER REPO MODE(block|warn) SERVICE
#          CONFIG (central .gitleaks.toml)  POLICY_DIR (policy/gitleaks)  WORKSPACE  GH_TOKEN(optional)
set -uo pipefail

MODE="${MODE:-block}"; SERVICE="${SERVICE:-service}"
WORKSPACE="${WORKSPACE:-$PWD}"; cd "$WORKSPACE"
TMPBASE="${RUNNER_TEMP:-/tmp}"
WORK="$(mktemp -d "$TMPBASE/gitleaks.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
git config --global --add safe.directory "$WORKSPACE" 2>/dev/null || true

fail_or_warn() {   # $1 message
  if [ "$MODE" = "block" ]; then echo "::error::$1"; return 1; else echo "::warning::$1 (mode=warn, not blocking)"; return 0; fi
}

[ -f "$CONFIG" ] || { echo "::error::central gitleaks config not found: $CONFIG"; exit 1; }
IGN="$POLICY_DIR/${REPO//\//__}"; [ -d "$IGN" ] || IGN="$POLICY_DIR/_default"
echo "Gitleaks config: central | ignore list: $(basename "$IGN") | mode: $MODE"

have() { git cat-file -e "${1}^{commit}" 2>/dev/null; }

if [ "$EVENT_NAME" = "pull_request" ]; then
  [ -n "${BASE_SHA:-}" ] && [ -n "${HEAD_SHA:-}" ] || { echo "::error::pull_request event without base/head SHA"; exit 1; }
  have "$BASE_SHA" || git fetch --no-tags -q origin "$BASE_SHA" 2>/dev/null || true
  have "$BASE_SHA" && have "$HEAD_SHA" || { echo "::error::base/head commit not available; check out with fetch-depth: 0"; exit 1; }
  MB="$(git merge-base "$BASE_SHA" "$HEAD_SHA")" || { echo "::error::no merge base"; exit 1; }
  RANGE="$BASE_SHA..$HEAD_SHA"; KIND="whole pull request"
  if [ "${PR_ACTION:-}" = "synchronize" ] && [ -n "${BEFORE_SHA:-}" ] && have "$BEFORE_SHA" \
     && git merge-base --is-ancestor "$BEFORE_SHA" "$HEAD_SHA" 2>/dev/null; then
    RANGE="$BEFORE_SHA..$HEAD_SHA"; KIND="latest push only"
  fi
else
  HEAD_SHA="$(git rev-parse HEAD)"; MB=""; RANGE="-1 $HEAD_SHA"; KIND="last commit (not a pull_request event)"
fi
echo "Scanning commits: $KIND  [$RANGE]"

GL=(gitleaks)
FINDINGS="$WORK/findings.json"; echo '[]' > "$FINDINGS"
TOOL_ERR=0

run_gl() {   # $1 = report path; rest = gitleaks args. Returns 0 clean, 77 leaks, other = tool error
  local rep="$1"; shift
  "${GL[@]}" "$@" -c "$CONFIG" -i "$IGN" -r "$rep" -f json --redact --no-banner --exit-code 77
}
merge_report() { [ -s "$1" ] && jq -s 'add' "$FINDINGS" "$1" > "$FINDINGS.new" 2>/dev/null && mv "$FINDINGS.new" "$FINDINGS"; true; }

# ---- 1) commits
run_gl "$WORK/commits.json" git "$WORKSPACE" --log-opts="$RANGE"; RC1=$?
case "$RC1" in 0|77) merge_report "$WORK/commits.json" ;; *) TOOL_ERR=1; echo "::error::gitleaks (commit scan) failed to run, exit $RC1" ;; esac

# ---- 2) net change of the PR (what would actually land) + inline allow comments
INLINE=0
if [ -n "$MB" ]; then
  NET="$WORK/net"; mkdir -p "$NET"; N=0
  while IFS= read -r -d '' f; do
    mkdir -p "$NET/$(dirname "$f")"
    git show "$HEAD_SHA:$f" > "$NET/$f" 2>/dev/null && N=$((N+1))
  done < <(git diff -z --name-only --diff-filter=AMR "$MB" "$HEAD_SHA")
  echo "Net-change check: $N changed file(s)"
  if [ "$N" -gt 0 ]; then
    run_gl "$WORK/net.json" dir "$NET"; RC2=$?
    case "$RC2" in 0|77) merge_report "$WORK/net.json" ;; *) TOOL_ERR=1; echo "::error::gitleaks (net-change scan) failed to run, exit $RC2" ;; esac
  fi
  if git diff -U0 "$MB" "$HEAD_SHA" | grep -E '^\+' | grep -v '^+++' | grep -q 'gitleaks:allow'; then
    INLINE=1
  fi
fi

# ---- results (never print secret values: reports are redacted; we print rule, location, fingerprint)
jq '[.[] | {File, RuleID, StartLine} as $k | . + {k: $k}] | unique_by(.k) | map(del(.k))' "$FINDINGS" > "$FINDINGS.u" 2>/dev/null && mv "$FINDINGS.u" "$FINDINGS"   # one entry per secret location
COUNT="$(jq 'length' "$FINDINGS")"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "secret_count=$COUNT" >> "$GITHUB_OUTPUT"
RC=0
if [ "$COUNT" -gt 0 ]; then
  echo "Gitleaks found $COUNT potential secret(s):"
  jq -r '.[] | "  - \(.RuleID)  \(.File):\(.StartLine)  commit \((.Commit // "net-change")[0:8])  fingerprint \(.Fingerprint)"' "$FINDINGS" | sort -u | head -40
  echo "ACTION REQUIRED: rotate/revoke the secret first. Removing it from the file does not undo the exposure."
  {
    echo "### Gitleaks: $SERVICE"; echo "Found **$COUNT** potential secret(s) ($KIND). **Rotate them first.**"; echo
    jq -r '.[] | "- `\(.RuleID)` in `\(.File):\(.StartLine)` (commit `\((.Commit // "net-change")[0:8])`)"' "$FINDINGS" | sort -u | head -40
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  if [ -n "${GH_TOKEN:-}" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "${REPO:-}" ]; then
    BODY="$(jq -Rs '{body: .}' <<EOF
**Gitleaks found $COUNT potential secret(s)** in this pull request ($SERVICE, $KIND).

$(jq -r '.[] | "- `\(.RuleID)` in `\(.File):\(.StartLine)` (commit `\((.Commit // "net-change")[0:8])`)"' "$FINDINGS" | sort -u | head -20)

Rotate or revoke the secret first: deleting it from the file does not remove the exposure. Reviewers: please confirm it was rotated.
EOF
)"
    curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments" -d "$BODY" >/dev/null 2>&1 || true
  fi
  fail_or_warn "Gitleaks found $COUNT potential secret(s)" || RC=1
else
  echo "Gitleaks: no secrets found ($KIND, plus net-change check)"
fi
if [ "$INLINE" = 1 ]; then
  fail_or_warn "inline 'gitleaks:allow' comments are not accepted; request a central exception instead" || RC=1
fi
if [ "$TOOL_ERR" = 1 ]; then
  fail_or_warn "gitleaks did not run correctly; failing closed" || RC=1
fi
exit "$RC"
