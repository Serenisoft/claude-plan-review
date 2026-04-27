#!/usr/bin/env bash
# plan-review-step.sh
#
# Run ONE iteration of the plan-review loop against Codex.
# Called from the /plan-review slash command, once per iteration.
# Holds state in <workdir>.
#
# Usage:
#   plan-review-step <workdir> <iter-nr> <plan-file> [project-root]
#
# Arguments:
#   <workdir>       Directory created by the calling slash command
#                   (mktemp -d, mode 700, must be owned by current user)
#   <iter-nr>       Integer, 1..MAX_ITER (default 3)
#   <plan-file>     Path to a markdown plan to review
#   [project-root]  Optional. If provided, Codex gets read-only access to
#                   this directory via `codex exec -C <root>`. Lets the
#                   reviewer verify assumptions against actual project
#                   files. Falls back to CLAUDE_PLAN_REVIEW_PROJECT_ROOT.
#                   If neither is set, the script runs in workdir-only
#                   mode (Codex sees only stdin, no project files).
#
# Optional state files in <workdir>:
#   project-context.md  Plan-author-supplied facts about the project
#                       (architecture, ADRs, conventions). When present,
#                       inserted into Codex prompt as <project_context>.
#                       The /plan-review slash command writes this; CLI
#                       users can write it manually before iter 1.
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
#   CLAUDE_PLAN_REVIEW_PROMPT        Path to adversarial prompt template.
#                                    Defaults to ../prompts/adversarial-prompt.md
#                                    relative to this script's resolved location.
#   CLAUDE_PLAN_REVIEW_MAX_ITER      Maximum iterations (default 3).
#   CLAUDE_PLAN_REVIEW_PROJECT_ROOT  Fallback for [project-root] when not
#                                    passed positionally.

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
MAX_ITER="${CLAUDE_PLAN_REVIEW_MAX_ITER:-3}"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <workdir> <iter-nr> <plan-file> [project-root]

Arguments:
  workdir       Directory holding state for this loop run (create with mktemp -d -m 700)
  iter-nr       Iteration number (1..$MAX_ITER)
  plan-file     Path to the plan markdown to review
  project-root  Optional directory Codex gets read-only access to.
                Falls back to \$CLAUDE_PLAN_REVIEW_PROJECT_ROOT.

Exit codes:
  0  PLAN OK
  1  Findings (continue iterating)
  2  User error
  3  Codex failed
EOF
    exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage

WORKDIR="$1"
ITER="$2"
PLAN_FILE="$3"
PROJECT_ROOT="${4:-${CLAUDE_PLAN_REVIEW_PROJECT_ROOT:-}}"

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

