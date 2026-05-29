# Claude Code(x) Orchestration Harness

`ccx-harness` (CC for Claude **Code**, x for Code**x**: the harness drives both). A Claude Code plugin that turns Claude into an orchestrator for OpenAI Codex.app, with an independent three-reviewer verification gate on every PR Codex opens.

You describe a feature in plain English. Claude interviews you conversationally, drafts a spec, then proposes a test plan targeting 85 to 90 percent coverage with high-confidence end-to-end scenarios. You sign off, and Claude dispatches the spec to Codex by driving the desktop UI: it looks at the screen, finds the Codex thread, pastes the spec, and submits. Codex branches from fresh main, implements, runs tests, opens a PR, and writes a completion file. Codex then drives the UI back the other way, finding your Claude orchestrator thread by name and pasting its completion summary in. Claude reads it, dispatches three parallel Opus reviewer agents that independently grade the PR against the spec, and auto-merges with `gh pr merge --squash --delete-branch` when all three agree. If any one dissents, an adjudicator agent investigates that specific claim against the actual code and decides whether it's real before merging or sending it back for revision.

Both directions are vision-based and symmetric: each agent finds the other's thread by name in the app sidebar, clicks in, pastes, and verifies by screenshot. macOS only.

## The loop in one picture

```
you + Claude (plan)  ->  spec  ->  Claude drives Codex UI (dispatch)
                                          |
                                   Codex implements, opens PR,
                                   writes completion file
                                          |
   Codex drives Claude UI (paste completion into named thread)
                                          |
   Claude runs 3 Opus reviewers  ->  all 3 MERGE  ->  squash-merge + delete branch
                                          |
                       any dissent -> adjudicator fact-checks the claim
                                          -> unfounded: merge / real: revise
```

## What you get

Four slash commands after install:

- `/ccx-harness:setup` calibrates the Codex.app input and send-button coordinates (a hint for the dispatch), optionally wires up ElevenLabs for phone escalation, and proves the loop with a test message.
- `/ccx-harness:plan <feature-slug>` is a conversational planner. It scans `CLAUDE.md`, project memory, and recent git activity, asks one or two questions at a time until the feature is understood, drafts the spec for your review, then proposes unit/integration/e2e tests with an 85 to 90 percent coverage target. It also captures your thread names (see Thread naming below). Writes `specs/<feature-slug>.md` only after you sign off.
- `/ccx-harness:send <feature-slug>` dispatches the spec to Codex by driving the desktop UI. Tells Codex to branch from fresh `origin/main` as `codex/<feature-slug>`, implement, open a PR, write a completion file, and paste the completion back into your named Claude thread. Then exits.
- `/ccx-harness:verify <feature-slug>` runs after Codex's completion lands. Fetches the PR diff, dispatches three parallel Opus reviewer agents that independently grade the PR, and auto-merges if all three return MERGE. If any reviewer dissents, an adjudicator agent fact-checks that claim against the actual code: the PR merges only if the dissent proves unfounded, otherwise a revision is dispatched (or it escalates to you on a genuine judgment call).

Plus a SessionStart hook that creates `.ccx-harness/inbox/` in your project and captures the Claude session id, and an optional MCP channel server (see Completion delivery below).

## Prerequisites

1. **Claude Code** with plugins and hooks enabled. https://claude.com/claude-code
2. **OpenAI Codex.app**, signed in, with shell access to your project. Codex needs `git` and `gh` available so it can branch, push, and open PRs, and `cliclick` + `screencapture` so it can drive the Claude UI to paste completions back.
3. **computer-use MCP** enabled in Claude Code, so Claude can drive the Codex UI to dispatch. macOS only.
4. **`cliclick`** (`brew install cliclick`): coordinate clicks for both directions of UI driving.
5. **`gh` CLI** authenticated (`gh auth login`): Codex opens PRs, the verify skill fetches diffs and merges.
6. **`jq`** on PATH (macOS Sonoma+ ships it, else `brew install jq`): used by the SessionStart hook.
7. **Accessibility + Screen Recording permission** for the terminals/apps that drive the UI (macOS prompts on first use).
8. **(Optional) `node` v18+** only if you want the MCP channel path (terminal-CLI users). Not needed for the desktop app.
9. **(Optional) ElevenLabs + Twilio** if you want the harness to phone you when Codex hits a genuine blocker during a long unattended run. Setup is involved (two accounts), so it has its own guide: [docs/phone-escalation-setup.md](docs/phone-escalation-setup.md). Skip it and blockers just surface in the conversation / inbox instead.

