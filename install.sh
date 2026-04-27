#!/usr/bin/env bash
# install.sh — install or uninstall claude-plan-review.
#
# Symlinks:
#   commands/plan-loop.md       → ~/.claude/commands/plan-loop.md
#   scripts/plan-loop-step.sh   → ~/.local/bin/plan-loop-step
#
# Usage:
#   bash install.sh              install
#   bash install.sh --uninstall  remove symlinks
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DST="$HOME/.claude/commands"
BIN_DST="$HOME/.local/bin"
SLASH_LINK="$COMMANDS_DST/plan-loop.md"
BIN_LINK="$BIN_DST/plan-loop-step"

uninstall() {
    echo "→ Removing symlinks"
    [[ -L "$SLASH_LINK" ]] && rm -v "$SLASH_LINK"
    [[ -L "$BIN_LINK" ]]   && rm -v "$BIN_LINK"
    echo "Done. Reload Claude Code (/reload-plugins or restart) to pick up the change."
    exit 0
}

[[ "${1:-}" == "--uninstall" ]] && uninstall

echo "=== claude-plan-review install ==="
echo "Repo: $REPO_DIR"
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

# claude CLI (warn but don't block — useful for non-Claude-Code users
# who want to run plan-loop-step manually)
if command -v claude >/dev/null 2>&1; then
    echo "  claude: $(claude --version 2>&1)"
else
    echo "  claude: NOT FOUND (optional — only needed for the /plan-loop slash command)"
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

# --- Create symlinks ---
echo
echo "→ Creating symlinks"
mkdir -p "$COMMANDS_DST" "$BIN_DST"
ln -sfn "$REPO_DIR/commands/plan-loop.md" "$SLASH_LINK"
echo "  $SLASH_LINK → $REPO_DIR/commands/plan-loop.md"
ln -sfn "$REPO_DIR/scripts/plan-loop-step.sh" "$BIN_LINK"
echo "  $BIN_LINK → $REPO_DIR/scripts/plan-loop-step.sh"

# --- Verify ---
echo
echo "→ Verifying install"
if [[ -L "$SLASH_LINK" ]] && [[ -L "$BIN_LINK" ]]; then
    if "$BIN_LINK" 2>&1 | grep -q "Usage:"; then
        echo "  plan-loop-step responds to --help: OK"
    else
        echo "  WARNING: plan-loop-step did not print usage as expected"
    fi
fi

cat <<EOF

=== Install complete ===

Next steps:
  1. Reload Claude Code (/reload-plugins or restart).
  2. Verify the slash command is available: /plan-loop
  3. (Optional) Configure ~/.codex/config.toml:
        model = "gpt-5.5"
        model_reasoning_effort = "high"
        sandbox_mode = "danger-full-access"
        approval_policy = "never"
  4. Try it:
        /plan-loop add expiry dates to short URLs

Uninstall: bash install.sh --uninstall
EOF
