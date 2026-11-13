#!/usr/bin/env bash
# Helpers for the developer-facing result card. Sourced by the scan scripts.
# Each tool writes a one-line row (icon + text) and, optionally, a detail block (markdown).
# scan-card.sh publishes them as one card per service in the job summary.
CARD_DIR="${RUNNER_TEMP:-/tmp}/scan-card"
card_row()    { mkdir -p "$CARD_DIR"; printf '%s|%s\n' "$2" "$3" > "$CARD_DIR/$1.row"; }   # tool icon text
card_detail() { mkdir -p "$CARD_DIR"; cat > "$CARD_DIR/$1.md"; }                            # tool, markdown on stdin
sev_icon()    { case "$1" in CRITICAL|HIGH) printf '🔴';; MEDIUM) printf '🟡';; *) printf '⚪';; esac; }
