---
description: Iterative plan review where Codex (gpt-5.5 high) acts as an adversarial reviewer. Converges on "PLAN OK" or stops at max 5 iterations.
argument-hint: <feature/change to plan>
allowed-tools: Bash(*), Read, Write, Edit
---

You will draft a thorough plan for `$ARGUMENTS`, then iterate on it with
Codex acting as an adversarial reviewer until Codex returns "PLAN OK" or
you reach 5 iterations.

# Flow

## Step 1 — Setup
Create an isolated workdir with safe permissions:
```bash
WORKDIR=$(mktemp -d -t plan-loop-XXXXXXXX)
chmod 700 "$WORKDIR"
echo "$WORKDIR"
```
Save the `WORKDIR` path — you'll need it for every subsequent call.

## Step 2 — Plan v1
Draft a thorough numbered plan for `$ARGUMENTS`:
- Cover edge cases, failure modes, security, observability
- Library-first where it makes sense
- No code — only the plan

Write the plan to `$WORKDIR/plan-v1.md`.

## Step 3 — Iter 1 (fresh Codex session)
```bash
plan-loop-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md"
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
   plan-loop-step "$WORKDIR" $N "$WORKDIR/plan-vN.md"
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
