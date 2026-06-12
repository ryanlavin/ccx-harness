#!/bin/bash
# ccx-harness :: poll-next — Codex's side of the relay wait.
#
# Codex runs this from the project root between relay tasks:
#
#   bash .ccx-harness/poll-next.sh <last_seq_completed>
#
# It blocks in chunks (default 20 minutes) checking .ccx-harness/relay.md for a
# new turn from the orchestrator. The total-wait clock persists across chunk
# re-invocations via a state file, so the give-up threshold spans the whole wait,
# not one chunk.
#
# Exit codes:
#   0   new instructions are ready — re-read .ccx-harness/relay.md and follow it
#   10  nothing yet after one chunk — run the exact same command again
#   20  give-up threshold passed — relay.md has been marked OFFLINE; end your session
#
# Tunables (env): CCX_CHUNK_MIN (default 20), CCX_POLL_S (60), CCX_GIVE_UP_H (9)
set -u

LAST_SEQ="${1:?usage: poll-next.sh <last_seq_completed>}"
HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HARNESS_DIR/relay.md"
STATE="$HARNESS_DIR/.poll-state"

CHUNK_MIN="${CCX_CHUNK_MIN:-20}"
POLL_S="${CCX_POLL_S:-60}"
GIVE_UP_H="${CCX_GIVE_UP_H:-9}"

fm_field() { # fm_field <key>
  awk -v key="$1" '
    NR==1 { if ($0 != "---") exit; infm=1; next }
    infm && $0=="---" { exit }
    infm && index($0, key ": ") == 1 {
      sub(/^[^:]*: */, "", $0); print; exit
    }' "$RELAY" 2>/dev/null
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

new_turn_ready() {
  turn="$(fm_field turn || true)"
  seq="$(fm_field seq || true)"
  is_num "${seq:-x}" && [ "$turn" = "codex" ] && [ "$seq" -gt "$LAST_SEQ" ]
}

# --- total-wait clock, persisted across chunk re-invocations -------------------
start=""
if [ -f "$STATE" ]; then
  read -r s_seq s_epoch < "$STATE" 2>/dev/null || true
  if [ "${s_seq:-}" = "$LAST_SEQ" ] && is_num "${s_epoch:-x}"; then start="$s_epoch"; fi
fi
if [ -z "$start" ]; then
  start="$(date +%s)"
  echo "$LAST_SEQ $start" > "$STATE"
fi

chunk_end=$(( $(date +%s) + CHUNK_MIN * 60 ))
give_up_at=$(( start + GIVE_UP_H * 3600 ))

while :; do
  if new_turn_ready; then
    rm -f "$STATE"
    echo "new turn at seq $(fm_field seq) — read $RELAY and follow it"
    exit 0
  fi

  now="$(date +%s)"

  if [ "$now" -ge "$give_up_at" ]; then
    # Final check immediately before signing off, to narrow the race with a
    # prompt the orchestrator writes at the last moment.
    if new_turn_ready; then
      rm -f "$STATE"
      echo "new turn at seq $(fm_field seq) — read $RELAY and follow it"
      exit 0
    fi
    seq="$(fm_field seq || true)"; is_num "${seq:-x}" || seq="$LAST_SEQ"
    task="$(fm_field task || true)"
    tmp="$RELAY.tmp.$$"
    {
      echo "---"
      echo "seq: $seq"
      echo "turn: claude"
      echo "state: OFFLINE"
      echo "kind: shutdown"
      echo "task: ${task:-unknown}"
      echo "written_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "written_by: poll-next"
      echo "---"
      echo
      echo "Codex waited ${GIVE_UP_H}h after completing seq ${LAST_SEQ} with no new"
      echo "prompt and signed off. Re-bootstrap Codex to resume the relay."
    } > "$tmp" && mv "$tmp" "$RELAY"
    rm -f "$STATE"
    echo "gave up after ${GIVE_UP_H}h of waiting — relay marked OFFLINE; end your session"
    exit 20
  fi

  if [ "$now" -ge "$chunk_end" ]; then
    echo "no new turn yet ($(( (now - start) / 60 )) min waited total) — run this exact command again"
    exit 10
  fi

  sleep "$POLL_S"
done
