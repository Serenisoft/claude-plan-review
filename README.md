# claude-plan-review

> **Note:** Personal Serenisoft tool. No support guarantees, response time may
> be days or weeks. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

A `/plan-loop` slash command for [Claude Code](https://claude.com/claude-code)
that drives an iterative plan review against [OpenAI Codex](https://github.com/openai/codex).
Claude drafts the plan, Codex acts as the adversarial reviewer, Claude
revises, and the loop continues until Codex returns `PLAN OK` or you hit
the iteration cap.

```
/plan-loop add expiry dates to short URLs

  iter 1  → Codex finds 4 blockers
  iter 2  → Claude revises plan, Codex sees the changes (resumed thread),
            confirms 3 are fixed, surfaces 2 new ones from the new design
  iter 3  → Claude revises again
  iter 4  → Codex: PLAN OK
```

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

## Prerequisites

| Tool | Why | How to install |
|------|-----|----------------|
| [Codex CLI](https://github.com/openai/codex) v0.118+ | Runs the review (`codex exec resume` requires this version) | `npm install -g @openai/codex` (needs Node 18.18+) |
| ChatGPT account | Codex auth | Run `codex login` after install (opens browser); or set `OPENAI_API_KEY` |
| [Claude Code](https://claude.com/claude-code) 2.x | Hosts the `/plan-loop` slash command | Follow the [official install guide](https://docs.anthropic.com/en/docs/claude-code) |
| `bash` 4+, `awk`, `grep`, `mktemp` | Standard on Linux/macOS | (already installed) |

### Recommended (not required)

The [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
plugin gives you `/codex:review`, `/codex:rescue`, and other commands that
complement plan-loop nicely. They are independent — plan-loop does not
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
| `commands/plan-loop.md` | `~/.claude/commands/plan-loop.md` |
| `scripts/plan-loop-step.sh` | `~/.local/bin/plan-loop-step` |

Make sure `~/.local/bin` is in your `$PATH` (Ubuntu does this by default
when the directory exists at login; reopen your shell if it didn't).

Then **restart Claude Code** (slash commands are registered at startup,
not on file change) and try:

```
/plan-loop add a "copy link" button to the link detail page
```

### What goes in `$ARGUMENTS`

`$ARGUMENTS` is the **feature description**, not the plan. Claude drafts
plan-v1 from this short description; you don't paste a multi-paragraph
plan into the slash command. Examples:

- `/plan-loop add expiry dates to short URLs`
- `/plan-loop migrate auth from sessions to JWT`
- `/plan-loop split the monolith billing service into per-customer workers`

If you already have a plan written somewhere and just want it reviewed,
manually copy it to the workdir and run `plan-loop-step` directly:

```bash
WORKDIR=$(mktemp -d -t plan-loop-XXXXXXXX)
chmod 700 "$WORKDIR"
cp my-existing-plan.md "$WORKDIR/plan-v1.md"
plan-loop-step "$WORKDIR" 1 "$WORKDIR/plan-v1.md"
# then iterate manually with plan-v2.md, plan-v3.md, etc.
```

## Recommended Codex configuration

Drop the following into `~/.codex/config.toml` (skip if you already have
your own preferences):

```toml
model = "gpt-5.5"
model_reasoning_effort = "high"
sandbox_mode = "danger-full-access"
approval_policy = "never"
```

- **`gpt-5.5` with `high` effort** is the sweet spot for adversarial plan
  review — `xhigh` is overkill for plan-sized inputs and roughly 2–4x more
  reasoning tokens. `medium` misses subtler edge cases.
- **`danger-full-access` + `never`** disables Codex's bubblewrap sandbox.
  This is reasonable here because Codex is reading a markdown plan, not
  executing arbitrary code. If you prefer the sandbox enabled, you may
  need to install `bubblewrap` and ensure user namespaces are allowed by
  the kernel.

## How it works

1. **Step 1** — Slash command creates a workdir with `mktemp -d -t plan-loop-XXXXXXXX`
   (mode 700, not world-readable).
2. **Step 2** — Claude drafts `plan-v1.md` in the workdir.
3. **Step 3 (iter 1)** — `plan-loop-step` calls `codex exec` with the
   adversarial prompt and the plan. Output is captured to `iter-1.txt`,
   the Codex session id is grepped from the output and stored in
   `.session-id`. Verdict (`PLAN_OK` or `FINDINGS`) is written to
   `verdict-1.txt`.
4. **Step 4 (iters 2..N)** — Claude reads `iter-N-1.txt`, judges each
   finding, revises the plan to a new `plan-vN.md`, and runs
   `plan-loop-step` again. The script calls `codex exec resume <session-id>`
   so Codex keeps full context of the prior rounds.
5. **Step 5** — Loop ends on `PLAN OK` (last non-empty line, exact match)
   or when iter 5 finishes with findings. The workdir is preserved as an
   audit trail; you remove it manually with `rm -rf "$WORKDIR"`.

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

### Why max 5 iterations

Reported convergence in the wild is 2–3 rounds typical. 5 is a safety
ceiling against runaway token cost; if Codex still hasn't said `PLAN OK`
after iter 5, the design likely has a deliberate tradeoff Codex won't
accept (e.g. denial of an industry best practice) and you should review
manually.

## Files in this repo

```
claude-plan-review/
├── README.md                  ← you are here
├── LICENSE                    ← MIT
├── CHANGELOG.md
├── CONTRIBUTING.md
├── install.sh                 ← symlinks and verifies prerequisites
├── commands/
│   └── plan-loop.md           ← Claude Code slash command
├── prompts/
│   └── adversarial-prompt.md  ← review prompt template (English)
└── scripts/
    └── plan-loop-step.sh      ← one iteration per call
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

### Permission denied on `~/.local/bin/plan-loop-step`
The installer should chmod +x automatically. If not:
```bash
chmod +x ~/.local/bin/plan-loop-step
```

## Limitations

- **One-reviewer only**. Future work could add Gemini, GPT-5, or others as
  parallel reviewers (see binaryroute's gist for inspiration).
- **No automation of the revision step**. Claude itself does the plan
  revision between rounds; the script only handles the Codex side.
- **Workdirs accumulate**. The audit trail design means stale workdirs
  pile up in `/tmp` (or wherever `mktemp` puts them on your OS). Cron a
  cleanup if you run `/plan-loop` heavily.

## License

MIT — see [LICENSE](LICENSE).

## Related projects

- [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) —
  official Codex plugin for Claude Code; complements plan-loop
- [`hamelsmu/claude-review-loop`](https://github.com/hamelsmu/claude-review-loop) —
  automated *code* review loop with Codex, plugin form
- [`serbanghita/claude-code-plan-critique`](https://github.com/serbanghita/claude-code-plan-critique) —
  similar idea, different design (single-shot critique, not resumed)
- [`amazedsaint/clocoloop`](https://github.com/amazedsaint/clocoloop) —
  Claude + Codex review loop for code/artifacts
