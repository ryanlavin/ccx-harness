---
name: setup
description: First-run calibration for ccx-harness. Captures the Codex.app input-field and send-button screen coordinates, optionally configures ElevenLabs for blocked-state phone escalation, sends a test message, and writes the result to ~/.claude/ccx-harness/config.json. Run this once after installing the plugin, and again whenever the Codex.app UI changes or you move to a new monitor.
user-invocable: true
allowed-tools: Bash Read Write Edit mcp__computer-use__request_access mcp__computer-use__open_application mcp__computer-use__cursor_position mcp__computer-use__screenshot mcp__computer-use__write_clipboard mcp__computer-use__computer_batch mcp__computer-use__list_granted_applications AskUserQuestion
---

# ccx-harness :: setup

You are walking the user through one-time calibration so the rest of the harness can talk to OpenAI Codex.app. The goal of this skill is to produce a valid `~/.claude/ccx-harness/config.json` and prove it works by sending one test message.

Do every step. Do not skip steps or guess values.

## Preconditions to check

1. **computer-use MCP is available.** If `mcp__computer-use__*` tools are not in your toolset, stop and tell the user:
   > The computer-use MCP isn't enabled in this Claude Code session. Install it from the MCP registry or your Claude Code settings, then re-run `/ccx-harness:setup`.

2. **Codex.app is installed.** Run `ls -d "/Applications/Codex.app" 2>/dev/null || ls -d "$HOME/Applications/Codex.app" 2>/dev/null`. If neither path exists, tell the user:
   > I don't see Codex.app in /Applications. Install it from https://chatgpt.com/codex/download (or your usual source), launch it, sign in, then re-run `/ccx-harness:setup`.

3. **`jq` is installed.** Run `which jq`. The plugin's hooks depend on it. If missing, tell the user:
   > Install jq with `brew install jq`, then re-run `/ccx-harness:setup`.

4. **`node` is installed (v18+).** Run `which node && node --version`. The channel server is plain Node. If missing or older than v18, tell the user to install/upgrade.

4b. **`cliclick` is installed.** Run `which cliclick`. When Codex pastes its completion back into Claude, it uses cliclick to click the chat input and Send button at the coordinates it reads from a screenshot (vision-based, the same way Claude drives Codex). If missing, tell the user:
   > Install cliclick with `brew install cliclick`, then re-run `/ccx-harness:setup`. Codex uses it to click into the Claude window when pasting completions back.

5. **Hooks are active.** Check that `${CLAUDE_PROJECT_DIR}/.ccx-harness/.session-id` exists. If missing, the SessionStart hook didn't fire (most likely because the plugin was just installed in this very session). Tell the user:
   > The ccx-harness hooks haven't activated yet. Quit and restart Claude Code, then re-run `/ccx-harness:setup`. One-time only; future sessions auto-init.

6. **Channel server enabled.** This is the critical one. Ask the user:
   > Have you added `--dangerously-load-development-channels plugin:ccx-harness@ccx-harness` to your `claude` shell function or invocation? Without it, the channel server runs but its completion notifications get dropped, so Codex finishing a feature won't auto-trigger anything in this session.
   
   If they're unsure, offer to inspect their `claude` shell function and walk them through the edit. The flag goes on the `command claude ...` line in their `.zshrc` / `.bashrc`. Example:
   ```bash
   command claude --dangerously-skip-permissions --dangerously-load-development-channels plugin:ccx-harness@ccx-harness "${args[@]}"
   ```
   
   After they add it, they need to `source ~/.zshrc` and restart Claude Code.

7. **Config dir exists.** Run `mkdir -p ~/.claude/ccx-harness`.

## Step 1: request access and bring Codex forward

Call `mcp__computer-use__request_access` with `applications: ["com.openai.codex"]`. Tell the user:
> I'm requesting access to Codex.app so I can read its window and click into it. Please approve the prompt.

Once granted, call `mcp__computer-use__open_application` with `application: "Codex"` to bring it to the front.

Take a screenshot with `mcp__computer-use__screenshot` and confirm in chat that you can see the Codex chat window with a visible input field at the bottom and a send button to its right. If you cannot see those, ask the user to resize Codex so both are visible, then re-screenshot.

