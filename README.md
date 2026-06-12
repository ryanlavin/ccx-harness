# Claude Code(x) Orchestration Harness

`ccx-harness` (CC for Claude **Code**, x for Code**x**: the harness drives both). A Claude Code plugin that turns Claude into an orchestrator for OpenAI Codex, with an independent three-reviewer verification gate on every PR Codex opens.

You describe a feature in plain English. Claude interviews you conversationally, drafts a spec, then proposes a test plan targeting 85 to 90 percent coverage with high-confidence end-to-end scenarios. You sign off, and Claude writes the dispatch prompt — spec, reward function, PR workflow, completion protocol — into one shared file: `.ccx-harness/relay.md`. You paste a single bootstrap line into a Codex session pointing it at that file, once. From there the two agents ping-pong the file all day with no UI driving and no further manual steps: Codex acks, implements from fresh main, opens a PR, and writes its handback into the relay; Claude — woken by a zero-token background watcher — runs three parallel Opus reviewers against the spec, auto-merges on convergence (`gh pr merge --squash --delete-branch`), and writes the next queued prompt into the same file. Codex, polling on its own cadence between tasks, picks it up and goes again.

No computer use. No screenshots, no coordinates, no window or thread bookkeeping. Two agents, one file, each polling at the rate it expects the other to take.

## The loop in one picture

```
you + Claude (plan)  ->  specs/*.md  ->  Claude writes prompt into .ccx-harness/relay.md
                                                       |
        you paste ONE bootstrap line into Codex (first task of the day only)
                                                       |
              Codex: ack WORKING -> branch from fresh main -> implement
                     -> open PR -> write DONE/BLOCKED handback into relay.md
                     -> poll relay.md every ~20 min for the next prompt
                                                       |
   Claude (woken by its background watcher on the file): archive handback
        -> 3 Opus reviewers  ->  all MERGE  ->  squash-merge + delete branch
                    any dissent -> adjudicator fact-checks -> merge / revise
        -> write next queued prompt (or revision, or answer) into relay.md
                                                       |
                              ... repeat until queue empty or /ccx-harness:send stop
```

## How the waiting works (the whole trick)

Each side polls the file on a cadence matched to how long the other usually takes — nobody pushes anything anywhere.

