#!/usr/bin/env bash
# Installs gitleaks or trivy for ONE job: into a per-job temp folder, no sudo, no shared cache.
#
# Usage: install-tool.sh <gitleaks|trivy> [latest|<version>]
#
# Version policy lives in policy/tool-versions.env (central, reviewed). In "latest" mode the newest
# stable release that is at least TOOL_COOLDOWN_DAYS old is used, so a freshly published (possibly
# bad) release is never picked up automatically. A minimum version stops downgrades.
# Integrity: the tarball is checked against the release's checksum file; in pinned mode the exact
# hash recorded in policy/tool-versions.env is also required.
set -euo pipefail

TOOL="${1:?usage: install-tool.sh <gitleaks|trivy> [latest|version]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/policy/tool-versions.env" ] && . "$ROOT/policy/tool-versions.env"

case "$TOOL" in
  gitleaks)
    REPO="gitleaks/gitleaks"; ASSET_T='gitleaks_@V@_linux_x64.tar.gz'; SUMS_T='gitleaks_@V@_checksums.txt'
    CFG_VER="${GITLEAKS_VERSION:-latest}"; MIN_VER="${GITLEAKS_MIN_VERSION:-0}"; PIN_SHA="${GITLEAKS_SHA256:-}" ;;
  trivy)
    REPO="aquasecurity/trivy"; ASSET_T='trivy_@V@_Linux-64bit.tar.gz'; SUMS_T='trivy_@V@_checksums.txt'
    CFG_VER="${TRIVY_VERSION:-latest}"; MIN_VER="${TRIVY_MIN_VERSION:-0}"; PIN_SHA="${TRIVY_SHA256:-}" ;;
  *) echo "::error::unknown tool '$TOOL'"; exit 2 ;;
esac
WANT="${2:-$CFG_VER}"
COOLDOWN_DAYS="${TOOL_COOLDOWN_DAYS:-3}"

api() {
  curl -fsSL --retry 3 --retry-delay 2 -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} "$@"
}

if [ "$WANT" = "latest" ]; then
  TAG="$(api "https://api.github.com/repos/${REPO}/releases?per_page=30" \
    | jq -r --argjson d "$COOLDOWN_DAYS" \
      '[.[] | select(.draft==false and .prerelease==false and ((now - (.published_at|fromdateiso8601)) > ($d*86400)))][0].tag_name // empty')"
  [ -n "$TAG" ] || { echo "::error::no eligible $TOOL release found (stable, older than ${COOLDOWN_DAYS} days)"; exit 1; }
else
  TAG="v${WANT#v}"
fi
V="${TAG#v}"

# never go below the minimum version (blocks downgrade to a vulnerable or withdrawn release)
if [ "$(printf '%s\n%s\n' "$MIN_VER" "$V" | sort -V | head -n1)" != "$MIN_VER" ] && [ "$MIN_VER" != "0" ]; then
  echo "::error::$TOOL $V is older than the allowed minimum $MIN_VER"; exit 1
fi

ASSET="${ASSET_T//@V@/$V}"; SUMS="${SUMS_T//@V@/$V}"
BASE_TMP="${RUNNER_TEMP:-$(mktemp -d)}"
DEST="$BASE_TMP/tools/$TOOL/$V"
mkdir -p "$DEST"; cd "$DEST"

curl -fsSL --retry 3 --retry-delay 2 -o "$ASSET" "https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
curl -fsSL --retry 3 --retry-delay 2 -o "$SUMS"  "https://github.com/${REPO}/releases/download/${TAG}/${SUMS}"

# 1) the file matches the release's checksum list (detects a damaged or swapped download)
grep " ${ASSET}\$" "$SUMS" | sha256sum -c - >/dev/null || { echo "::error::checksum mismatch for $ASSET"; exit 1; }
# 2) pinned mode: the hash recorded in OUR reviewed repo must also match
if [ "$WANT" != "latest" ]; then
  [ -n "$PIN_SHA" ] || { echo "::error::pinned $TOOL version needs its SHA256 in policy/tool-versions.env"; exit 1; }
  echo "${PIN_SHA}  ${ASSET}" | sha256sum -c - >/dev/null || { echo "::error::pinned hash mismatch for $ASSET"; exit 1; }
fi

tar -xzf "$ASSET" "$TOOL"
rm -f "$ASSET"
chmod +x "$TOOL"
[ -n "${GITHUB_PATH:-}" ] && echo "$DEST" >> "$GITHUB_PATH"
export PATH="$DEST:$PATH"
"$TOOL" --version | head -n 3
{
  echo "- **$TOOL** \`$V\` (policy: $WANT, cooldown ${COOLDOWN_DAYS}d, minimum $MIN_VER)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
