#!/bin/bash
# ccx-harness :: session-init
# Runs on every Claude Code SessionStart. Initializes the per-project .ccx-harness
# directory, captures the session_id, and reports the current relay state so a
# fresh session knows whether a Claude⇄Codex relay is mid-flight in this project.
set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')

if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

HARNESS_DIR="${PROJECT_DIR}/.ccx-harness"
RELAY_FILE="${HARNESS_DIR}/relay.md"
QUEUE_FILE="${HARNESS_DIR}/queue.json"
PIDFILE="${HARNESS_DIR}/watch-relay.pid"
SESSION_FILE="${HARNESS_DIR}/.session-id"
GITIGNORE_FILE="${HARNESS_DIR}/.gitignore"

mkdir -p "${HARNESS_DIR}/inbox" "${HARNESS_DIR}/outbox"

if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "*" > "$GITIGNORE_FILE"
fi

if [[ -n "$SESSION_ID" ]]; then
  echo "$SESSION_ID" > "$SESSION_FILE"
fi

# --- frontmatter reader (tolerant; missing file/keys yield empty) -------------
fm_field() {
  awk -v key="$1" '
    NR==1 { if ($0 != "---") exit; infm=1; next }
    infm && $0=="---" { exit }
    infm && index($0, key ": ") == 1 {
      sub(/^[^:]*: */, "", $0); print; exit
    }' "$RELAY_FILE" 2>/dev/null || true
}

RELAY_STATUS="no active relay"
if [[ -f "$RELAY_FILE" ]]; then
  R_STATE=$(fm_field state); R_TASK=$(fm_field task)
  R_SEQ=$(fm_field seq);     R_AT=$(fm_field written_at)
  WATCHER="not running"
  if [[ -f "$PIDFILE" ]]; then
    W_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n "$W_PID" ]] && kill -0 "$W_PID" 2>/dev/null; then
      WATCHER="running (pid ${W_PID})"
    fi
  fi
  RELAY_STATUS="state=${R_STATE:-?} task=${R_TASK:-?} seq=${R_SEQ:-?} written_at=${R_AT:-?}; watcher ${WATCHER}"
fi

QUEUE_STATUS=""
if [[ -f "$QUEUE_FILE" ]]; then
  QUEUE_STATUS=$(jq -r '"queued=\(.queued | length) active=\(.active.slug // "none") done=\(.done | length)"' "$QUEUE_FILE" 2>/dev/null || true)
fi

jq -n \
  --arg sid "$SESSION_ID" \
  --arg pdir "$PROJECT_DIR" \
  --arg relay "$RELAY_STATUS" \
  --arg queue "${QUEUE_STATUS:-no queue}" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("ccx-harness (relay mode) initialized for project " + $pdir + ". Session id: " + $sid + ". Claude and Codex coordinate through .ccx-harness/relay.md (turn-based; no computer use). Relay: " + $relay + ". Queue: " + $queue + ". If the relay shows a Claude-turn state (DONE/BLOCKED/OFFLINE) or a Codex-turn state with the watcher not running, do not act on it unprompted — another session may own it; if the user asks, run /ccx-harness:send resume.")
    }
  }'