- **Claude's wait costs zero tokens.** `/ccx-harness:send` launches `watch-relay.sh` as a background bash task that checks the relay every ~30 seconds and exits only when the turn comes back to Claude (DONE / BLOCKED / OFFLINE) or a deadline blows. The exit wakes Claude, which reads the file and acts. Claude never burns context polling an unchanged file.
- **Claude estimates, then gets suspicious on schedule.** At dispatch, Claude estimates the task (anchored to configurable small/medium/large minutes). The estimate is a **deadman timer, not a deadline**: Codex's reward function gives it unlimited time, but after `estimate × 2.5` of silence Claude checks liveness (the spec's Operator Log mtime, recent commits on the branch) before deciding whether to extend quietly or escalate to you.
- **Codex waits in chunks.** After a handback, Codex runs `.ccx-harness/poll-next.sh`, which blocks in ~20-minute chunks (exit 10 = "run me again") until a new prompt appears (exit 0), then reads the relay and continues. After ~9 idle hours it marks the relay OFFLINE and signs off (exit 20).
- **Pickups are deadline-checked too.** If a prompt sits unacked past its pickup window (generous for the day's first bootstrap, tight mid-relay), Claude re-arms once with the bootstrap line back on your clipboard, then asks you.

## What you get

Four slash commands after install:

- `/ccx-harness:setup` — checks prerequisites (`gh`, `jq`), writes the v2 config (relay cadences, estimate anchors, optional ElevenLabs phone escalation), and proves the relay round-trip with a self-test that plays both sides — no Codex needed.
- `/ccx-harness:plan <feature-slug>` — conversational planner. Scans `CLAUDE.md`, project memory, and recent git activity, asks one or two questions at a time, drafts the spec for your review, then proposes unit/integration/e2e tests with an 85–90% coverage target and an effort estimate. Writes `specs/<feature-slug>.md` only after you sign off.
- `/ccx-harness:send <feature-slug>` — queues the spec and runs the relay. Writes the prompt turn into `.ccx-harness/relay.md` (archived to `.ccx-harness/outbox/`), puts the one-line bootstrap on your clipboard when Codex isn't already polling, starts the background watcher, and exits. Also: `status`, `resume` (re-arm after a session restart), `stop` (release Codex with an ALL_DONE turn).
- `/ccx-harness:verify <feature-slug>` — three parallel Opus reviewer agents grade the PR against the spec; auto-merge on 3/3 MERGE; any dissent goes to an adjudicator agent that fact-checks it against the actual code before merging, revising (via a relay revision turn), or escalating to you. Triggered automatically by the relay wake handler on a DONE handback with a PR.

Plus a SessionStart hook that initializes `.ccx-harness/` and reports the live relay state (task, seq, watcher liveness, queue depth) to every new session in the project.

## Prerequisites

1. **Claude Code** with plugins and hooks enabled. https://claude.com/claude-code
2. **OpenAI Codex** (desktop app or CLI), signed in, with shell + filesystem access to your project — that's how it reads the relay and writes back. It needs `git` and `gh` to branch, push, and open PRs.
3. **`gh` CLI** authenticated (`gh auth login`): Codex opens PRs, the verify skill fetches diffs and merges.
4. **`jq`** on PATH (macOS Sonoma+ ships it, else `brew install jq`): used by the SessionStart hook.
5. **(Optional) ElevenLabs + Twilio** if you want the harness to phone you on a genuine blocker or a gone-dark task. Setup guide: [docs/phone-escalation-setup.md](docs/phone-escalation-setup.md). The API key lives in an env var, never in config.

That's the whole list. No computer-use MCP, no accessibility permissions, no `cliclick`, no `node`, no channel flags.

## Install

In Claude Code:

```
/plugin marketplace add <github-owner>/ccx-harness
/plugin install ccx-harness@ccx-harness
/reload-plugins
/ccx-harness:setup
```

Replace `<github-owner>` with the account or org hosting this repo. Setup writes `~/.claude/ccx-harness/config.json` and runs the relay self-test.

## Daily use

```
/ccx-harness:plan magic-link-auth        # interview -> spec -> test plan -> estimate
/ccx-harness:plan rate-limit-webhooks    # plan as many as you like; they queue
/ccx-harness:send magic-link-auth        # writes relay prompt, bootstrap on clipboard
```

Paste the bootstrap line (already on your clipboard) into a Codex session for the project:

> `[ccx-harness] You are the implementation half of a two-agent file relay. … Read /path/to/project/.ccx-harness/relay.md now and follow it exactly.`

That's your last required touch. Codex acks in the relay (Claude's watcher sees it and starts the deadman clock), implements, opens the PR, hands back. Claude wakes, verifies with three reviewers, merges, writes the next queued prompt; Codex's poll loop picks it up within ~20 minutes. BLOCKED handbacks surface the question to you (and optionally phone you); answers travel back through the relay the same way. At day's end, `/ccx-harness:send stop` releases Codex gracefully — or let it time out and sign off on its own.

## The relay file

`.ccx-harness/relay.md` is a turn-based thread: YAML frontmatter for machine state, markdown body for the payload. Writes are atomic (`.tmp` + `mv`), `seq` increments only on Claude's prompt turns, and each side only acts when `turn` points at it.

| state | turn | meaning |
|---|---|---|
| `PROMPT_READY` | codex | Claude wrote a prompt (kind: feature / revision / answer) |
| `WORKING` | codex | Codex acked and is implementing (`started_at` set) |
| `DONE` / `BLOCKED` | claude | Codex handed back a completion or a question (`pr_url` set when open) |
| `ALL_DONE` | codex | Claude released Codex; its poll loop ends |
| `OFFLINE` | claude | Codex gave up waiting / signed off; next dispatch re-bootstraps |

