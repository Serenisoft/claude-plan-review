# Contributing

Thanks for your interest. A few notes to set expectations:

- This is a personal tool maintained by [Serenisoft](https://github.com/Serenisoft).
  Response time is best-effort and may be days or weeks.
- **Open an issue first** before submitting a pull request. A short
  discussion saves effort on both sides — we want to make sure the change
  fits the project before you invest time.

## Reporting bugs

When opening an issue, include:

- Output of `codex --version` and `claude --version`
- The exact `/plan-review` invocation you used
- The contents of `iter-N.txt` from the workdir if a Codex call failed
- What you expected to happen vs. what actually happened

## Suggesting features

plan-review has a deliberately small surface area. Before suggesting a
feature, consider whether it really belongs here or in a wrapper script
on top. Strong candidates:

- Better convergence heuristics (e.g. detecting repeated findings)
- Multi-reviewer support (Codex + Gemini + others)
- Better PLAN OK detection (currently exact-match on last non-empty line)

## Pull requests

- Keep changes focused. One logical change per PR.
- Update `CHANGELOG.md` under the `[Unreleased]` section.
- Make sure `bash -n scripts/plan-review-step.sh` passes.
- If you change the prompt template or the slash command, run the loop
  end-to-end at least once before submitting.

## Code style

- Bash: `set -euo pipefail` everywhere. Quote variables. Prefer POSIX
  builtins when portable.
- Markdown: keep prompts and slash commands compact; reviewer attention
  is finite.
- Comments explain *why*, not *what*. The code already says what.
