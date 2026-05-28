#!/bin/bash
# ccx-harness :: session-init
# Runs on every Claude Code SessionStart. Initializes the per-project .ccx-harness
# directory and captures the session_id. The channel MCP server (see .mcp.json)
# handles the actual completion-notification push; this hook just sets up the
# filesystem state the channel server expects to find.
set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')

if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

HARNESS_DIR="${PROJECT_DIR}/.ccx-harness"
INBOX_DIR="${HARNESS_DIR}/inbox"
SIGNAL_FILE="${INBOX_DIR}/_signal"
SESSION_FILE="${HARNESS_DIR}/.session-id"
GITIGNORE_FILE="${HARNESS_DIR}/.gitignore"

mkdir -p "$INBOX_DIR"

if [[ ! -f "$GITIGNORE_FILE" ]]; then
  echo "*" > "$GITIGNORE_FILE"
fi

if [[ ! -f "$SIGNAL_FILE" ]]; then
  : > "$SIGNAL_FILE"
fi

if [[ -n "$SESSION_ID" ]]; then
  echo "$SESSION_ID" > "$SESSION_FILE"
fi

jq -n \
  --arg sid "$SESSION_ID" \
  --arg pdir "$PROJECT_DIR" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("ccx-harness initialized for project " + $pdir + ". Session id: " + $sid + ". Completion inbox: .ccx-harness/inbox/, signal file: .ccx-harness/inbox/_signal. The ccx-harness-channel MCP server is watching the signal file and will push completion notifications as <channel source=\"ccx-harness-channel\"> messages when Codex finishes a dispatched feature.")
    }
  }'