# --- PROJECT_ROOT validation (when set) ---
# When project-root is provided, Codex gets read-only access to it via -C.
# We require the directory exists, isn't a symlink, and is owned by us —
# preventing accidental pointer to a foreign user's project.
PROJECT_ROOT_REAL=""
if [[ -n "$PROJECT_ROOT" ]]; then
    [[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project-root not a directory: $PROJECT_ROOT" >&2; exit 2; }
    [[ -L "$PROJECT_ROOT" ]] && { echo "ERROR: project-root must not be a symlink: $PROJECT_ROOT" >&2; exit 2; }
    PROJECT_ROOT_REAL="$(readlink -f "$PROJECT_ROOT")"
    PROJECT_OWNER="$(stat -c '%u' "$PROJECT_ROOT_REAL")"
    if [[ "$PROJECT_OWNER" != "$(id -u)" ]]; then
        echo "ERROR: project-root must be owned by current user (UID $(id -u)): $PROJECT_ROOT_REAL" >&2
        exit 2
    fi
fi

# --- Optional project-context.md ---
# If the slash command (or a manual user) wrote project-context.md into
# the workdir, splice it into the Codex prompt. Validate it's a regular
# file we own — symlinks are rejected for the same reason as elsewhere.
PROJECT_CONTEXT_FILE="$WORKDIR/project-context.md"
HAS_PROJECT_CONTEXT=0
if [[ -e "$PROJECT_CONTEXT_FILE" ]]; then
    [[ -f "$PROJECT_CONTEXT_FILE" ]] || { echo "ERROR: project-context.md is not a regular file" >&2; exit 2; }
    [[ -L "$PROJECT_CONTEXT_FILE" ]] && { echo "ERROR: project-context.md must not be a symlink" >&2; exit 2; }
    PC_OWNER="$(stat -c '%u' "$PROJECT_CONTEXT_FILE")"
    [[ "$PC_OWNER" == "$(id -u)" ]] || { echo "ERROR: project-context.md must be owned by current user" >&2; exit 2; }
    # Light size guardrail — warn (not fail) if context is unusually large.
    PC_WORDS="$(wc -w < "$PROJECT_CONTEXT_FILE")"
    if (( PC_WORDS > 1500 )); then
        echo "WARNING: project-context.md is $PC_WORDS words — keep it focused (<1500 words recommended)" >&2
    fi
    HAS_PROJECT_CONTEXT=1
fi

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
    # noclobber is set globally at script top — `>` will refuse to overwrite
    printf '%s\n' "$VERDICT_TOKEN" > "$TOKEN_FILE"
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
IS_LAST_ITER=0
(( ITER == MAX_ITER )) && IS_LAST_ITER=1

if (( ITER == 1 )); then
    ITER_INSTRUCTION="This is the first round. Review the entire plan."
    if (( HAS_PROJECT_CONTEXT == 1 )); then
        ITER_INSTRUCTION+=$'\nA <project_context> block has been provided with project-specific facts.
Use it to calibrate your findings to this codebase\'s actual conventions.'
    fi
else
    ITER_INSTRUCTION="This is round $ITER. You have seen earlier versions of the
plan in this thread. Specifically evaluate whether your previous concerns
have been addressed, and whether the changes have introduced new blockers.
Only emit the PLAN_OK verdict if no blockers remain AND no new ones have
been introduced."
fi

if (( IS_LAST_ITER == 1 && ITER > 1 )); then
    ITER_INSTRUCTION+=$'\n\nThis is the FINAL round (max iterations = '"$MAX_ITER"$'). Raise only blocking
design issues. Speculative concerns, micro-bugs, style, and polish are
out of scope. If the plan has no blockers but has minor opportunities
for improvement, emit PLAN_OK and let the author iterate later.'
fi

# Compose the full stdin payload:
#   prompt template (with token substituted)
#   + optional <project_context> block (only when project-context.md exists)
#   + <iter_context> block
#   + <plan> block
# We pass `-` as the PROMPT argument so Codex reads everything from stdin.
# This is the only stdin mode `codex exec resume` supports, so we use it
# consistently for iter 1 and iter N to keep behavior uniform.
build_stdin_prompt() {
    # Substitute {{VERDICT_TOKEN}} placeholder with the actual marker
    sed "s|{{VERDICT_TOKEN}}|$VERDICT_MARKER|g" "$PROMPT_TEMPLATE"
    if (( HAS_PROJECT_CONTEXT == 1 )); then
        printf '\n\n<project_context>\n'
        cat "$PROJECT_CONTEXT_FILE"
        printf '\n</project_context>\n'
    fi
    printf '\n\n<iter_context>\n%s\n</iter_context>\n\n<plan>\n' "$ITER_INSTRUCTION"
    cat "$PLAN_FILE"
    printf '\n</plan>\n'
}

# --- Build Codex flag array ---
# Always: --sandbox read-only (defense-in-depth — review never needs to write)
# Always: --skip-git-repo-check (idempotent; permits non-repo project roots)
# When PROJECT_ROOT set: -C <canonical-path> (Codex can read project files)
CODEX_FLAGS=(--sandbox read-only --skip-git-repo-check)
if [[ -n "$PROJECT_ROOT_REAL" ]]; then
    CODEX_FLAGS+=(-C "$PROJECT_ROOT_REAL")
fi

echo "→ plan-review iter $ITER (workdir: $WORKDIR)" >&2

# Use noclobber-safe redirection for OUTPUT
if (( ITER == 1 )); then
    # First round: new session, capture session id from output
    if ! build_stdin_prompt | codex exec \
            "${CODEX_FLAGS[@]}" \
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
    printf '%s\n' "$SESSION_ID" > "$SESSION_FILE"
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
            "${CODEX_FLAGS[@]}" \
            "$SESSION_ID" - > "$OUTPUT" 2>&1; then
        echo "ERROR: codex exec resume failed (iter $ITER). See $OUTPUT" >&2
        exit 3
    fi
fi

chmod 600 "$OUTPUT"

# --- Verdict parsing ---
# We accept ONLY the verdict line as the LAST non-empty line of the
# Codex output, matching exactly one of:
#   <<VERDICT-{TOKEN}>> PLAN_OK
#   <<VERDICT-{TOKEN}>> FINDINGS
#
# Last-line matching avoids a real correctness bug: if Codex echoes the
# verdict format in its reasoning (e.g. "an example verdict line is
# `<<VERDICT-X>> PLAN_OK`"), a free-text scan would pick that up before
# the actual verdict. The reviewer prompt explicitly tells Codex to put
# the verdict line last, and we enforce that.
EXPECTED_PLAN_OK="${VERDICT_MARKER} PLAN_OK"
EXPECTED_FINDINGS="${VERDICT_MARKER} FINDINGS"

LAST_NONEMPTY="$(awk 'NF { last = $0 } END { print last }' "$OUTPUT" | sed 's/[[:space:]]*$//')"

if [[ "$LAST_NONEMPTY" == "$EXPECTED_PLAN_OK" ]]; then
    printf 'PLAN_OK\n' > "$VERDICT"
    chmod 600 "$VERDICT"
    echo "  verdict: PLAN OK (iter $ITER)" >&2
    exit 0
elif [[ "$LAST_NONEMPTY" == "$EXPECTED_FINDINGS" ]]; then
    printf 'FINDINGS\n' > "$VERDICT"
    chmod 600 "$VERDICT"
    echo "  verdict: findings (iter $ITER) — see $OUTPUT" >&2
    exit 1
else
    # Last line didn't match a valid verdict. Treat as findings to be safe;
    # the user should inspect iter-N.txt and decide whether to retry.
    printf 'NO_VERDICT_LINE\n' > "$VERDICT"
    chmod 600 "$VERDICT"
    echo "  verdict: last non-empty line is not a valid verdict (iter $ITER)" >&2
    echo "  last line was: ${LAST_NONEMPTY:0:80}" >&2
    echo "  expected one of: $EXPECTED_PLAN_OK | $EXPECTED_FINDINGS" >&2
    exit 1
fi
