---
name: verify
description: Independent PR verification after Codex finishes. Dispatches two parallel Opus 4.7 1M reviewer agents that grade the PR against the original spec. Auto-merges via `gh pr merge --squash --delete-branch` when both reviewers return MERGE. Surfaces concerns and offers a revision dispatch otherwise. Auto-triggered when Codex pastes a completion with status DONE and a pr_url into the thread; can also be invoked manually.
argument-hint: <feature-slug>
user-invocable: true
allowed-tools: Bash Read Write Edit Grep Agent AskUserQuestion
---

# ccx-harness :: verify

You verify Codex's PR against the original spec using two independent reviewer agents, then auto-merge if both say MERGE.

## Step 0: parse arguments and find inputs

The user, or the auto-verify trigger embedded in a pasted completion, invokes you with `/ccx-harness:verify <feature-slug>`.

- If no slug given, read `.ccx-harness/inbox/_signal`. If it contains `latest=<file>.md`, derive the slug from `<file>`. Otherwise list `ls .ccx-harness/inbox/*.md` and ask.

Then read three files in parallel:

1. `specs/<feature-slug>.md` — the original spec.
2. `.ccx-harness/inbox/<feature-slug>.md` — Codex's completion summary.
3. Extract `pr_url` from the completion file's YAML frontmatter. If `pr_url` is `none` or missing, stop and tell the user the PR was never opened — verification is meaningless without a diff to grade.

## Step 1: fetch PR data

Run these in parallel via `gh`:

```bash
gh pr view <pr_url> --json number,title,body,baseRefName,headRefName,additions,deletions,changedFiles,mergeable,statusCheckRollup,reviewDecision,commits
gh pr diff <pr_url>
```

Save the JSON output and the diff to working memory. If `gh` fails (auth, missing repo, etc.), surface the error and stop.

Sanity checks:
- `mergeable` should be `MERGEABLE` (not `CONFLICTING`). If conflicting, stop and tell the user.
- `statusCheckRollup` should be all `SUCCESS` or empty. If any check is `FAILURE` or `PENDING`, surface and ask whether to proceed anyway.

## Step 2: dispatch two parallel reviewers

In a single message, fire two `Agent` tool calls with the same prompt but no shared state.

