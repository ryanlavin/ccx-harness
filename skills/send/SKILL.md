---
name: send
description: Dispatch a spec to OpenAI Codex.app via computer-use, embedding a completion protocol so Codex writes its results to .ccx-harness/inbox/ and pastes a completion summary back into this Claude thread (via computer-use) when finished. Reads specs/{feature}.md and ~/.claude/ccx-harness/config.json. Run /ccx-harness:setup once before first use.
argument-hint: <feature-slug>
user-invocable: true
allowed-tools: Bash Read Write Edit mcp__computer-use__request_access mcp__computer-use__open_application mcp__computer-use__write_clipboard mcp__computer-use__computer_batch mcp__computer-use__screenshot mcp__computer-use__list_granted_applications AskUserQuestion
---

# ccx-harness :: send

You dispatch a spec to Codex.app and then **exit**. There is no monitoring loop. Codex writes a completion summary to `.ccx-harness/inbox/<feature>.md` and, when done, pastes that summary back into this Claude thread via computer-use and submits it (the same vision-based mechanism you use to paste into Codex). It arrives as a new user turn, so the user sees it land mid-conversation.

## Step 0: parse arguments

The user typed `/ccx-harness:send <feature-slug>`.

- If no slug given, list `ls specs/` and ask which one. Abort if `specs/` is empty.
- Sanitize the slug to filesystem-safe characters (lowercase, kebab-case).

## Step 1: preflight

Run these in parallel:

1. Read `~/.claude/ccx-harness/config.json`. If missing, tell the user to run `/ccx-harness:setup` first and stop.
2. Read `specs/<feature-slug>.md`. If missing, tell the user to run `/ccx-harness:plan <feature-slug>` first and stop.
3. Read `.ccx-harness/.session-id` for the current Claude session id. If missing, the SessionStart hook didn't fire; warn the user that auto-notification won't work and ask if they want to continue anyway. (The most common cause is that they installed the plugin during this very session and need to start a new Claude Code session to activate hooks.)
4. Capture working dir (`pwd`). Detect the repo's default branch (almost always `main`) with `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'` (fall back to `main` if that returns nothing). Do NOT capture the current local branch as the base. Every harness task branches from FRESH `origin/<default>`, not from whatever happens to be checked out, so no task inherits another task's in-flight state.

5. Resolve the two thread names, in this priority order:
   - Your orchestrator prompt context (the prompt typically says "you are the orchestrator in the Claude thread named X; the Codex agent is in thread Y"), else
   - `.ccx-harness/threads.json` (keys `orchestrator_thread_name`, `codex_thread_name`), written by `/ccx-harness:plan`, else
   - ask the user in plain chat for both names now, and write them to `.ccx-harness/threads.json` so it's asked once.

   The two names:
   - **Your own Claude thread name** (the orchestrator thread). Where Codex must paste the completion back. You embed it in the dispatch payload so Codex finds your thread in the Claude sidebar and switches to it. If unknown after all three sources, pass `unspecified`; Codex falls back to the frontmost Claude window (unreliable with multiple windows open).
   - **The Codex thread name** you dispatch into. Used in Step 3 to switch Codex to the right thread before pasting, so you don't dispatch into the wrong Codex conversation.


## Step 2: compose the dispatch payload

Build a single self-contained payload Codex will receive. Structure:

```
[ccx-harness dispatch :: <feature-slug>]

