---
name: setup
description: First-run setup for ccx-harness (relay mode). Checks prerequisites, writes ~/.claude/ccx-harness/config.json (v2 schema with relay cadences, estimate anchors, and optional ElevenLabs phone escalation), migrates v1 configs, and proves the relay round-trip with a self-test that needs no Codex. Run once after installing the plugin; re-run any time to change cadences or escalation.
user-invocable: true
allowed-tools: Bash Read Write Edit AskUserQuestion
---

# ccx-harness :: setup

You are producing a valid v2 `~/.claude/ccx-harness/config.json` and proving the relay machinery works end to end — without needing Codex present. There is no screen calibration anymore: the harness has no computer-use anywhere. Claude and Codex talk only through `.ccx-harness/relay.md`, each polling on its own cadence.

Do every step. Do not skip steps or guess values.

## Preconditions to check

Run these checks in parallel; report all failures at once:

1. **`git` and `gh`, authenticated.** `gh auth status`. Codex opens PRs with `gh`; the verify skill fetches diffs and merges with it. If unauthenticated, tell the user to run `! gh auth login` and re-run setup.
2. **`jq` on PATH.** Used by the SessionStart hook. If missing: `brew install jq`.
3. **Hooks are active.** Check `${CLAUDE_PROJECT_DIR}/.ccx-harness/.session-id` exists. If missing, the plugin was likely installed during this very session: tell the user to restart Claude Code once, then re-run setup.
4. **Codex has filesystem access to this project.** Nothing to verify programmatically — just confirm with the user that their Codex sessions for this project run with shell + filesystem access to the project directory (that is how it reads the relay file and the spec, and writes its handback). Codex.app and the Codex CLI both qualify.

Note what is now NOT required, in case the user has v1 leftovers: no computer-use MCP, no `cliclick`, no `node`, no `--dangerously-load-development-channels` flag in their `claude` alias (the channel server is gone — they can delete that flag from their shell rc).

## Step 1: relay cadences

Explain the three knobs in one short paragraph, then ask whether the defaults are fine (AskUserQuestion, single question, options "Use defaults (Recommended)" / "Customize"):

- `recheck_minutes` (default **20**): how often an idle Codex re-checks the relay for its next prompt. Lower = faster pickup between tasks, slightly chattier Codex session.
- `work_timeout_multiplier` (default **2.5**): Claude gets suspicious after `estimate × multiplier` of WORKING silence — it then checks liveness before bothering anyone.
- `codex_give_up_hours` (default **9**): an idle Codex stops polling and signs off after this long with no new prompt (roughly a workday).

If they customize, collect the values in chat. Estimate anchors (`small/medium/large` minutes, defaults 20/45/90) and poll intervals rarely need changing; mention they exist and move on.

## Step 2: optional ElevenLabs phone escalation

AskUserQuestion: "Want the harness to phone you when Codex hits a genuine blocker or goes dark mid-task? (Requires an ElevenLabs conversational agent + Twilio number — see docs/phone-escalation-setup.md.)" Options: "Yes, configure now" / "Skip for now".

If skipped: `elevenlabs.enabled = false`.

If configuring, collect in plain chat (free-form values, not AskUserQuestion):

1. The **environment variable name** holding their API key (default `ELEVENLABS_API_KEY`). The key itself NEVER goes in the config file. If a v1 config exists with a plaintext `api_key`, point it out, tell them to move the key into the env var in their shell rc, and **recommend rotating it** since it sat in a file on disk.
2. Agent ID.
3. Phone number ID (the outbound number).
4. Their phone number (E.164, e.g. `+15551234567`).

## Step 3: write config.json

`mkdir -p ~/.claude/ccx-harness`, then write `~/.claude/ccx-harness/config.json`:

```json
{
  "version": 2,
  "specs_dir": "specs",
  "relay": {
    "recheck_minutes": 20,
    "claude_poll_seconds": 30,
    "codex_poll_seconds": 60,
    "pickup_grace_minutes": 5,
    "bootstrap_pickup_minutes": 120,
    "work_timeout_multiplier": 2.5,
    "codex_give_up_hours": 9
  },
  "estimates_minutes": { "small": 20, "medium": 45, "large": 90 },
  "elevenlabs": {
    "enabled": false,
    "endpoint_template": "https://api.elevenlabs.io/v1/convai/conversations/{agent_id}/outbound-call",
    "agent_id": null,
    "phone_number_id": null,
    "api_key_env": "ELEVENLABS_API_KEY",
    "to_number": null
  },
  "configured_at": "<ISO 8601 UTC now>"
}
```

If a v1 config exists, carry over its ElevenLabs values (mapped to the v2 keys, key itself excluded per Step 2) and drop `codex_app` entirely — coordinates are dead. `chmod 600` the file.

## Step 4: prove the relay round-trip (no Codex needed)

Run the self-test in the current project. You play both sides; this exercises the exact scripts and file format the real flow uses.

```bash
mkdir -p .ccx-harness
cp "${CLAUDE_PLUGIN_ROOT}/templates/poll-next.sh" .ccx-harness/poll-next.sh
chmod +x .ccx-harness/poll-next.sh
```

1. **Claude's write, Codex's read.** Write a test prompt turn to `.ccx-harness/relay.md` (atomic: `.tmp` then `mv`) with `seq: 999`, `turn: codex`, `state: PROMPT_READY`, `task: setup-self-test`. Then run Codex's poller as Codex would:
   `CCX_CHUNK_MIN=0 bash .ccx-harness/poll-next.sh 998; echo "exit=$?"`
   Expect `exit=0` (it sees seq 999 > 998 on a codex turn). Anything else: the poller or the file format is broken — stop and debug before telling the user setup succeeded.
2. **Codex's handback, Claude's watcher.** Rewrite the relay file as a handback: `seq: 999`, `turn: claude`, `state: DONE`. Then run the watcher in fast foreground mode:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/watch-relay.sh" "$(pwd)" 999 $(($(date +%s)+60)) 60 1; echo "exit=$?"`
   Expect it to print `DONE 999` and `exit=0` within a second or two.
3. **Clean up:** `rm -f .ccx-harness/relay.md .ccx-harness/.poll-state .ccx-harness/watch-relay.pid`.

If both legs pass, the relay is proven: file format, atomic writes, both pollers, exit codes.

## Step 5: confirm and exit

Tell the user:

> Setup complete — config at `~/.claude/ccx-harness/config.json`, relay self-test passed. The flow is now:
>
> - `/ccx-harness:plan <feature>` — interview, spec, test plan.
> - `/ccx-harness:send <feature>` — writes the prompt into `.ccx-harness/relay.md` and puts a one-line bootstrap on your clipboard. **Paste that one line into a Codex session for this project** — that's the only manual step all day.
> - Codex acks in the relay file, implements, opens a PR, writes its handback to the same file, then polls every 20 minutes for its next prompt. I watch the file for free in the background, wake when it's my turn, run the three-reviewer verify, merge, and write the next queued prompt. We keep ping-ponging until the queue is empty or you say `/ccx-harness:send stop`.