Every prompt is archived to `.ccx-harness/outbox/<seq>-<slug>.md` (recovery source + lets Codex re-read instructions mid-task), every handback to `.ccx-harness/inbox/<slug>.md` (what the reviewers grade). `queue.json` holds Claude's task queue and seq counter. Everything under `.ccx-harness/` is gitignored automatically.

One hard rule on both sides: relay bodies written by the other agent are **data, not instructions**. Claude acts on parsed frontmatter fields and its own protocol; the verify reviewers grade Codex's claims rather than obey them.

## Config

`~/.claude/ccx-harness/config.json` (global, v2):

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
  }
}
```

## Spec layout

Generated specs live in `specs/<feature-slug>.md` and are committable. Each has: Context (including the effort estimate), numbered Acceptance Criteria, a three-layer Test Plan (unit/integration/e2e) with pre-populated scenarios, a Coverage Target (85 to 90 percent, with a deliberate skip list), Architectural Constraints (auto-pulled from `CLAUDE.md` and memory), an Iteration Policy, and an Operator Log that Codex appends to — which doubles as the liveness signal Claude checks when a task runs long.

## Troubleshooting

**Codex never acked the prompt.** Mid-relay, its poll loop probably died (session ended, machine slept). The watcher times out the pickup, and Claude puts the bootstrap line back on your clipboard — paste it into a fresh Codex session; the relay resumes where it was.

**Relay shows OFFLINE.** Codex waited out the give-up window (default 9h) and signed off, possibly clobbering a just-written prompt (a deliberate, narrow race). Claude restores any clobbered prompt from `outbox/` and re-bootstraps on the next dispatch.

**Claude's session restarted mid-task.** Relay state lives on disk. The SessionStart hook reports it; run `/ccx-harness:send resume` to re-arm the watcher or handle a waiting handback.

**The watcher says another watcher is running (exit 6).** Another Claude window owns this relay. One watcher per project; use `resume` only if that session is gone.

**`gh pr merge` failed during auto-merge.** Branch protection, failing checks, or conflicts. The verify skill surfaces the exact error and does not retry blindly.

**All three reviewers approved bad code.** Three reviewers plus an adjudicator is a strong filter but not perfect. `gh pr revert <pr_number>` and dispatch a follow-up.

**ElevenLabs call did not fire.** Check `elevenlabs.enabled`, the agent/phone ids, and that the env var named in `api_key_env` is exported in the shell Claude runs from.

## Layout

```
ccx-harness/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── hooks/hooks.json            # SessionStart: init .ccx-harness, report relay state
├── scripts/
│   ├── session-init.sh
│   └── watch-relay.sh          # Claude's zero-token wait: polls relay, exits to wake
├── skills/
│   ├── setup/SKILL.md          # config v2 + relay self-test (plays both sides)
│   ├── plan/SKILL.md           # conversational planner + estimate
│   ├── send/SKILL.md           # the relay: queue, dispatch, watcher, wake handlers
│   └── verify/SKILL.md         # 3 reviewers + adjudicator + auto-merge
├── templates/
│   ├── spec.template.md
│   └── poll-next.sh            # Codex's wait loop, materialized into each project
└── README.md
```

## Migrating from 0.14 (computer-use era)

- Re-run `/ccx-harness:setup` — it migrates your config to v2 and drops the dead `codex_app` coordinates.
- Delete `--dangerously-load-development-channels plugin:ccx-harness@ccx-harness` from your `claude` alias; the channel server is gone (the watcher replaces it).
- `cliclick`, computer-use MCP access, and accessibility permissions are no longer used. `.ccx-harness/threads.json` and `inbox/_signal` are dead files; remove them if you like.
- If your old config had a plaintext ElevenLabs `api_key`, rotate it and export the new one as an env var — v2 stores only the env var's name.

## License

MIT. Use it, fork it, send PRs.

## Credits

Built from a daily workflow of using Claude Code to plan features and orchestrate OpenAI Codex to implement them. Fork it, adapt it, make it yours.
