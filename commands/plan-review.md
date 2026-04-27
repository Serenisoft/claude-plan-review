---
description: Iterative plan review where Codex (gpt-5.5 high) acts as an adversarial reviewer. Converges on "PLAN OK" or stops at max 5 iterations.
argument-hint: [optional feature description or focus instruction]
allowed-tools: Bash(mktemp:*), Bash(chmod:*), Bash(plan-review-step:*), Bash(rm:*), Bash(cat:*), Bash(ls:*), Bash(echo:*), Read, Write
---

You will draft a thorough plan and iterate on it with Codex acting as an
adversarial reviewer until Codex returns "PLAN OK" or you reach 5 iterations.

## Decide how to source plan-v1 (Step 2)

The user can invoke this command in three ways. Detect which one and act
accordingly:

1. **`$ARGUMENTS` is empty, and there is meaningful prior conversation
   about a plan/feature/change.** Use the conversation as the basis for
   plan-v1. Synthesize what was discussed into a coherent numbered plan.
2. **`$ARGUMENTS` looks like a focus instruction** (phrases like "focus on…",
   "scrutinize…", "especially…"), and there is meaningful prior conversation.
   Use the conversation as the basis for plan-v1, but weight `$ARGUMENTS`
   heavily as a focus area both in your plan and in how you respond to
   findings.
3. **`$ARGUMENTS` looks like a feature description** (e.g. "add expiry
   dates to short URLs"), with or without prior conversation. Treat it
   as the feature to plan, drafting plan-v1 from scratch based on the
   description. If there is also prior conversation, fold its constraints
   in as context but let `$ARGUMENTS` define scope.

If `$ARGUMENTS` is empty AND there is no prior conversation about a plan,
ask the user what they want planned before doing anything else.

# Flow

## Step 1 — Setup
Create an isolated workdir with safe permissions:
```bash
WORKDIR=$(mktemp -d -t plan-review-XXXXXXXX)
chmod 700 "$WORKDIR"
echo "$WORKDIR"
```
Save the `WORKDIR` path — you'll need it for every subsequent call.

## Step 2 — Plan v1
Following the routing decision above, draft a thorough numbered plan:
- Cover edge cases, failure modes, security, observability
- Library-first where it makes sense
- No code — only the plan

Write the plan to `$WORKDIR/plan-v1.md`.

## Step 3 — Iter 1 (fresh Codex session)
```bash
plan-review-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md"
```
Inspect the exit code:
- `0` → "PLAN OK" found, jump to Step 5 (wrap-up)
- `1` → findings recorded in `$WORKDIR/iter-1.txt`, continue to Step 4
- `2` or `3` → error, report to the user and stop

## Step 4 — Iters 2..5 (resume)
Repeat until "PLAN OK" or iter=5:

1. Read `$WORKDIR/iter-N-1.txt` (the previous round's findings).
2. Update the plan based on the findings:
   - For each finding: judge whether it is valid
   - If valid: revise the plan to address it
   - If a false positive: write *why* you're keeping the current design.
     Codex will see this in the resumed thread.
3. Write `$WORKDIR/plan-vN.md` (full new version, not a diff).
4. Run:
   ```bash
   plan-review-step "$WORKDIR" $N "$WORKDIR/plan-vN.md"
   ```
5. Inspect the exit code as in Step 3.

## Step 5 — Wrap-up

### If "PLAN OK"
Show the user:
- The iteration number that converged
- The final plan (`$WORKDIR/plan-v<final>.md`)
- The workdir path (so the user can inspect any iteration)

Say: "Plan approved by Codex on iteration N. Ready for implementation."

### If max iterations without convergence
Show the user:
- The last plan and the last findings
- The workdir path
- A brief note: which findings repeated vs. which new ones appeared

Say: "Did not converge after 5 iterations. Remaining blockers from iter-5.txt
listed above. Decide manually whether the design choice is a deliberate
tradeoff or whether the underlying plan needs reworking."

# Rules

- **Do not implement the plan** — this command is for plan review only.
- **Do not delete or modify files in the workdir between iterations** — the
  audit trail requires that older `plan-vN.md` files are preserved, and
  Codex's resumed state depends on the full iteration history being intact.
- **The workdir is not auto-cleaned** — the user must remove it manually
  after reviewing (`rm -rf "$WORKDIR"`). This is intentional: hard plans
  benefit from an audit trail.
- **Do not run other Codex sessions in parallel** while this loop is active —
  it can interfere with Codex's session state.
- **If you find a false positive from Codex**, do not just ignore it. Write
  in the updated plan *why* you're keeping the choice. Codex sees this in
  the resumed thread and may accept the rationale.
