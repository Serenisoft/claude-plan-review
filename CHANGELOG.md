# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] — 2026-04-27

### Fixed
- `install.sh` no longer prints a spurious "WARNING: plan-loop-step did
  not print usage as expected" line when verifying the install. The
  script writes usage to stderr (correctly), but the verification only
  captured stdout.

## [0.1.3] — 2026-04-27

### Changed
- README opens with a one-paragraph pitch (problem + how we solve it)
  instead of leading with the "personal tool" disclaimer. The disclaimer
  moved below the example, where it's still visible without being the
  first thing visitors read.

## [0.1.2] — 2026-04-27

### Changed
- Slash command and README now document all three legitimate invocation
  patterns:
  - **A** — discuss with Claude first, then `/plan-loop` with no args
    (Claude uses conversation context for plan-v1) — most common in
    practice
  - **B** — `/plan-loop <feature>` for direct invocation with no prior
    conversation
  - **C** — `/plan-loop <focus instruction>` after discussion, where the
    argument weights the review focus
- Slash command frontmatter `argument-hint` updated to reflect that the
  argument is optional.
- Routing logic added to the slash command so Claude can detect which
  mode it's in (empty arg + prior conversation, focus phrasing, feature
  phrasing) and act accordingly.

## [0.1.1] — 2026-04-27

### Changed
- README: lead with the fundamental gap (plugin reviews files only, not
  plans in chat) instead of the secondary point about resume continuity.
  Restructured "Why this exists" with a primary section on the file-vs-chat
  gap and a "Bonus" section on context-preserving resume.
- README: clarify that `$ARGUMENTS` is the feature description (Claude
  drafts the plan), not a pre-written plan. Added an example flow for
  reviewing an existing plan file via direct `plan-loop-step` invocation.
- README: install step now says "restart Claude Code" explicitly — slash
  commands are registered at startup, `/reload-plugins` does not pick
  them up.

## [0.1.0] — 2026-04-27

### Added
- `/plan-loop <feature>` slash command for Claude Code that drives an
  iterative plan review against Codex.
- `plan-loop-step` shell script that runs one iteration: fresh Codex
  session on iter 1 (capturing the session id), `codex exec resume` on
  iter 2..N for context continuity.
- Adversarial prompt template (`prompts/adversarial-prompt.md`) tuned for
  plan review (not code review). Uses an exact `PLAN OK` sentinel as the
  loop's stop signal.
- `install.sh` for symlinking the slash command into `~/.claude/commands/`
  and the step script into `~/.local/bin/`.
- README, CONTRIBUTING, LICENSE (MIT), CHANGELOG.

### Design notes
- Resume-based loop chosen over fresh-each-round after empirical evidence
  that fresh runs do not converge: each round surfaces a different
  finding set on the same unchanged plan, so `PLAN OK` is never reached.
  See README "How it works" for the full rationale.
- Workdirs use `mktemp -d` with mode 700 (not `/tmp/plan-loop/<uuid>`)
  to avoid world-readable plan leakage.
- Session id is captured explicitly from iter 1 output and reused for all
  resume calls (not `--last`, which is not concurrency-safe).

[Unreleased]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Serenisoft/claude-plan-review/releases/tag/v0.1.0