Working directory: <pwd>
Base branch: <default branch, e.g. main> (you MUST branch from FRESH origin/<default>, never from any local checkout)
Claude session id: <session-id from .ccx-harness/.session-id>
Paste your completion back into the Claude thread named: "<orchestrator thread name, or 'unspecified'>"
Dispatched at: <ISO 8601 timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`>

You are receiving a spec produced by an interactive planning session in Claude Code. Read the entire spec below before writing code. Follow the Iteration Policy at the bottom of the spec strictly. Append progress to the Operator Log section as you work.

================================================================
REWARD FUNCTION (read this before anything else)
================================================================

You are optimizing for these hard success criteria, not for speed or
elapsed time:

  R1. Every acceptance criterion in the spec passes (observable behavior,
      not just code presence).
  R2. Unit, integration, and e2e tests are all green on the head branch.
  R3. Coverage on changed code lands in the 85 to 90 percent target range
      from the spec, skipping the deliberate gaps the spec lists.
  R4. PR is opened on `codex/<feature-slug>` against the base branch via
      `gh pr create`.
  R5. Completion summary is written to `.ccx-harness/inbox/<feature-slug>.md`
      and `_signal` is updated, per the Completion Protocol at the end of
      this payload.

There is NO time limit on this work. No iteration cap. No "let's stop here
for now" exit. You stop only on ONE of two conditions:

  (a) DONE — all five reward criteria above are met.
  (b) BLOCKED — you hit a hard architectural or environmental wall that
      genuinely requires the human user's judgment to unblock.

The following are NOT blockers. Fix them yourself and keep going:
- Failing tests (debug them — that is literally the point of running them)
- Missing dependencies (install them)
- Linter / type-checker errors (fix them)
- Production bugs surfaced by your new tests (fix as part of the feature)
- Flaky CI runs (re-run, identify the cause, fix the flake)
- Authentication issues with services you have credentials for (re-auth)
- Code that needs refactoring to make the feature testable (refactor)

Genuine blockers (declaring BLOCKED is appropriate):
- A core architectural decision the spec did not anticipate
- Missing credentials for a service the user has not provided access to
- A constraint conflict between two pieces of the spec
- Hardware or external-system failures outside your control

Do not preemptively call yourself blocked. If uncertain whether something
is a blocker, attempt the fix first. Most things that feel like blockers
are not. If you are tempted to write "I've made significant progress, let
me stop here and come back later," that is a violation of this reward
function. Keep going until DONE or genuinely BLOCKED.

================================================================
HARNESS WORKFLOW (overrides any "push to main" defaults)
================================================================

For this feature, you MUST use a PR-based workflow, not direct push to main. The discipline is: every task starts from FRESH `origin/<base-branch>`, no task inherits another's state, and no branch outlives its PR. This keeps main the single source of truth and kills branch drift at the source.

1. Branch from fresh `origin/<base-branch>`, NOT from whatever is currently checked out:
   ```
   git fetch origin <base-branch>
   git checkout -b codex/<feature-slug> origin/<base-branch>
   ```
   If a local `codex/<feature-slug>` branch already exists from a prior attempt, delete it first (`git branch -D codex/<feature-slug>`) so you start clean.

2. Commit as you iterate on that branch. Push to the remote at least once before opening the PR.

3. When all acceptance criteria pass and all three test layers are green, open a PR against the base branch:
   `gh pr create --base <base-branch> --head codex/<feature-slug> --title "<feature-slug>: <one-line goal>" --body "<short body referencing specs/<feature-slug>.md and the completion file>"`

4. Capture the PR URL from gh's output. You need it in the completion frontmatter.

5. Do NOT merge the PR yourself. The harness runs an independent three-reviewer verification on the PR after you signal completion. On convergence it merges with `gh pr merge --squash --delete-branch`, so your branch is deleted the moment it merges. You never need to clean up the branch yourself.

================================================================
SPEC
================================================================

<full contents of specs/<feature-slug>.md>

================================================================
COMPLETION PROTOCOL (required before stopping)
================================================================

When you have either:
  (a) completed all acceptance criteria with all three test layers green AND the PR is open, OR
  (b) hit a hard blocker that needs human intervention (matches the BLOCKED definition in the Iteration Policy)

do these THREE steps exactly, in order, before stopping:

1. Write a completion summary to `.ccx-harness/inbox/<feature-slug>.md` (relative to the working directory above). Use this exact template, filling every field. Do NOT use the spec template; use this one:

----- BEGIN COMPLETION TEMPLATE -----
---
feature: <feature-slug>
status: DONE | BLOCKED
session_id: <Claude session id from above>
dispatched_at: <ISO timestamp from above>
completed_at: <ISO timestamp now, `date -u +%Y-%m-%dT%H:%M:%SZ`>
base_branch: <base branch from above>
head_branch: codex/<feature-slug>
commit: <`git rev-parse --short HEAD`>
pr_url: <full https://github.com/... URL from `gh pr create` output, or 'none' if BLOCKED before PR>
---

# <feature-slug>: <DONE or BLOCKED>

## Summary
<one paragraph in plain English: what the user can now do that they could not before, or what blocked you>

## Acceptance criteria
- [x] <criterion 1 from spec, verbatim>
- [x] <criterion 2 from spec, verbatim>
- [ ] <criterion 3 from spec, verbatim, with one-line reason if not met>

## Test results
- Unit: <P>/<T> passing
- Integration: <P>/<T> passing
- E2E: <P>/<T> passing
- Coverage: <line%>/<branch%> on changed code (run the coverage report and paste the actual numbers; spec target was 85–90%)
- Test command(s) the user can re-run: `<commands>`

## Files changed
<output of `git diff --stat <base-branch>...codex/<feature-slug>`>

## Issues encountered
<bulleted, only the ones worth surfacing; omit section if none>

## Next steps for the user
<what the user should do next: review diff, merge, follow-up tasks, etc.>
----- END COMPLETION TEMPLATE -----

2. Write a single line to `.ccx-harness/inbox/_signal` (OVERWRITE; do NOT append):

   latest=<feature-slug>.md

3. Paste the completion back into the orchestrator's Claude thread and submit it, using your own computer-use ability the SAME way Claude used computer-use to paste this spec into your window: bring the app to the front, take a screenshot, find the chat input by looking at the screen, click it, paste, click Send, screenshot again to confirm it submitted, and iterate if it didn't. You locate the input and Send button visually each time, not from pre-recorded coordinates. The Claude desktop app doesn't support channels (research preview is CLI-only), so this screenshot-driven paste is the delivery mechanism for desktop users.

   First, put the notification on the clipboard and fire a backstop macOS notification, so the user is pinged even if every paste attempt fails:

   ```bash
   FEATURE="<feature-slug>"; STATUS="<status>"; PR_URL="<pr_url>"
   NOTIFY="[ccx-harness] Completion landed for ${FEATURE}. Status: ${STATUS}. PR: ${PR_URL}. Read .ccx-harness/inbox/${FEATURE}.md and follow the ccx-harness:verify protocol now: dispatch three parallel Opus reviewers; auto-merge if all three agree, otherwise adjudicate the dissent."
   printf '%s' "$NOTIFY" | pbcopy
   /usr/bin/osascript -e "display notification \"Completion landed for ${FEATURE}. If Claude did not respond, paste from clipboard.\" with title \"ccx-harness\" sound name \"Glass\""
   ```

   Then drive the paste-back as a screenshot loop, targeting the named orchestrator thread (the "Paste your completion back into the Claude thread named ..." line in the dispatch header above). macOS tools you have: `osascript -e 'tell application "Claude" to activate'` (bring Claude forward), `screencapture -x /tmp/ch-N.png` (capture screen), your vision (read the screenshot), `cliclick c:X,Y` (click coordinates you read off the screenshot), `osascript -e 'tell application "System Events" to keystroke "v" using {command down}'` (paste). Loop:

   a. Activate Claude, screenshot, look at it.
   b. **Switch to the named orchestrator thread.** Open the Claude sidebar (there is an "Open sidebar" control near the top-left; click it if the thread list isn't already visible). Read the thread titles in the sidebar and find the one matching the thread name from the dispatch header. Click it to switch to that thread. This is the fix for completions landing in the wrong thread: you target by NAME, not by whatever window is frontmost. Screenshot to confirm that thread is now active.
      - If the thread name was `unspecified`, fall back to the frontmost Claude window (best-effort).
      - If you cannot find a thread with that name in the sidebar, stop; the backstop notification + clipboard cover it. Append `delivery: thread-not-found`.
   c. Click the active thread's chat input box (bottom of the window), then paste (Cmd+V).
   d. Screenshot again. Confirm your text now sits in the input box of the correct thread. If it landed in the wrong place or didn't appear, correct and retry.
   e. Click the Send button (the up-arrow at the bottom-right of the composer). Screenshot again.
   f. Confirm the text left the input and now appears as a submitted user turn in the named thread. If it's still in the input, click Send again. Iterate (a few attempts) until it's submitted in the right thread.

   Append a one-line delivery status to `.ccx-harness/inbox/<feature-slug>.md`: `delivery: submitted` (screenshot-confirmed in the named thread), `delivery: thread-not-found` (named thread not in sidebar), or `delivery: unverified` (clicked but could not confirm).

   Notes for Codex:
   - This is symmetric to how Claude dispatched into you: Claude switched to your named Codex thread, then pasted. You switch to its named Claude thread, then paste. Both sides target by thread name via the sidebar, found visually.
   - Requires Accessibility + Screen Recording permission for the shell running this (macOS prompts once; the user approves).
   - The backstop notification + clipboard already fired before the loop, so even total failure leaves the user pinged with the text ready to paste. Never loop forever; a few attempts, then stop and record the delivery status.

4. Stop. Do not continue iterating after writing the signal and triggering the notification. Do not write to `_signal` while still working; intermediate progress goes only into the spec's Operator Log section.

If you ignore the Completion Protocol, the user's Claude session will never be notified, the PR will sit unreviewed, and your work effectively disappears.
```

