#!/usr/bin/env bash
# Publishes the result card of one service to the job summary, or resets the card (MODE=init).
# Only what a developer needs: one status per check, then what to fix. No tool or policy details.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/card-lib.sh"
if [ "${MODE:-publish}" = "init" ]; then rm -rf "$CARD_DIR"; mkdir -p "$CARD_DIR"; exit 0; fi
SERVICE="${SERVICE:-service}"; OUT="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
row() { # key label
  if [ -f "$CARD_DIR/$1.row" ]; then IFS='|' read -r icon text < "$CARD_DIR/$1.row"; else icon="⚪"; text="not run"; fi
  echo "| $icon $2 | $text |"; case "$icon" in 🔴) RED=1;; 🟡) YEL=1;; esac
}
RED=0; YEL=0
TABLE="$(row gitleaks 'Secrets (Gitleaks)'; row trivy 'Vulnerabilities (Trivy)'; [ -f "$CARD_DIR/trivy-secrets.row" ] && row trivy-secrets 'Secrets in image (Trivy)'; row sonar 'Code quality (Sonar)')"
# the row() calls ran in a subshell: recompute the overall status from the rows
if grep -q '^🔴' "$CARD_DIR"/*.row 2>/dev/null; then HEAD="🔴"; elif grep -q '^🟡' "$CARD_DIR"/*.row 2>/dev/null; then HEAD="🟡"; else HEAD="🟢"; fi
{
  echo "### $HEAD $SERVICE"; echo
  echo "| Check | Result |"; echo "|---|---|"; echo "$TABLE"; echo
  for t in gitleaks trivy trivy-secrets sonar; do
    if [ -f "$CARD_DIR/$t.md" ]; then cat "$CARD_DIR/$t.md"; echo; fi
  done
} >> "$OUT"
# the card must never fail the job: always exit 0
exit 0