## Install

In Claude Code:

```
/plugin marketplace add <github-owner>/ccx-harness
/plugin install ccx-harness@ccx-harness
/reload-plugins
```

Replace `<github-owner>` with the account or org hosting this repo. Then run setup once:

```
/ccx-harness:setup
```

Setup grants computer-use access to Codex.app, records the Codex input + send coordinates (a fallback hint; dispatch is primarily vision-based), optionally configures ElevenLabs, and sends a test message to confirm the loop. Config is saved to `~/.claude/ccx-harness/config.json`.

## Thread naming (how completions route to the right place)

The harness drives real app windows, so it needs to know which thread is which. There is no stable window id on macOS for these Electron apps, but each app's sidebar shows thread names you control, and that name is the durable handle.

You give the orchestrator two names, either in your orchestrator prompt ("you are the orchestrator in the Claude thread named X; the Codex agent is in thread Y") or when `/ccx-harness:plan` asks you the first time (it stores them in `.ccx-harness/threads.json` so it only asks once). On dispatch, Claude switches Codex to thread Y before pasting. On completion, Codex finds Claude thread X in the sidebar, switches to it, and pastes there. Name your threads distinctively in each app's sidebar so they are findable.

## Daily use (interactive)

```
/ccx-harness:plan magic-link-auth
```

Claude scans the project, captures thread names if it does not have them, then runs a conversational planning session: understanding, then a spec draft for your review, then a test plan with the coverage target. It writes `specs/magic-link-auth.md` after you sign off.

```
/ccx-harness:send magic-link-auth
```

Claude drives the Codex UI: switches to your named Codex thread, pastes the spec (with the reward function, the fresh-main + PR workflow override, and the completion protocol appended), submits, verifies the spinner, and exits.

Codex branches `codex/magic-link-auth` from fresh `origin/main`, implements, opens a PR, writes `.ccx-harness/inbox/magic-link-auth.md`, then drives the Claude UI to paste its completion summary into your named orchestrator thread. That arrives as a normal user turn. Claude then:

1. Fetches the PR diff via `gh pr view` and `gh pr diff`.
2. Dispatches three parallel Opus reviewer agents with identical inputs (spec, completion claim, PR metadata, diff) and a strict rubric.
3. Compares verdicts. All three MERGE: auto-merge via `gh pr merge --squash --delete-branch`. Any dissent: an adjudicator agent investigates the dissenting claim against the actual code, then merges if it's unfounded, dispatches a revision if it's real, or escalates to you if it's a genuine judgment call.

## Autonomous orchestration (overnight queues)

For a hands-off run, wrap the orchestrator under `/loop` (or a cron-driven session) with a queue of specs. The orchestrator dispatches a task, then on each loop tick reads `.ccx-harness/inbox/` for new completion files and acts on them. This pull-based loop is the reliable backbone for unattended runs: it does not depend on a UI paste landing, it just reads the inbox. The vision paste-back is the live in-thread nudge on top of it; if a paste ever misses, the next loop tick still picks the completion up from the inbox.

Operational tasks (deploys, test re-runs, seeding) produce no PR. Codex runs the action against current main and writes a report to the inbox; the orchestrator reviews the report directly and decides pass/continue.

## Completion delivery: two paths

