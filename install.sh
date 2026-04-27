#!/usr/bin/env bash
# install.sh — install or uninstall claude-plan-review.
#
# Symlinks:
#   commands/plan-review.md       → ~/.claude/commands/plan-review.md
#   scripts/plan-review-step.sh   → ~/.local/bin/plan-review-step
#
# Usage:
#   bash install.sh              install (refuses to overwrite foreign files)
#   bash install.sh --force      install, overwriting any existing target
#   bash install.sh --uninstall  remove symlinks (only ours)
#
# Idempotent — safe to re-run as long as targets are our own symlinks.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DST="$HOME/.claude/commands"
BIN_DST="$HOME/.local/bin"
SLASH_LINK="$COMMANDS_DST/plan-review.md"
BIN_LINK="$BIN_DST/plan-review-step"

SLASH_TARGET="$REPO_DIR/commands/plan-review.md"
BIN_TARGET="$REPO_DIR/scripts/plan-review-step.sh"

# Legacy symlinks from versions before v0.3.0. We remove them on install
# if they point into our repo, so users don't end up with both a stale
# /plan-loop and the new /plan-review.
LEGACY_SLASH_LINK="$COMMANDS_DST/plan-loop.md"
LEGACY_BIN_LINK="$BIN_DST/plan-loop-step"

FORCE=0