## Step 2: capture the INPUT FIELD coordinates

Say to the user:
> I'll now record where Codex's chat input field is. **Hover your mouse cursor over the chat input area** (the text box where you type prompts). Don't click, just hover. Reply 'ready' when your cursor is in place.

Wait for the user to reply 'ready' (or equivalent). Then call `mcp__computer-use__cursor_position` and capture the returned `{x, y}`. Show the captured coords back to the user:
> Captured input field at (X, Y). Want to keep this or recapture?

If they want to recapture, repeat. If they confirm, store as `codex_app.input_field`.

## Step 3: capture the SEND BUTTON coordinates

Same flow, but for the send button:
> Now hover over the **send button** (usually a small arrow/paper-plane icon to the right of the input). Reply 'ready' when in place.

Capture with `mcp__computer-use__cursor_position`. Confirm and store as `codex_app.send_button`.

## Step 4: optional ElevenLabs escalation

Ask the user via AskUserQuestion:
- Question: "Do you want to wire up ElevenLabs so the harness calls your phone when Codex gets blocked (3 identical failures, or asks a clarifying question)?"
- Options: "Yes, configure now", "Skip for now"

If they skip, set `elevenlabs.enabled = false` and move on.

If they want to configure, ask plainly in chat for these values, one at a time (do NOT use AskUserQuestion since these are free-form secrets/IDs):
1. ElevenLabs API key environment variable name (default: `ELEVENLABS_API_KEY`). Tell them not to paste the key itself, just the env var name.
2. Agent ID (the conversational agent that will make the call)
3. Phone number ID (the outbound number)
4. Their phone number (the destination, in E.164 format e.g. `+15551234567`)

Set `elevenlabs.enabled = true` and fill the values. Endpoint defaults to `https://api.elevenlabs.io/v1/convai/conversations/{agent_id}/outbound-call` (you can hardcode this template).

## Step 5: write config.json

Write `~/.claude/ccx-harness/config.json` with this exact schema:

```json
{
  "version": 1,
  "codex_app": {
    "bundle_id": "com.openai.codex",
    "input_field": {"x": <captured>, "y": <captured>},
    "send_button": {"x": <captured>, "y": <captured>}
  },
  "elevenlabs": {
    "enabled": <true|false>,
    "endpoint_template": "https://api.elevenlabs.io/v1/convai/conversations/{agent_id}/outbound-call",
    "agent_id": <"..." or null>,
    "phone_number_id": <"..." or null>,
    "api_key_env": <"ELEVENLABS_API_KEY" or null>,
    "caller_phone": <"+1..." or null>
  },
  "specs_dir": "specs",
  "calibrated_at": "<ISO 8601 timestamp, run `date -u +%Y-%m-%dT%H:%M:%SZ`>"
}
```

## Step 6: prove it works

1. Bring Codex.app forward again (`open_application "Codex"`).
2. Write the calibration message to clipboard with `mcp__computer-use__write_clipboard`:
   > `[ccx-harness calibration test] Please reply with the single word 'ok' and then stop. Do not start any work.`
3. Use `mcp__computer-use__computer_batch` to:
   - `left_click` at the captured input_field coords
   - `key` `cmd+v`
   - `wait` 1 second
   - `left_click` at the captured send_button coords
4. Wait 3 seconds, then `mcp__computer-use__screenshot`.
5. Verify the screenshot shows either (a) a spinner / stop button (still working), or (b) Codex's 'ok' reply. If neither, the calibration is off. Show the screenshot to the user and offer to recapture coords.

## Step 7: confirm and exit

Tell the user:
> Setup complete. Config saved to `~/.claude/ccx-harness/config.json`. You can now use:
>
> - `/ccx-harness:plan <feature name>` to interview and write a spec
> - `/ccx-harness:send <feature name>` to dispatch the spec to Codex
>
> When Codex finishes, it pastes its completion back into this conversation via computer-use and submits it. If Codex's UI ever changes or you move it to a different monitor, re-run `/ccx-harness:setup`.