1. **Vision paste-back (default, works on the desktop app).** Codex finds your named Claude thread in the sidebar, clicks in, pastes the completion, submits, and screenshot-verifies. This is the symmetric mirror of how Claude dispatched into Codex.
2. **MCP channel (optional, terminal-CLI only).** The bundled `channel/server.js` watches `.ccx-harness/inbox/_signal` and pushes a `<channel source="ccx-harness-channel">` notification into the session. Channels are a Claude Code research-preview feature gated behind `--channels` / `--dangerously-load-development-channels`, which the desktop app does not pass, so this path only works if you launch via the terminal `claude` CLI with that flag. Dormant (harmless) on the desktop app.

For unattended runs, the inbox poll described above is more reliable than either push path.

## Config

`~/.claude/ccx-harness/config.json` (global):

```json
{
  "version": 1,
  "codex_app": {
    "bundle_id": "com.openai.codex",
    "input_field": {"x": 798, "y": 595},
    "send_button": {"x": 1075, "y": 638}
  },
  "elevenlabs": {
    "enabled": false,
    "endpoint": "https://api.elevenlabs.io/v1/convai/twilio/outbound-call",
    "agent_id": null,
    "agent_phone_number_id": null,
    "to_number": null,
    "api_key": null
  }
}
```

`.ccx-harness/threads.json` (per project, gitignored): `{ "orchestrator_thread_name": "...", "codex_thread_name": "..." }`.

The `codex_app` coordinates are a fallback hint; dispatch reads the screen first. Edit by hand or re-run `/ccx-harness:setup`.

## Spec layout

Generated specs live in `specs/<feature-slug>.md` and are committable. Each has: Context, numbered Acceptance Criteria, a three-layer Test Plan (unit/integration/e2e) with pre-populated scenarios, a Coverage Target (85 to 90 percent, with a deliberate skip list), Architectural Constraints (auto-pulled from `CLAUDE.md` and memory), an Iteration Policy, and an Operator Log that Codex appends to.

## Troubleshooting

**Dispatch landed in the wrong Codex thread.** Make sure the Codex thread name in `.ccx-harness/threads.json` matches the sidebar title exactly. Dispatch switches to that thread before pasting.

**Completion landed in the wrong Claude thread (or nowhere).** Same fix on the Claude side: the orchestrator thread name must match its sidebar title. With no name set (`unspecified`), Codex falls back to the frontmost window, which is unreliable with multiple windows. For unattended runs, rely on the inbox poll, it does not depend on the paste landing.

**Codex could not click the input or send button.** Confirm `cliclick` is installed where Codex runs (`which cliclick`) and that Codex has Accessibility + Screen Recording permission.

**`gh pr merge` failed during auto-merge.** Branch protection, failing checks, or conflicts. The verify skill surfaces the exact error and does not retry blindly. Re-run CI, get a review, or rebase.

**Reviewers disagreed.** Verify surfaces both verdicts and asks you to decide (merge anyway / dispatch revision / hold).

**All three reviewers approved bad code.** Three reviewers plus an adjudicator is a strong filter but not perfect. `gh pr revert <pr_number>` and dispatch a follow-up.

**ElevenLabs call did not fire.** Check `elevenlabs.enabled` and the agent/phone ids in config. The orchestrator constructs the call when it detects a genuine blocker.

## Layout

```
ccx-harness/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── .mcp.json                   # optional channel server (CLI-only path)
├── channel/server.js           # optional: MCP channel, dormant on desktop app
├── hooks/hooks.json            # SessionStart: create inbox, capture session id
├── scripts/session-init.sh
├── skills/
│   ├── setup/SKILL.md
│   ├── plan/SKILL.md           # conversational planner + thread-name capture
│   ├── send/SKILL.md           # vision dispatch + completion protocol
│   └── verify/SKILL.md         # 2-reviewer dispatch + auto-merge
├── templates/spec.template.md
└── README.md
```

## License

MIT. Use it, fork it, send PRs.

## Credits

Built from a daily workflow of using Claude Code to plan features and orchestrate OpenAI Codex to implement them. Fork it, adapt it, make it yours.