Hold this payload in working memory. Do not paste it back into chat (it's long and noisy).

## Step 3: dispatch via computer-use

Drive this by looking at the screen, not by trusting stale coordinates. The `config.codex_app` coordinates are a hint for where the input and send button usually are; the screenshot is the source of truth. This is the same vision-based loop Codex uses to paste back into Claude, just in the other direction.

1. `mcp__computer-use__list_granted_applications` to verify Codex.app access. If not granted, call `mcp__computer-use__request_access` with `["com.openai.codex"]` and ask the user to approve.
2. `mcp__computer-use__write_clipboard` with the dispatch payload.
3. `mcp__computer-use__open_application` with `"Codex"`, then `mcp__computer-use__screenshot`. Look at it. **If you were given the Codex thread name** (Step 1), switch to it first: open Codex's sidebar/thread list, find the thread with that name, and click it so you dispatch into the right conversation, not whatever Codex thread happens to be open. Then locate the Codex chat input. If no Codex thread name was given, use the currently-open thread.
4. `left_click` the input at the coordinates you read from the screenshot (fall back to `config.codex_app.input_field` only if the screenshot is ambiguous), `key` `cmd+v` to paste, then `left_click` the send button (coords from the screenshot, `config.codex_app.send_button` as the fallback hint).
5. Wait ~3 seconds, `mcp__computer-use__screenshot` again. Verify a spinner / stop button appeared, meaning Codex accepted the dispatch.
6. If the send button is still idle and no new message bubble appeared, the paste missed. Re-screenshot, re-locate the input visually, and retry once. If it still fails, surface the screenshot and suggest `/ccx-harness:setup` to recalibrate the hint coordinates. Do not retry blindly more than once.

## Step 4: log and exit

1. Append to the spec's Operator Log section:
   ```
   [<ISO timestamp>] DISPATCHED — payload sent to Codex (session: <claude-session-id>, branch: <branch>)
   ```
2. Tell the user, in one or two sentences:
   > Dispatched `<feature-slug>` to Codex. I'll be quiet now. When Codex finishes (or blocks), it will paste its completion summary back into this thread and submit it, the same way I just pasted into Codex.

3. **Exit cleanly.** Do not schedule wake-ups. Do not poll. Do not screenshot Codex again. Codex pastes the completion back into this thread via computer-use when it's done (its Completion Protocol step 3), which arrives here as a new user turn.

## When the completion lands

Codex pastes its completion summary into this thread and submits it, so it arrives as an ordinary user turn beginning with `[ccx-harness] Completion landed for <feature-slug>`. Treat that as the user prompting you with that content. Respond appropriately:

- If status is **DONE** and the additionalContext includes the auto-verify trigger: follow the verify protocol (see `${CLAUDE_PLUGIN_ROOT}/skills/verify/SKILL.md`). Dispatch the three parallel reviewers; auto-merge if all three agree, otherwise spawn the adjudicator to fact-check the dissent. The user has already opted into auto-merge on a clean verification; do not ask for confirmation.
- If status is **DONE** but no `pr_url` is present: paraphrase the blocker (Codex finished but didn't open a PR — likely a setup or `gh` auth issue), and ask the user to investigate.
- If status is **BLOCKED**: paraphrase the blocker, recommend whether the user should fix manually or re-dispatch with a revised spec, and offer to revise the spec via `/ccx-harness:plan` if relevant.

## Notes for Claude

- The session_id embedded in the payload is informational (so the completion file records which session dispatched it). Codex pastes the completion back into whichever Claude thread is showing this orchestration conversation, located visually from its screenshot.
- Never re-dispatch a spec without explicit user confirmation. Codex's current thread continues across dispatches, so a duplicate dispatch will confuse it.
- Both directions are vision-based: you find the Codex input by looking at the screenshot, and Codex finds your input the same way. Neither relies on coordinates staying fixed. Always verify via the post-action screenshot (spinner on dispatch; submitted turn on completion).
- This skill is intentionally short. The smarts live in (a) the spec the user co-authored with `/ccx-harness:plan`, and (b) the completion protocol Codex follows.
