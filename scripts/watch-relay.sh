#!/bin/bash
# ccx-harness :: watch-relay — Claude's side of the relay wait.
#
# Polls .ccx-harness/relay.md until the turn passes back to Claude or a deadline
# blows. Launched by /ccx-harness:send as a Claude Code background task; its exit
# re-invokes Claude, which then follows "When the watcher wakes you" in
# skills/send/SKILL.md. Polling happens here, in bash, so waiting costs Claude
# zero tokens.
#
# Usage:
#   watch-relay.sh <project_dir> <expect_seq> <pickup_deadline_epoch> <work_timeout_seconds> [poll_seconds]
#
# Exit codes:
#   0  turn is Claude's — state DONE|BLOCKED|OFFLINE at seq >= expect_seq (prints "<STATE> <seq>")
#   3  pickup timeout — state still PROMPT_READY past pickup_deadline_epoch
#   4  work deadman — WORKING longer than work_timeout_seconds (clock starts at first observed WORKING)
#   5  relay file missing or unparseable for 10 consecutive polls
#   6  another watcher already holds this project's pidfile
set -u

PROJECT_DIR="${1:?usage: watch-relay.sh <project_dir> <expect_seq> <pickup_deadline_epoch> <work_timeout_s> [poll_s]}"
EXPECT_SEQ="${2:?expect_seq required}"
PICKUP_DEADLINE="${3:?pickup_deadline_epoch required}"
WORK_TIMEOUT_S="${4:?work_timeout_seconds required}"
POLL_S="${5:-30}"

RELAY="$PROJECT_DIR/.ccx-harness/relay.md"
PIDFILE="$PROJECT_DIR/.ccx-harness/watch-relay.pid"
SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/send/SKILL.md"

wake_hint() {
  echo "ccx-harness relay event — follow 'When the watcher wakes you' in $SKILL"
}

# --- single-watcher guard -----------------------------------------------------
if [ -f "$PIDFILE" ]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "another watcher is already running for this project (pid $oldpid)"
    exit 6
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# --- frontmatter reader (first value of a key between the first two '---') -----
fm_field() { # fm_field <key>
  awk -v key="$1" '
    NR==1 { if ($0 != "---") exit; infm=1; next }
    infm && $0=="---" { exit }
    infm && index($0, key ": ") == 1 {
      sub(/^[^:]*: */, "", $0); print; exit
    }' "$RELAY" 2>/dev/null
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

working_since=0
bad_reads=0

while :; do
  state="$(fm_field state || true)"
  seq="$(fm_field seq || true)"

  if [ -z "$state" ] || ! is_num "${seq:-x}"; then
    bad_reads=$((bad_reads + 1))
    if [ "$bad_reads" -ge 10 ]; then
      echo "relay file missing or unparseable after $bad_reads polls: $RELAY"
      wake_hint
      exit 5
    fi
  else
    bad_reads=0
    if [ "$seq" -ge "$EXPECT_SEQ" ]; then
      case "$state" in
        DONE|BLOCKED|OFFLINE)
          echo "$state $seq"
          wake_hint
          exit 0
          ;;
        WORKING)
          if [ "$working_since" -eq 0 ]; then working_since="$(date +%s)"; fi
          if [ $(( $(date +%s) - working_since )) -gt "$WORK_TIMEOUT_S" ]; then
            echo "WORK_TIMEOUT $seq (WORKING > ${WORK_TIMEOUT_S}s by this watcher's clock)"
            wake_hint
            exit 4
          fi
          ;;
        PROMPT_READY)
          if [ "$(date +%s)" -gt "$PICKUP_DEADLINE" ]; then
            echo "PICKUP_TIMEOUT $seq (no ack by deadline)"
            wake_hint
            exit 3
          fi
          ;;
      esac
    fi
  fi

  sleep "$POLL_S"
done