uninstall() {
    echo "→ Removing our symlinks (only if they point into this repo)"
    for path in "$SLASH_LINK" "$BIN_LINK"; do
        if [[ -L "$path" ]]; then
            target="$(readlink "$path")"
            case "$target" in
                "$REPO_DIR"/*)
                    rm -v "$path"
                    ;;
                *)
                    echo "  $path points to $target — not ours, leaving alone" >&2
                    ;;
            esac
        fi
    done
    echo "Done. Reload Claude Code (restart) to pick up the change."
    exit 0
}

# Verify a destination path is safe to overwrite.
# Refuses if the path is:
#   - a regular file (not a symlink) — could be the user's own work
#   - a symlink pointing somewhere outside our repo — could be another tool's
# Allows if:
#   - path doesn't exist
#   - path is a symlink already pointing into our repo (idempotent re-run)
#   - --force was passed
check_dest_safe() {
    local path="$1"
    local expected_target="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    if [[ -L "$path" ]]; then
        local current_target
        current_target="$(readlink "$path")"
        if [[ "$current_target" == "$expected_target" ]]; then
            return 0
        fi
        case "$current_target" in
            "$REPO_DIR"/*)
                # Old symlink into our repo, fine to update
                return 0
                ;;
        esac
        if (( FORCE == 1 )); then
            return 0
        fi
        cat >&2 <<EOF
ERROR: $path is a symlink pointing to:
  $current_target

That's not part of this repo. Refusing to overwrite without --force.

If you want to keep the existing target, do nothing.
If you want to install claude-plan-review here, re-run with: bash install.sh --force
EOF
        exit 1
    fi
    # Path exists and is NOT a symlink — refuse hard
    if (( FORCE == 1 )); then
        echo "  WARNING: $path exists as a regular file/dir; --force given, will overwrite"
        return 0
    fi
    cat >&2 <<EOF
ERROR: $path exists and is not a symlink.

Refusing to overwrite a regular file/directory. If this was an earlier
install or a file you don't need, remove it first:
  rm "$path"
Then re-run install. Or use --force to overwrite.
EOF
    exit 1
}

# --- Argument parsing ---
case "${1:-}" in
    --uninstall) uninstall ;;
    --force)     FORCE=1 ;;
    "")          ;;
    *)           echo "Unknown argument: $1" >&2; exit 2 ;;
esac

echo "=== claude-plan-review install ==="
echo "Repo: $REPO_DIR"
(( FORCE == 1 )) && echo "Mode: --force (will overwrite existing targets)"
echo

# --- Prerequisite checks ---
echo "→ Checking prerequisites"

# codex CLI (try to load nvm if not on PATH yet)
if ! command -v codex >/dev/null 2>&1; then
    if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
    fi
fi
if ! command -v codex >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: codex CLI not found.

Install with one of:
  npm install -g @openai/codex     (requires Node 18.18+)
  https://github.com/openai/codex   (releases)

Then run: codex login
EOF
    exit 1
fi
echo "  codex: $(codex --version 2>&1 | head -1)"

# v0.4+ requires --sandbox flag (Codex v0.118+). Verify capability.
if ! codex exec --help 2>&1 | grep -q -- '--sandbox'; then
    cat >&2 <<EOF

ERROR: your Codex CLI does not support the --sandbox flag.
plan-review v0.4+ uses --sandbox read-only on every Codex call.

Upgrade with: npm install -g @openai/codex@latest
Minimum version: v0.118
EOF
    exit 1
fi

# claude CLI (warn but don't block — useful for non-Claude-Code users
# who want to run plan-review-step manually)
if command -v claude >/dev/null 2>&1; then
    echo "  claude: $(claude --version 2>&1)"
else
    echo "  claude: NOT FOUND (optional — only needed for the /plan-review slash command)"
fi

# ~/.local/bin in PATH?
case ":$PATH:" in
    *":$BIN_DST:"*) echo "  ~/.local/bin in PATH: yes" ;;
    *)
        cat <<EOF
  ~/.local/bin in PATH: NO

  Add this to ~/.bashrc or ~/.zshrc:
      export PATH="\$HOME/.local/bin:\$PATH"

  Then reopen your shell. Continuing with install anyway.
EOF
        ;;
esac

# --- Remove legacy symlinks from before v0.3.0 ---
echo
echo "→ Removing legacy /plan-loop symlinks (if any point into this repo)"
for legacy in "$LEGACY_SLASH_LINK" "$LEGACY_BIN_LINK"; do
    if [[ -L "$legacy" ]]; then
        target="$(readlink "$legacy")"
        case "$target" in
            "$REPO_DIR"/*)
                rm -v "$legacy"
                ;;
            *)
                echo "  $legacy → $target — not ours, leaving alone" >&2
                ;;
        esac
    fi
done

# --- Safety check destinations ---
echo
echo "→ Checking destination paths"
check_dest_safe "$SLASH_LINK" "$SLASH_TARGET"
check_dest_safe "$BIN_LINK" "$BIN_TARGET"
echo "  destinations safe to write"

# --- Create symlinks ---
echo
echo "→ Creating symlinks"
mkdir -p "$COMMANDS_DST" "$BIN_DST"
ln -sfn "$SLASH_TARGET" "$SLASH_LINK"
echo "  $SLASH_LINK → $SLASH_TARGET"
ln -sfn "$BIN_TARGET" "$BIN_LINK"
echo "  $BIN_LINK → $BIN_TARGET"

# --- Verify ---
echo
echo "→ Verifying install"
if [[ -L "$SLASH_LINK" ]] && [[ -L "$BIN_LINK" ]]; then
    # plan-review-step prints usage to stderr and exits 2 on no-args.
    # Capture both streams into a variable so we don't fight pipefail.
    verify_output="$("$BIN_LINK" 2>&1 || true)"
    if [[ "$verify_output" == *"Usage:"* ]]; then
        echo "  plan-review-step prints usage: OK"
    else
        echo "  WARNING: plan-review-step did not print usage as expected"
    fi
fi

cat <<EOF

=== Install complete ===

What's new in v0.4:
  • Codex now gets read-only access to your project files during review
    (slash command captures \$(pwd), passes it to codex via -C). Findings
    calibrate to your codebase, not generic best-practices.
  • Default MAX_ITER is 3 (was 5). Override: CLAUDE_PLAN_REVIEW_MAX_ITER=5.
  • Codex always runs with --sandbox read-only regardless of your
    config.toml — defense-in-depth for plan review specifically.

Next steps:
  1. Restart Claude Code (slash commands are loaded at startup, not at /reload-plugins).
  2. Verify the slash command is available: /plan-review
  3. Configure ~/.codex/config.toml (sandbox/approval are managed per-call now):
        model = "gpt-5.5"
        model_reasoning_effort = "high"
  4. Try it:
        /plan-review add expiry dates to short URLs

Uninstall: bash install.sh --uninstall
EOF
