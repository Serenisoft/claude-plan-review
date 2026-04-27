# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Serenisoft/claude-plan-review/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Serenisoft/claude-plan-review/releases/tag/v0.1.0
