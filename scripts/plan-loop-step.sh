#!/usr/bin/env bash
# plan-loop-step.sh
#
# Run ONE iteration of the plan-review loop against Codex.
# Called from the /plan-loop slash command, once per iteration.
# Holds state in <workdir>.
#
# Usage:
#   plan-loop-step <workdir> <iter-nr> <plan-file>
#
# Arguments:
#   <workdir>    Directory created by the calling slash command
#                (mktemp -d, mode 700, must be owned by current user)
#   <iter-nr>    Integer, 1..MAX_ITER (default 5)
#   <plan-file>  Path to a markdown plan to review
#
# State files written into <workdir>:
#   .session-id     UUID from iter 1, used for resume in iters 2..N
#   .verdict-token  Per-iter random token used to detect verdict line
#   iter-N.txt      Codex output from iteration N
#   verdict-N.txt   "PLAN_OK" or "FINDINGS"
#
# Exit codes:
#   0   "PLAN OK" verdict — loop done, plan approved
#   1   Findings — loop must continue
#   2   User error (missing args, file not found, iter > MAX_ITER, unsafe workdir)
#   3   Codex failed (network, auth, crash)
#
# Configuration via environment variables (all optional):
#   CLAUDE_PLAN_REVIEW_PROMPT  Path to adversarial prompt template.
#                              Defaults to ../prompts/adversarial-prompt.md
#                              relative to this script's resolved location.
#   CLAUDE_PLAN_REVIEW_MAX_ITER  Maximum iterations (default 5).

set -euo pipefail
set -o noclobber

# --- Resolve script directory (handles symlinks) ---
SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROMPT_TEMPLATE="${CLAUDE_PLAN_REVIEW_PROMPT:-$REPO_DIR/prompts/adversarial-prompt.md}"
MAX_ITER="${CLAUDE_PLAN_REVIEW_MAX_ITER:-5}"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <workdir> <iter-nr> <plan-file>

Arguments:
  workdir     Directory holding state for this loop run (create with mktemp -d -m 700)
  iter-nr     Iteration number (1..$MAX_ITER)
  plan-file   Path to the plan markdown to review

Exit codes:
  0  PLAN OK
  1  Findings (continue iterating)
  2  User error
  3  Codex failed
EOF
    exit 2
}