Use:
- `subagent_type: "general-purpose"`
- `model: "opus"` (required by user's memory; do not omit)
- Same `description` for both: "Independent PR review for <feature-slug>"

The prompt for both agents:

```
You are reviewing a pull request as an independent verifier. Another reviewer
agent is being run in parallel with the exact same prompt and inputs. You will
not see each other's work. We compare verdicts at the end and only merge if you
both agree.

Your job: grade this PR against the original spec. Decide whether to merge.
Be skeptical. The author (an LLM coding agent named Codex) has already claimed
the tests pass; your job is to independently verify that the implementation
actually satisfies the spec and that the tests are meaningful, not just green.

================================================================
ORIGINAL SPEC
================================================================

<paste full contents of specs/<feature-slug>.md>

================================================================
CODEX COMPLETION CLAIM
================================================================

<paste full contents of .ccx-harness/inbox/<feature-slug>.md>

================================================================
PR METADATA
================================================================

<paste gh pr view JSON output>

================================================================
PR DIFF
================================================================

<paste gh pr diff output>

================================================================
REVIEW RUBRIC
================================================================

Grade each dimension independently:

1. SPEC ADHERENCE — for each acceptance criterion in the spec, did the PR
   actually implement it? Look at the code, not Codex's claim. Mark each
   criterion SATISFIED, PARTIAL, or NOT SATISFIED with a one-line reason.

2. TEST QUALITY — for each test layer (unit, integration, e2e), are the
   tests meaningful, or are they tautological / mocked beyond recognition /
   missing the actual edge cases the spec called out? Mark ADEQUATE or
   INADEQUATE with reasoning.

3. COVERAGE CLAIM — Codex claims a coverage percentage. Is it plausible
   given the diff? Skim the new code for obviously-untested branches.

4. CODE QUALITY — anti-patterns, subtle bugs, security issues, anything
   that an experienced reviewer would flag. Don't nitpick style; flag
   substantive concerns only.

5. SCOPE CREEP — does the PR touch things outside the spec's scope?
   If so, are those changes load-bearing for the feature, or accidental?

================================================================
OUTPUT FORMAT (strict; we parse this)
================================================================

Respond with exactly this structure, nothing else:

VERDICT: <MERGE | REVISE | REJECT>
CONFIDENCE: <high | medium | low>

SPEC_ADHERENCE:
- <criterion 1 verbatim>: <SATISFIED | PARTIAL | NOT_SATISFIED> — <one-line reason>
- <criterion 2 verbatim>: <SATISFIED | PARTIAL | NOT_SATISFIED> — <one-line reason>
- ...

TEST_QUALITY:
- Unit: <ADEQUATE | INADEQUATE> — <one-line reason>
- Integration: <ADEQUATE | INADEQUATE> — <one-line reason>
- E2E: <ADEQUATE | INADEQUATE> — <one-line reason>

COVERAGE_PLAUSIBLE: <yes | no> — <one-line reason>

CONCERNS:
- <substantive concern 1, or "none">
- <substantive concern 2>
- ...

ONE_LINE_RECOMMENDATION: <single sentence>

Definitions:
- MERGE: implementation satisfies the spec, tests are meaningful, ship it.
- REVISE: fixable problems — list them in CONCERNS so Codex can address.
- REJECT: fundamental issues (wrong approach, broken safety, missing the goal).

Do not hedge. If you would not personally approve this PR for merge,
your verdict is not MERGE.
```

## Step 3: parse verdicts

Each reviewer returns a structured response. Extract:
- `VERDICT` (MERGE | REVISE | REJECT)
- `CONCERNS` lines
- `ONE_LINE_RECOMMENDATION`

If either response is malformed (doesn't include `VERDICT:`), treat that reviewer as REJECT with a concern noting the malformed output, and proceed.

## Step 4: convergence decision

Apply this logic:

- **Both `VERDICT: MERGE`** → go to Step 5 (auto-merge).
- **Both `VERDICT: REJECT`** → go to Step 6a (revision dispatch).
- **Both `VERDICT: REVISE`** → go to Step 6a (revision dispatch).
- **One MERGE, one REVISE** → go to Step 6b (escalate to user with both verdicts).
- **One MERGE, one REJECT** → go to Step 6b. Major disagreement; user decides.
- **One REVISE, one REJECT** → go to Step 6a (revision dispatch, with stricter framing).

## Step 5: auto-merge

The user has opted into auto-merge on convergence; do NOT ask for confirmation.

1. Print a tight summary to chat:

   ```
   ✅ Both reviewers: MERGE.

   Reviewer A: <one-line recommendation>
   Reviewer B: <one-line recommendation>

   Merging PR <pr_number> via squash + delete branch...
   ```

2. Merge with squash AND branch deletion. `--delete-branch` is non-negotiable: no branch outlives its PR. Run:
   `gh pr merge <pr_url> --squash --delete-branch`
   If it fails due to branch protection, retry once with `--admin` appended. After the merge returns success, confirm the branch is gone with `git ls-remote --exit-code --heads origin codex/<feature-slug>` (a 0 exit means it still exists; if so, delete it explicitly: `gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/codex/<feature-slug>` or `git push origin --delete codex/<feature-slug>`).

3. Append a final entry to the spec's Operator Log:
   `[<ISO timestamp>] MERGED — PR <pr_number>, both reviewers MERGE, auto-merged via ccx-harness:verify`

4. Append to `.ccx-harness/inbox/<feature-slug>.md`:
   ```

   ## Verification result
   - Reviewer A: MERGE — <recommendation>
   - Reviewer B: MERGE — <recommendation>
   - Action: auto-merged at <ISO timestamp>
   ```

5. Tell the user:
   > Merged. Branch deleted. `<feature-slug>` is shipped. If you want to run anything next, just say so.

## Step 6a: revision needed (both reviewers want changes)

1. Synthesize the two reviewers' concerns into a deduplicated bulleted list.
2. Tell the user:

   ```
   ⚠️  Reviewers say NOT MERGE.

   Reviewer A verdict: <verdict> — <recommendation>
   Reviewer B verdict: <verdict> — <recommendation>

   Combined concerns (deduped):
   - <concern 1>
   - <concern 2>
   ...

   Want me to dispatch a revision to Codex? I'd send the original spec plus
   these concerns as a "revise PR #N to address ..." prompt. The branch and
   PR stay open.
   ```

3. Use `AskUserQuestion`:
   - Question: "Dispatch the revision to Codex?"
   - Options: "Yes, dispatch revision", "No, I'll handle manually"

4. If yes: compose the revision prompt (spec + concerns + "amend the existing PR codex/<feature-slug>; do not open a new one"), paste into Codex via the same computer-use flow as `/ccx-harness:send`, log to operator log. Codex's next completion will re-trigger verify.

5. If no: leave the PR open; the user can `gh pr view` and steer Codex directly.

## Step 6b: disagreement, escalate

1. Show both verdicts side by side with concerns. No auto action.

2. Use `AskUserQuestion`:
   - Question: "Reviewers disagreed. Decision?"
   - Options: "Merge anyway", "Dispatch revision with both concerns", "Hold and let me look at the PR"

3. Act on the choice. If "Merge anyway", do Step 5 (record that user overrode disagreement in the operator log). If "Dispatch revision", do Step 6a step 4. If "Hold", stop.

## Notes for Claude

- Always run both agents IN PARALLEL in one message. Two separate sequential calls double the latency.
- Don't pad the reviewer prompts with anything beyond the rubric. Each reviewer should see exactly the same inputs.
- Reviewers cannot run code or hit the network for context; they grade on the diff and the spec only. That's intentional — they're a sanity check against Codex's self-report.
- If `gh pr merge` fails (branch protection, status checks not green, conflicts), do NOT retry blindly. Surface the failure to the user with the exact error, and ask whether to override or revise.
- The auto-merge policy was set by the user via setup. If you suspect the PR is unsafe to merge even with two MERGE verdicts (e.g. PR touches secrets, deletes production config, etc.), escalate via Step 6b instead. Use judgment.

## Branch hygiene (no branch outlives its PR)

The harness invariant is that no branch outlives its PR, so main stays the single source of truth and drift is impossible.

- **Merged** (Step 5): `--delete-branch` removes the branch automatically. Confirm it's gone.
- **Revising** (Step 6a, user chose to dispatch a revision): the branch and PR stay open intentionally because Codex amends the same PR. This is fine; the branch still has a live PR.
- **Abandoned** (a PR the user decides NOT to merge and NOT to revise, e.g. a REJECT verdict the user accepts): close the PR AND delete its branch so it doesn't linger. Run `gh pr close <pr_url> --delete-branch`. Confirm with the user first if it isn't obvious they want it gone.

Operational tasks (deploys, test re-runs, staging redeploys) don't produce PRs at all. They run against current `main` directly and never create a branch, so there's nothing to clean up. Only feature/spec work goes through the branch + PR + delete lifecycle.
