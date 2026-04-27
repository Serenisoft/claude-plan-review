---
description: Iterative plan review where Codex (gpt-5.5 high) acts as an adversarial reviewer with read-only access to the project files. Converges on "PLAN OK" or stops at max 3 iterations.
argument-hint: [optional feature description or focus instruction]
allowed-tools: Bash(mktemp:*), Bash(chmod:*), Bash(pwd:*), Bash(plan-review-step:*), Bash(rm:*), Bash(cat:*), Bash(ls:*), Bash(echo:*), Read, Write, Grep, Glob
---

You will draft a thorough plan and iterate on it with Codex acting as an
adversarial reviewer until Codex returns "PLAN OK" or you reach the
iteration cap (3 by default; honors `CLAUDE_PLAN_REVIEW_MAX_ITER`).

## Decide how to source plan-v1 (Step 2b)

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
Capture the project root and create an isolated workdir with safe perms:
```bash
PROJECT_ROOT="$(pwd)"
WORKDIR=$(mktemp -d -t plan-review-XXXXXXXX)
chmod 700 "$WORKDIR"
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "WORKDIR=$WORKDIR"
```
Save both — you'll need them for every `plan-review-step` call.

## Step 2a — Gather project context
Before drafting plan-v1, build a *focused* project-context summary so
Codex's review is calibrated to this codebase's conventions. Use Read,
Grep, and Glob to find:

- `CLAUDE.md` at project root and any nested `CLAUDE.md`
- `.claude/skills/*/SKILL.md` indexes — pull names + first-paragraph
  descriptions
- ADRs under `docs/adr/`, `docs/adrs/`, `architecture/decisions/`,
  `apps/*/docs/decisions/`, or similar — extract titles and one-line
  summaries; flag any ADR plausibly relevant to the feature being
  planned
- `README.md` architecture section if present

Synthesize a **focused** summary scoped to the feature being planned —
NOT a kitchen-sink dump. Target 200–600 words. Format:

- Project facts: stack, deployment model, key constraints
- Conventions relevant to this feature (naming, error handling, patterns)
- Related skills by name with one-line "use when" reminder
- Related ADRs by number with one-line summary
- Existing similar features Codex should compare against

Write to `$WORKDIR/project-context.md`. If the project has no
CLAUDE.md, no skills, and no ADRs, write a brief "minimal project
context" note (language, runtime, anything obvious from the code) — do
not skip the file. Codex still benefits from a baseline.

## Step 2b — Plan v1
Following the routing decision above, draft a thorough numbered plan:
- Cover edge cases, failure modes, security, observability
- Library-first where it makes sense
- No code — only the plan
- Where project conventions matter for the plan, fold them in directly
  (don't just defer to the project-context.md file). The plan should
  *read* like it was written by someone who knows the codebase.

Write the plan to `$WORKDIR/plan-v1.md`.

## Step 3 — Iter 1 (fresh Codex session)
```bash
plan-review-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md" "$PROJECT_ROOT"
```
Inspect the exit code:
- `0` → "PLAN OK" found, jump to Step 5 (wrap-up)
- `1` → findings recorded in `$WORKDIR/iter-1.txt`, continue to Step 4
- `2` or `3` → error, report to the user and stop

## Step 4 — Iters 2..N (resume)
Repeat until "PLAN OK" or iter=MAX_ITER (3 by default):

### 4.1 Evaluate each finding against this checklist
For HVER finding in `$WORKDIR/iter-N-1.txt`, write down your answer
explicitly **before** revising the plan. Do not just absorb findings
silently — Codex' reviewer role tends toward overengineering, so you
must filter actively.

For each finding, answer:

- **Relevant?** Is this finding actually about the feature being
  planned, or is it adjacent / out of scope?
- **Real or hypothetical?** Does this fail under realistic operating
  conditions (the project's actual threat model and reliability bar),
  or only under contrived edge cases?
- **Tradeoff?** Is the current design a deliberate choice — fits an
  existing project pattern (verify with `Grep`/`Read` against the
  project), accepted by the threat model, chosen simplicity-over-
  completeness? If yes, the finding is a *non-issue Codex didn't have
  context for* — keep the design and document why.
- **Overengineered fix?** If the suggested fix adds significant
  complexity (new dependencies, new abstractions, more code paths)
  for a marginal risk reduction, prefer the simpler design. State
  that explicitly.
- **Verify with project files.** Codex now has read-only access to
  the project (via `-C $PROJECT_ROOT`). If a finding contradicts an
  existing pattern in the codebase, point that out — Codex should
  have seen it but may have missed it.

### 4.2 Write the decisions into plan-vN itself
At the **top** of the new `plan-vN.md`, before the plan content,
include a section:

```markdown
## Findings considered in iteration N-1

1. **Finding:** <one-line paraphrase>
   **Decision:** Addressed | Rejected — overengineering | Rejected — out of scope | Rejected — deliberate tradeoff | Rejected — false positive
   **Rationale:** <1–3 sentences>

2. ...
```

This block stays in plan-vN+1, plan-vN+2, etc. (each round appends a
new "Findings considered in iteration X" section above the previous
ones, so the audit trail accumulates). Codex sees these decisions on
resume and either accepts the rationale or pushes back with sharper
evidence next round.

### 4.3 Apply the addressed-finding revisions
Update the rest of the plan to reflect the findings you decided to
address. Keep the plan a coherent whole, not a diff.

### 4.4 Run the next iteration
Write the updated plan to `$WORKDIR/plan-vN.md` (full new version) and
call:
```bash
plan-review-step "$WORKDIR" $N "$WORKDIR/plan-vN.md" "$PROJECT_ROOT"
```
Inspect the exit code as in Step 3.

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
- A brief note: which findings repeated vs. which new ones appeared,
  and how many were `Rejected — overengineering` (a healthy signal)

Say: "Did not converge after MAX_ITER iterations. Remaining blockers
from the last iter-N.txt are listed above. Decide manually whether the
design is sound or whether it needs reworking."

# Rules

- **Do not implement the plan** — this command is for plan review only.
- **Lean toward the simpler plan.** Convergence at iter 3 with a couple
  of `Rejected — overengineering` findings is a healthy outcome — don't
  iterate just to please the reviewer.
- **Do not delete or modify files in the workdir between iterations** —
  the audit trail requires that older `plan-vN.md` files are preserved,
  and Codex's resumed state depends on the full iteration history being
  intact.
- **The workdir is not auto-cleaned** — the user must remove it manually
  after reviewing (`rm -rf "$WORKDIR"`). This is intentional: hard plans
  benefit from an audit trail.
- **Do not run other Codex sessions in parallel** while this loop is
  active — it can interfere with Codex's session state.
- **For false positives, document `why`** in the per-finding decision
  log (Step 4.2). Codex sees the rationale on resume and may accept it.