[[ $# -eq 3 ]] || usage

WORKDIR="$1"
ITER="$2"
PLAN_FILE="$3"

# --- WORKDIR safety validation ---
# Reject anything that isn't a real directory we own and that has tight perms.
# This prevents symlink attacks where a caller points us at a directory whose
# files we'd then overwrite.
[[ -d "$WORKDIR" ]] || { echo "ERROR: workdir not found: $WORKDIR" >&2; exit 2; }
[[ -L "$WORKDIR" ]] && { echo "ERROR: workdir must not be a symlink: $WORKDIR" >&2; exit 2; }

WORKDIR_REAL="$(readlink -f "$WORKDIR")"
WORKDIR_OWNER="$(stat -c '%u' "$WORKDIR_REAL")"
WORKDIR_PERMS="$(stat -c '%a' "$WORKDIR_REAL")"
if [[ "$WORKDIR_OWNER" != "$(id -u)" ]]; then
    echo "ERROR: workdir must be owned by current user (UID $(id -u)): $WORKDIR_REAL" >&2
    exit 2
fi
if [[ "$WORKDIR_PERMS" != "700" ]]; then
    echo "ERROR: workdir must have mode 700 exactly (got $WORKDIR_PERMS): $WORKDIR_REAL" >&2
    echo "Fix with: chmod 700 \"$WORKDIR_REAL\"" >&2
    exit 2
fi

# Validate plan file is regular (not symlink) and we own it
[[ -f "$PLAN_FILE" ]] || { echo "ERROR: plan file not found: $PLAN_FILE" >&2; exit 2; }
[[ -L "$PLAN_FILE" ]] && { echo "ERROR: plan file must not be a symlink: $PLAN_FILE" >&2; exit 2; }

[[ -f "$PROMPT_TEMPLATE" ]] || { echo "ERROR: prompt template missing: $PROMPT_TEMPLATE" >&2; exit 2; }
[[ "$ITER" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: iter-nr must be a positive integer" >&2; exit 2; }
(( ITER <= MAX_ITER )) || { echo "ERROR: iter $ITER exceeds max $MAX_ITER" >&2; exit 2; }

OUTPUT="$WORKDIR/iter-$ITER.txt"
VERDICT="$WORKDIR/verdict-$ITER.txt"
SESSION_FILE="$WORKDIR/.session-id"
TOKEN_FILE="$WORKDIR/.verdict-token"

# Pre-existing iter-N or verdict-N files indicate either a re-run or tampering.
# noclobber will refuse to overwrite later, but we check up-front for a clear error.
[[ -e "$OUTPUT" ]]  && { echo "ERROR: iter-$ITER.txt already exists; use a fresh workdir" >&2; exit 2; }
[[ -e "$VERDICT" ]] && { echo "ERROR: verdict-$ITER.txt already exists; use a fresh workdir" >&2; exit 2; }

# Try to load nvm if codex isn't already on PATH (common in non-interactive shells)
if ! command -v codex >/dev/null 2>&1; then
    if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
    fi
fi
command -v codex >/dev/null 2>&1 || {
    echo "ERROR: codex CLI not found in PATH" >&2
    echo "Install with: npm install -g @openai/codex" >&2
    exit 3
}

# --- Generate per-run verdict token (anti prompt-injection) ---
# A 24-char URL-safe token is generated from /dev/urandom. We embed it in
# the reviewer prompt and only accept verdict lines containing this exact
# token. A plan author cannot guess the token, so they cannot forge a
# verdict line that the parser will accept.
if (( ITER == 1 )); then
    VERDICT_TOKEN="$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)"
    [[ -n "$VERDICT_TOKEN" && ${#VERDICT_TOKEN} -eq 24 ]] || {
        echo "ERROR: failed to generate verdict token" >&2
        exit 3
    }
    # Use noclobber-safe write
    set -C
    printf '%s\n' "$VERDICT_TOKEN" > "$TOKEN_FILE"
    set +C
    chmod 600 "$TOKEN_FILE"
else
    [[ -f "$TOKEN_FILE" ]] || {
        echo "ERROR: $TOKEN_FILE missing — was iter 1 run with this script?" >&2
        exit 2
    }
    VERDICT_TOKEN="$(cat "$TOKEN_FILE")"
fi

VERDICT_MARKER="<<VERDICT-${VERDICT_TOKEN}>>"

# Build per-iteration instruction
if (( ITER == 1 )); then
    ITER_INSTRUCTION="This is the first round. Review the entire plan."
else
    ITER_INSTRUCTION="This is round $ITER. You have seen earlier versions of the
plan in this thread. Specifically evaluate whether your previous concerns
have been addressed, and whether the changes have introduced new blockers.
Only emit the PLAN_OK verdict if no blockers remain AND no new ones have
been introduced."
fi

# Compose the full stdin payload: template (with token substituted) + iter
# context + plan in <plan> block. We pass `-` as the PROMPT argument so
# Codex reads everything from stdin. This is the only stdin mode
# `codex exec resume` supports, so we use it consistently for iter 1 and
# iter N to keep behavior uniform.
build_stdin_prompt() {
    # Substitute {{VERDICT_TOKEN}} placeholder with the actual marker
    sed "s|{{VERDICT_TOKEN}}|$VERDICT_MARKER|g" "$PROMPT_TEMPLATE"
    printf '\n\n<iter_context>\n%s\n</iter_context>\n\n<plan>\n' "$ITER_INSTRUCTION"
    cat "$PLAN_FILE"
    printf '\n</plan>\n'
}

echo "→ plan-loop iter $ITER (workdir: $WORKDIR)" >&2

# Use noclobber-safe redirection for OUTPUT
if (( ITER == 1 )); then
    # First round: new session, capture session id from output
    if ! build_stdin_prompt | codex exec \
            --skip-git-repo-check \
            - > "$OUTPUT" 2>&1; then
        echo "ERROR: codex exec failed (iter 1). See $OUTPUT" >&2
        exit 3
    fi

    # Capture session id (UUID on the line "session id: <uuid>")
    SESSION_ID="$(grep -oE 'session id: [0-9a-f-]{36}' "$OUTPUT" | head -1 | awk '{print $3}')"
    if [[ -z "$SESSION_ID" ]]; then
        echo "ERROR: could not capture session id from Codex output" >&2
        echo "See $OUTPUT for full output" >&2
        exit 3
    fi
    set -C
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
    set +C
    chmod 600 "$SESSION_FILE"
    echo "  session-id: $SESSION_ID" >&2
else
    # Resume — requires session id captured in iter 1
    [[ -f "$SESSION_FILE" ]] || {
        echo "ERROR: $SESSION_FILE missing — was iter 1 run?" >&2
        exit 2
    }
    SESSION_ID="$(cat "$SESSION_FILE")"

    if ! build_stdin_prompt | codex exec resume \
            --skip-git-repo-check \
            "$SESSION_ID" - > "$OUTPUT" 2>&1; then
        echo "ERROR: codex exec resume failed (iter $ITER). See $OUTPUT" >&2
        exit 3
    fi
fi

chmod 600 "$OUTPUT"

# --- Verdict parsing ---
# We accept ONLY a verdict line that matches:
#   <<VERDICT-{TOKEN}>> PLAN_OK
# or:
#   <<VERDICT-{TOKEN}>> FINDINGS
#
# The token is fresh per run and never seen by the plan author, so a
# malicious plan cannot forge a verdict line that grep accepts. We scan
# the whole output (not just the last line) so position-sensitive
# injections don't matter.
EXPECTED_PLAN_OK="${VERDICT_MARKER} PLAN_OK"
EXPECTED_FINDINGS="${VERDICT_MARKER} FINDINGS"

if grep -Fxq "$EXPECTED_PLAN_OK" "$OUTPUT"; then
    set -C
    printf 'PLAN_OK\n' > "$VERDICT"
    set +C
    chmod 600 "$VERDICT"
    echo "  verdict: PLAN OK (iter $ITER)" >&2
    exit 0
elif grep -Fxq "$EXPECTED_FINDINGS" "$OUTPUT"; then
    set -C
    printf 'FINDINGS\n' > "$VERDICT"
    set +C
    chmod 600 "$VERDICT"
    echo "  verdict: findings (iter $ITER) — see $OUTPUT" >&2
    exit 1
else
    # Reviewer did not emit a valid verdict line at all. Could be a Codex
    # error, a token-substitution failure, or a malformed reply. Treat as
    # findings to be safe.
    set -C
    printf 'NO_VERDICT_LINE\n' > "$VERDICT"
    set +C
    chmod 600 "$VERDICT"
    echo "  verdict: no valid verdict line found (iter $ITER) — see $OUTPUT" >&2
    echo "  expected one of: $EXPECTED_PLAN_OK | $EXPECTED_FINDINGS" >&2
    exit 1
fi
