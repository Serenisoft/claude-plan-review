# claude-plan-review

**Iteratively pressure-test Claude Code plans with Codex as the adversarial reviewer — until both models agree the plan is ready.**

The official OpenAI [`codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
reviews git diffs only. Plans that live in chat — which is how plans
actually get drafted during interactive sessions with Claude — cannot
be adversarially reviewed by the plugin at all. And even if you write
the plan to a file, each plugin call starts a fresh thread, so the
reviewer keeps rediscovering the same concerns and never confirms
they're actually fixed.

`claude-plan-review` closes both gaps by piping the plan directly into
`codex exec` over a resumed session, so the reviewer keeps full context
between rounds and `PLAN OK` becomes a meaningful convergence signal.

```
/plan-review add expiry dates to short URLs

  iter 1  → Codex finds 4 blockers
  iter 2  → Claude revises plan, Codex sees the changes (resumed thread),
            confirms 3 are fixed, surfaces 2 new ones from the new design
  iter 3  → Claude revises again
  iter 4  → Codex: PLAN OK
```

> **Note:** Personal Serenisoft tool. No support guarantees, response time may
> be days or weeks. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

## Why this exists

### The fundamental gap: Codex plugin only reviews files, not plans in chat

The official [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin's `/codex:review` and `/codex:adversarial-review` commands operate
on **git diffs**. They have no input mode for "the plan Claude just
sketched in this conversation" — your only options with the plugin alone are:

- Write the plan to a markdown file in the repo first, then run the
  plugin (cumbersome, especially for throwaway planning sessions)
- Misuse `/codex:rescue` (which is designed for delegating implementation,
  not review)
- Build something else

`claude-plan-review` is the third option. It calls `codex exec` directly
with the plan piped via stdin, so plans that live entirely in chat — never
as a file — can be adversarially reviewed without round-tripping through
git.

### Bonus: context-preserving resume between iterations

Beyond the file-vs-chat gap, the plugin also starts a fresh Codex thread
on every invocation. That works fine for one-shot code review, but breaks
down when you want to *iterate* on a plan:

- Each fresh round produces a different finding set on the same unchanged
  plan (we tested this — three runs gave three different lists)
- `PLAN OK` is never reached because the reviewer cannot see whether
  earlier concerns were addressed
- Token cost grows linearly with iterations (no delta optimization)

claude-plan-review captures Codex's session id from iter 1 and uses
`codex exec resume <id>` for iters 2..N, so the reviewer keeps full
context and can give a meaningful "no remaining or new blockers" verdict.

### Bonus: project-aware review (v0.4+)

Codex sees the project. The slash command captures `$(pwd)` and passes
it to `codex exec -C <root> --sandbox read-only`, so the reviewer can
read existing code, ADRs, and conventions while reviewing your plan.
Findings calibrate to *your* codebase — not generic best-practices.
Combined with a `<project_context>` block (CLAUDE.md / skills / ADRs
summarized by Claude into the prompt), this fixes the failure mode
where Codex flags issues that contradict patterns already established
in your project.

## Prerequisites

| Tool | Why | How to install |
|------|-----|----------------|
| [Codex CLI](https://github.com/openai/codex) v0.118+ | Runs the review (`codex exec resume` requires this version) | `npm install -g @openai/codex` (needs Node 18.18+) |
| ChatGPT account | Codex auth | Run `codex login` after install (opens browser); or set `OPENAI_API_KEY` |
| [Claude Code](https://claude.com/claude-code) 2.x | Hosts the `/plan-review` slash command | Follow the [official install guide](https://docs.anthropic.com/en/docs/claude-code) |
| `bash` 4+, `awk`, `grep`, `mktemp` | Standard on Linux/macOS | (already installed) |

### Recommended (not required)

The [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin gives you `/codex:review`, `/codex:rescue`, and other commands that
complement plan-review nicely. They are independent — plan-review does not
depend on the plugin — but most users want both.

## Install

```bash
git clone https://github.com/Serenisoft/claude-plan-review.git
cd claude-plan-review
bash install.sh
```

The installer symlinks two files and verifies prerequisites:

| Source | Destination |
|--------|-------------|
| `commands/plan-review.md` | `~/.claude/commands/plan-review.md` |
| `scripts/plan-review-step.sh` | `~/.local/bin/plan-review-step` |

Make sure `~/.local/bin` is in your `$PATH` (Ubuntu does this by default
when the directory exists at login; reopen your shell if it didn't).

Then **restart Claude Code** (slash commands are registered at startup,
not on file change) and try:

```
/plan-review add a "copy link" button to the link detail page
```

### Three ways to invoke

The `/plan-review` command works in three modes. Pick the one that fits
your situation.

#### A — Discuss first, then review (most common in practice)
You and Claude have already been talking about a feature. Claude has a
plan in mind from the conversation. You want it reviewed.
```
[20 min of conversation about the feature, edge cases, options...]
[Claude proposes a plan]
/plan-review
```
Claude uses the conversation as the basis for plan-v1. `$ARGUMENTS` is
empty.

#### B — Jump straight to planning (fastest)
You know what you want. No back-and-forth needed first.
```
/plan-review add expiry dates to short URLs
```
Claude drafts plan-v1 from scratch based on the feature description.

#### C — Discuss, then focus the review (hybrid)
You've talked it through, but you know exactly where you want Codex to
push hardest.
```
[conversation about the feature]
/plan-review especially scrutinize the rollout strategy and security
```
Claude uses the conversation as the basis for plan-v1, with `$ARGUMENTS`
as a weighted focus area for both the plan and the review.

### Reviewing a pre-existing plan file

If your plan is already written somewhere, skip the slash command and
run `plan-review-step` directly:

```bash
WORKDIR=$(mktemp -d -t plan-review-XXXXXXXX)
chmod 700 "$WORKDIR"
cp my-existing-plan.md "$WORKDIR/plan-v1.md"

# Optional but recommended: give Codex read-only access to your project
plan-review-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md" "$(pwd)"

# Or without project access:
# plan-review-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md"

# then iterate manually with plan-v2.md, plan-v3.md, etc.
```

**Optional:** to give Codex project context too, write a focused
summary to `$WORKDIR/project-context.md` before iter 1. The script
splices it into a `<project_context>` block automatically.

## Recommended Codex configuration

```toml
# ~/.codex/config.toml
model = "gpt-5.5"
model_reasoning_effort = "high"
```

- **`gpt-5.5` with `high` effort** is the sweet spot for adversarial plan
  review — `xhigh` is overkill for plan-sized inputs (roughly 2–4× more
  reasoning tokens for diminishing returns), and `medium` misses subtler
  edge cases.
- **Sandbox and approval settings:** v0.4+ runs Codex with
  `--sandbox read-only` per call, regardless of your config. You don't
  need to lower your default sandbox for plan-review specifically.

## Security

### Who this tool is built for

claude-plan-review is built for the **single-user, trusted-input** case:
you on your own machine, planning your own features, with plan text
synthesized from your own conversation with Claude. Under that model,
the protections in v0.2.x are roughly the right level — strict enough
to handle the obvious failure modes, loose enough to stay fast and
ergonomic.

If your situation is different (multi-user system, CI that runs this
on inputs from issues/PRs, plans synthesized from web-fetched content
or third-party documents), read **Known limitations** below before
relying on it.

### Threat model (single-user mode — the supported case)

The plan text passed into Codex is treated as untrusted within the
review prompt: the reviewer is told to ignore instructions found inside
the `<plan>` block. The main risks the tool actively defends against
are:

1. **Accidental verdict spoofing** — a plan or Codex's own reasoning
   trace echoing the verdict format and tricking the parser into a
   false `PLAN OK`.
2. **Workdir mishaps** — the script writing into the wrong directory
   if a path is misconfigured.

### Mitigations

- The reviewer prompt explicitly marks `<plan>` content as untrusted
  and forbids following instructions found there.
- The verdict is signaled via a per-run random token embedded in the
  reviewer prompt. The parser requires the verdict line to be the
  **last non-empty line** of Codex output and to match the exact token
  — a plan author cannot forge a verdict that gets accepted.
- The slash command's `allowed-tools` is scoped to a small set of
  filesystem and runner commands — not `Bash(*)`.
- `plan-review-step.sh` validates the workdir's owner and exact mode
  (700) before writing, refuses symlink targets, and uses noclobber
  redirection throughout.
- **v0.4+:** every Codex invocation forces `--sandbox read-only`,
  defense-in-depth against prompt-injection-induced tool use even if
  the user's `~/.codex/config.toml` is configured loosely.
- **v0.4+:** when a project root is provided, it must be owned by the
  current user (validated via `stat`) — preventing accidental
  pointers at another user's project.

### Known limitations (cases the tool does NOT fully defend)

The current design assumes you're on a single-user machine with no
hostile local actor. If those assumptions don't hold, these are
unaddressed:

| Concern | Realistic when |
|---------|----------------|
| Token can be observed in `iter-N.txt` after each round and forged in the next iteration's plan | A genuinely adversarial plan author iterating against you over a series of rounds — unlikely in personal use, real in CI/multi-user contexts |
| Slash-command `allowed-tools` includes `Read`, `Write`, `rm`, `chmod`, `cat`, `echo`, `ls` | Prompt injection from a third-party document or webpage that Claude pulled into the conversation could ask Claude (not Codex) to misuse these |
| Installer's symlink-into-repo check is lexical, not canonical | Attacker has placed a symlink in the repo path before you ran `install.sh` — requires prior write access to your filesystem |
| WORKDIR path validated, but writes go through the original (non-canonicalized) string | A symlink-parent race during script execution — requires concurrent write access to your `/tmp` |

If you operate in a context where any of these are realistic, please
either skip claude-plan-review or open an issue describing your use
case so the project can decide whether v0.3+ should harden further.

### Sandbox guidance

> Note: as of v0.4 the slash command and `plan-review-step` always pass
> `--sandbox read-only` per call, so most of this section applies to
> *other* Codex use on your machine, not to plan-review specifically.

The Codex CLI runs in a bubblewrap-based sandbox by default
(`approval_policy = "on-request"`, `sandbox_mode = "workspace-write"` or
similar — see [Codex docs](https://developers.openai.com/codex/agent-approvals-security)).
**Keep these defaults if you can.** They prevent Codex from running
shell commands or modifying files outside the workspace without your
explicit approval — even if a malicious plan tries to issue tool calls.

If your kernel's user-namespace restrictions block bubblewrap (you'll
see `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`),
you have two options:

1. **Recommended:** install `bubblewrap` and enable unprivileged user
   namespaces:
   ```bash
   sudo apt install bubblewrap
   sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
   ```
2. **Only if you accept the risk:** disable the sandbox in
   `~/.codex/config.toml`:
   ```toml
   sandbox_mode = "danger-full-access"
   approval_policy = "never"
   ```
   This makes Codex run with full access to your filesystem and
   network as the invoking user. Combined with the prompt-injection
   surface above, a malicious plan could in principle achieve code
   execution. The token-based verdict and `allowed-tools` scoping
   reduce — but do not eliminate — the risk. Use this only on personal
   development boxes where you fully control the plan input.

## How it works

1. **Step 1** — Slash command captures `$(pwd)` as `PROJECT_ROOT` and
   creates a workdir with `mktemp -d -t plan-review-XXXXXXXX` (mode 700,
   not world-readable).
2. **Step 2a** — Claude reads `CLAUDE.md`, `.claude/skills/*/SKILL.md`,
   ADRs, and the README architecture section, then writes a focused
   project-context summary (200–600 words, scoped to the feature) to
   `$WORKDIR/project-context.md`.
3. **Step 2b** — Claude drafts `plan-v1.md` in the workdir, folding
   project conventions directly into the plan where relevant.
4. **Step 3 (iter 1)** — `plan-review-step` invokes
   `codex exec --sandbox read-only --skip-git-repo-check -C $PROJECT_ROOT`
   with the adversarial prompt + `<project_context>` block + plan via
   stdin. Output is captured to `iter-1.txt`, the Codex session id is
   grepped from the output and stored in `.session-id`. Verdict
   (`PLAN_OK` or `FINDINGS`) is written to `verdict-1.txt`.
5. **Step 4 (iters 2..N)** — Claude reads `iter-N-1.txt`, evaluates each
   finding against an explicit checklist (relevant? real or hypothetical?
   tradeoff? overengineered? verifiable against project files?), records
   per-finding decisions in a `## Findings considered in iteration N-1`
   section at the top of `plan-vN.md`, and runs `plan-review-step` again.
   The script calls `codex exec resume <session-id>` (with the same
   sandbox/cd flags) so Codex keeps full context across rounds and sees
   the decision rationale on resume.
6. **Step 5** — Loop ends on `PLAN OK` (last non-empty line, exact match
   against the per-run verdict token) or when iter MAX_ITER finishes
   with findings. The workdir is preserved as an audit trail; you
   remove it manually with `rm -rf "$WORKDIR"`.

### Why resume between iterations

Empirical: three fresh runs of `codex exec` against the same unchanged
plan produced three different finding sets. Without context, the reviewer
cannot distinguish "this finding is new" from "this finding is the one I
already raised, just phrased differently." Resume fixes both:

- Codex confirms whether earlier concerns were addressed (rather than
  re-discovering them)
- New findings are genuinely new, not re-rolls of old ones
- `PLAN OK` becomes a meaningful signal (the reviewer is saying "no
  remaining or new blockers"), not just "this round happened to find
  nothing"

This matches the approach taken in
[binaryroute's multi-model review gist](https://gist.github.com/binaryroute/aba0350689ef90396478946662763766)
and [Aseem Shrey's experience report](https://aseemshrey.in/blog/claude-codex-iterative-plan-review/),
which both use resume and report convergence in 2–3 rounds typical.

### Why exact session id (not `--last`)

`codex exec resume --last` is not concurrency-safe. If you start another
Codex session in any shell while the loop is running, `--last` may resolve
to the wrong thread and silently corrupt the review. We capture the
explicit UUID from iter 1's output (`session id: <uuid>`) and pass it
verbatim on every resume.

### Why max 3 iterations (default)

Reported convergence in the wild is 2–3 rounds typical
([Aseem Shrey: 8 → 6 → 0](https://aseemshrey.in/blog/claude-codex-iterative-plan-review/)).
Our own first real loop hit 5 iterations without convergence, but
inspection showed the loop had escalated from real design issues into
mikro-bugs after iter 3 — the reviewer can't say "I'm done" so it keeps
finding *something*, often something not worth fixing.

v0.4 makes 3 the default. If your plan is unusually thorny and 3
isn't enough, raise it via:

```bash
CLAUDE_PLAN_REVIEW_MAX_ITER=5 claude
```

Inside the slash command, the script tells Codex when it's the final
round so the reviewer focuses on blockers rather than polish.

## Files in this repo

```
claude-plan-review/
├── README.md                  ← you are here
├── LICENSE                    ← MIT
├── CHANGELOG.md
├── CONTRIBUTING.md
├── install.sh                 ← symlinks and verifies prerequisites
├── commands/
│   └── plan-review.md           ← Claude Code slash command
├── prompts/
│   └── adversarial-prompt.md  ← review prompt template (English)
└── scripts/
    └── plan-review-step.sh      ← one iteration per call
```

## Troubleshooting

### "codex CLI not found in PATH"
The script tries to source `~/.nvm/nvm.sh` if codex isn't on `$PATH`.
If you installed Codex via npm under nvm but `nvm.sh` isn't where the
script looks, either:
- Add a wrapper shim to `~/.local/bin/codex`, or
- Install the standalone Codex binary from the [releases page](https://github.com/openai/codex/releases)

### "could not capture session id from Codex output"
Codex changed the output format or your output buffer was truncated.
Check `iter-1.txt` for a line matching `session id: [0-9a-f-]{36}`.
If it's there but in a different format, please open an issue with
the version of Codex you're running.

### Loop never converges (always reports findings)
- Make sure you're using `gpt-5.5` with `high` effort (not `medium` or `low`)
- Check `iter-N.txt` for whether Codex acknowledges previous concerns —
  if every round says "Plan missing in message" or similar, resume isn't
  working; verify `~/.codex/sessions/` is writable
- Some plans simply need design rework; consider whether the persistent
  finding is a real problem or a difference of opinion

### Permission denied on `~/.local/bin/plan-review-step`
The installer should chmod +x automatically. If not:
```bash
chmod +x ~/.local/bin/plan-review-step
```

## Limitations

- **One-reviewer only**. Future work could add Gemini, GPT-5, or others as
  parallel reviewers (see binaryroute's gist for inspiration).
- **No automation of the revision step**. Claude itself does the plan
  revision between rounds; the script only handles the Codex side.
- **Workdirs accumulate**. The audit trail design means stale workdirs
  pile up in `/tmp` (or wherever `mktemp` puts them on your OS). Cron a
  cleanup if you run `/plan-review` heavily.

## License

MIT — see [LICENSE](LICENSE).

## Related projects

- [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) —
  official Codex plugin for Claude Code; complements plan-review
- [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) —
  automated *code* review loop with Codex, plugin form
- [`serbanghita/claude-code-plan-critique`](https://github.com/serbanghita/claude-code-plan-critique) —
  similar idea, different design (single-shot critique, not resumed)
- [`amazedsaint/clocoloop`](https://github.com/amazedsaint/clocoloop) —
  Claude + Codex review loop for code/artifacts
