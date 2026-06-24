#!/bin/bash
# Register / re-sync this Claude session in ~/.claude/running-agents.
#
# Idempotent: safe to call from SessionStart and as a self-heal prelude
# from agent-send.sh / agent-rename.sh. All paths converge on the same
# end state.
#
# Registry: ~/.claude/running-agents/<name>.<claude_pid>  (content: $TMUX_PANE)
# Name:     current git branch (sanitized), fallback to cwd basename.
#
# On SessionStart it also injects agent-type-specific startup instructions
# (the "role context") via additionalContext — see "Role context" below.
#
# Usage:
#   register-agent.sh sessionstart      — full setup; role context + /rename keystroke
#   register-agent.sh send-selfheal     — quiet re-sync; no role context, no /rename
#   register-agent.sh rename-selfheal   — quiet re-sync; no role context, no /rename

set -u

LOG="$HOME/.claude/debug/register-agent.log"
mkdir -p "$(dirname "$LOG")"

# Drain hook stdin and capture for session_id extraction + diagnostic log.
stdin_payload=$(cat 2>/dev/null || true)

source="${1:-sessionstart}"
ts=$(date '+%Y-%m-%d %H:%M:%S')

log() {
  printf '%s [%s] %s\n' "$ts" "$source" "$*" >> "$LOG"
}

log "fired. TMUX_PANE=${TMUX_PANE:-(unset)} cwd=$PWD payload_bytes=${#stdin_payload}"

# tmux is OPTIONAL (DX-jn-8-019): without it we still register, keyed by a
# cwd-based identity token (see _fleet.sh). Only the tmux cosmetics (pane/window
# title, /rename keystroke) below are skipped when tmux is unavailable.

# --- Resolve the claude PID ---
# Strategy (most -> least reliable):
#   1. Parse session_id from hook stdin JSON, then look up the matching
#      ~/.claude/sessions/<pid>.json — pid is authoritative because Claude
#      Code itself writes those files. Verify the candidate PID is still
#      alive and is actually a claude process (session files accumulate
#      across runs, so blind trust gives stale PIDs).
#   2. Walk the process tree from $$ upward; find nearest ancestor whose
#      command starts with `claude`.
#   3. Last-ditch: $PPID (unreliable because Claude Code wraps hooks in
#      an intermediate shell).
claude_pid=""

session_id=""
if [ -n "$stdin_payload" ] && command -v jq >/dev/null 2>&1; then
  session_id=$(printf '%s' "$stdin_payload" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [ -n "$session_id" ]; then
  for f in "$HOME/.claude/sessions/"*.json; do
    [ -f "$f" ] || continue
    if grep -q "\"sessionId\":\"$session_id\"" "$f" 2>/dev/null; then
      candidate=$(basename "$f" .json)
      if kill -0 "$candidate" 2>/dev/null && \
         ps -p "$candidate" -o command= 2>/dev/null | grep -qE '(^|/)claude( |$)'; then
        claude_pid="$candidate"
        log "pid=$claude_pid via session_id=$session_id"
        break
      else
        log "skipping stale session file $f (pid $candidate not a live claude)"
      fi
    fi
  done
fi

if [ -z "$claude_pid" ]; then
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! read -r ppid cmd < <(ps -p "$pid" -o ppid=,command= 2>/dev/null); then
      break
    fi
    [ -z "${ppid:-}" ] && break
    if printf '%s' "$cmd" | grep -qE '(^|/)claude( |$)'; then
      claude_pid="$pid"
      log "pid=$claude_pid via process-tree walk"
      break
    fi
    pid="$ppid"
  done
fi

if [ -z "$claude_pid" ]; then
  claude_pid="$PPID"
  log "pid=$claude_pid via PPID fallback (probably wrong)"
fi

# --- Load per-project workflow config ---
# Defines optional WORKFLOW_AGENT_* knobs:
#   WORKFLOW_AGENT_DEFAULT_BRANCH   — pins agent name + base branch in config
#   WORKFLOW_AGENT_NAME_PREFIX      — prepended to derived name
#   WORKFLOW_AGENT_NAME_TRANSFORM   — sed expr applied to derived name
#   WORKFLOW_AGENT_SKIP_RENAME      — set to "1" to skip /rename keystroke
#   WORKFLOW_AGENT_SKIP_BRANCH_WARN — set to "1" to suppress mismatch warning
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_loader="${script_dir%/hooks}/scripts/_config.sh"
if [ -r "$config_loader" ]; then
  # shellcheck disable=SC1090
  . "$config_loader"
fi
fleet_helper="${script_dir%/hooks}/scripts/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"
# Identity token: $TMUX_PANE inside tmux, else cwd-based (works headless).
self_token="$(fleet_self_token 2>/dev/null || printf '%s' "${TMUX_PANE:-cwd:$PWD}")"

# --- Determine agent name ---
# Priority:
#   1. Session file's `name` field (set by `/rename`; persists across resumes).
#   2. WORKFLOW_AGENT_DEFAULT_BRANCH from .claude/workflow.config (if set).
#   3. Current git branch (sanitized).
#   4. cwd basename.
name=""
session_name=""
if [ -n "$claude_pid" ] && [ -f "$HOME/.claude/sessions/$claude_pid.json" ] && command -v jq >/dev/null 2>&1; then
  session_name=$(jq -r '.name // empty' "$HOME/.claude/sessions/$claude_pid.json" 2>/dev/null)
  name="$session_name"
fi
if [ -z "$name" ] && [ -n "${WORKFLOW_AGENT_DEFAULT_BRANCH:-}" ]; then
  name="$WORKFLOW_AGENT_DEFAULT_BRANCH"
  log "using WORKFLOW_AGENT_DEFAULT_BRANCH=$name"
fi
current_branch=$(git -C "$PWD" branch --show-current 2>/dev/null)
if [ -z "$name" ] && [ -n "$current_branch" ]; then
  name="$current_branch"
fi
[ -z "$name" ] && name="$(basename "$PWD")"

# Apply optional sed transform BEFORE sanitization, so user-provided
# patterns can match the raw branch (e.g. "s|^feature/||").
if [ -n "${WORKFLOW_AGENT_NAME_TRANSFORM:-}" ]; then
  name=$(printf '%s' "$name" | sed -E "$WORKFLOW_AGENT_NAME_TRANSFORM")
  log "applied transform: $name"
fi

# Sanitize: alnum/dash/underscore only. (No dots — dots are field delimiters
# in the message-mailbox filenames; a dot in a name would break drain parsing.)
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')

# Apply optional prefix (also sanitized so the joined name stays clean).
# Guard against double-application: a session whose name already carries the
# prefix (set by /rename, then re-derived from session_name on `claude
# --continue`) must NOT become <prefix><prefix>name (e.g. wf-todo-wf-todo-feat-1),
# which would fork a duplicate registry entry + corrupt the agent's identity.
if [ -n "${WORKFLOW_AGENT_NAME_PREFIX:-}" ]; then
  prefix=$(printf '%s' "$WORKFLOW_AGENT_NAME_PREFIX" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g')
  case "$name" in
    "$prefix"*) log "prefix already present, not re-applying: $name" ;;
    *) name="${prefix}${name}"; log "applied prefix: $name" ;;
  esac
fi

[ -z "$name" ] && name="agent"

# Sanitize current_branch the same way for consistent comparison.
current_branch_sanitized=$(printf '%s' "$current_branch" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')

# Sanitize the session's current name too, so we can tell whether the Claude
# session is ALREADY named correctly and skip a redundant /rename (the slow
# path runs on every start — including `--resume`, which carries the name
# forward — because the registry is keyed by the now-new PID).
session_name_sanitized=$(printf '%s' "$session_name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')

# --- Role context (injected at SessionStart via additionalContext) ---
# Different agent types get tailored startup instructions. The role is derived
# from the agent name; override per-agent with ~/.claude/agents/<name>.role (a
# single word). Role docs live in .claude/agent-roles/<role>.md and ship with
# the repo (so they propagate via merge-down). Only loaded on sessionstart.
# Keep these patterns IDENTICAL to role_of() in scripts/agent-fanout.sh.
resolve_role() {
  case "$1" in
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo coordinator ;;
    test|*-test|*-test-*|test-*)                                       echo test ;;
    review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*)           echo review ;;
    *)                                                                 echo feature ;;
  esac
}
role_context=""
if [ "$source" = "sessionstart" ]; then
  role=""
  [ -f "$HOME/.claude/agents/$name.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$name.role")"
  [ -z "$role" ] && role="$(resolve_role "$name")"
  role_file="$(cd "$(dirname "$0")/../agent-roles" 2>/dev/null && pwd)/$role.md"
  if [ -f "$role_file" ]; then
    role_context="$(cat "$role_file")"
    log "loaded role context: role=$role file=$role_file"
  else
    log "no role file for role=$role ($role_file)"
  fi
  # Base-branch alias: tell the model the configured base branch's NAME, so a
  # user saying "merge <branch>" / "push <branch>" routes to the base-* skills
  # even though the skills are branch-name-agnostic. Config-derived — renaming
  # the base branch never requires a prose edit.
  if [ -n "${WORKFLOW_BASE_BRANCH:-}" ]; then
    base_alias_note="This project's configured base branch is \`$WORKFLOW_BASE_BRANCH\` (WORKFLOW_BASE_BRANCH in .claude/workflow.config). When the user names it — \"merge $WORKFLOW_BASE_BRANCH\", \"push $WORKFLOW_BASE_BRANCH\", \"review $WORKFLOW_BASE_BRANCH\", \"test $WORKFLOW_BASE_BRANCH\" — they mean /base-merge, /base-push, /base-pr, /base-test against that branch."
    if [ -n "$role_context" ]; then
      role_context="$role_context

$base_alias_note"
    else
      role_context="$base_alias_note"
    fi
  fi
fi

log "name=$name current_branch=$current_branch"

# --- Base-branch tracking ---
# Persistent per-agent metadata at ~/.claude/agents/<name>; survives
# SessionEnd. Records the branch the agent was last registered with so
# the next SessionStart can warn if the worktree drifts to another branch.
#
# If WORKFLOW_AGENT_DEFAULT_BRANCH is set in the project config, that
# config IS the source of truth — we force-write it as the recorded
# base and the mismatch warning fires when the worktree isn't on it.
mkdir -p "$HOME/.claude/agents"
base_branch_file="$HOME/.claude/agents/$name"
mismatch_warning=""

# Sanitize the intended (config-pinned) base too, so comparisons match.
intended_base=""
if [ -n "${WORKFLOW_AGENT_DEFAULT_BRANCH:-}" ]; then
  intended_base=$(printf '%s' "$WORKFLOW_AGENT_DEFAULT_BRANCH" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
fi

if [ -n "$intended_base" ]; then
  # Config-pinned: always force-write the recorded base.
  printf '%s\n' "$intended_base" > "$base_branch_file"
  recorded_base="$intended_base"
  log "pinned base branch from config: $recorded_base"
elif [ -f "$base_branch_file" ]; then
  recorded_base=$(cat "$base_branch_file" 2>/dev/null)
else
  # First registration with no config pin: record current branch.
  if [ -n "$current_branch_sanitized" ]; then
    printf '%s\n' "$current_branch_sanitized" > "$base_branch_file"
    log "recorded base branch: $current_branch_sanitized"
  fi
  recorded_base="$current_branch_sanitized"
fi

if [ "${WORKFLOW_AGENT_SKIP_BRANCH_WARN:-}" != "1" ] \
   && [ -n "$recorded_base" ] \
   && [ -n "$current_branch_sanitized" ] \
   && [ "$recorded_base" != "$current_branch_sanitized" ]; then
  mismatch_warning="Agent '$name' was registered with base branch '$recorded_base' but the worktree is currently on '$current_branch'. If this is unintentional, switch back with: git checkout $recorded_base"
  log "BRANCH MISMATCH: registered=$recorded_base current=$current_branch_sanitized"
fi

# --- Context-lookup anchors (DX-jn-8-018) ---
# Record the agent's cwd and live transcript path so tools (e.g. agent-fanout
# `status`/`compact`) can find this agent's session transcript WITHOUT tmux. cwd
# derives the project dir (~/.claude/projects/<cwd|nonalnum→->); transcript_path
# (from the SessionStart payload) is the direct, heuristic-free pointer. Both are
# refreshed every SessionStart (incl. `--continue`).
printf '%s\n' "$PWD" > "$HOME/.claude/agents/$name.cwd"
transcript_path=$(printf '%s' "$stdin_payload" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$transcript_path" ]; then
  printf '%s\n' "$transcript_path" > "$HOME/.claude/agents/$name.transcript"
  log "recorded cwd=$PWD transcript=$transcript_path"
else
  log "recorded cwd=$PWD (no transcript_path in payload)"
fi

mkdir -p "$HOME/.claude/running-agents"
target="$HOME/.claude/running-agents/$name.$claude_pid"

# Helper: emit Claude Code's SessionStart additionalContext JSON to stdout.
# Combines the role context (loaded above) with any per-call warning so both
# reach the model in one SessionStart additionalContext payload.
emit_session_context() {
  local msg="$1"
  local combined="${role_context:-}"
  if [ -n "$msg" ]; then
    if [ -n "$combined" ]; then
      combined="$combined

$msg"
    else
      combined="$msg"
    fi
  fi
  if [ "$source" = "sessionstart" ] && [ -n "$combined" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg ctx "$combined" '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'
    else
      esc=${combined//\\/\\\\}; esc=${esc//\"/\\\"}; esc=${esc//$'\n'/\\n}
      printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$esc"
    fi
    log "emitted SessionStart additionalContext"
  fi
}

# Fast path: registry already correct.
if [ -f "$target" ] && [ "$(cat "$target" 2>/dev/null)" = "$self_token" ]; then
  log "exit: registry already correct ($target)"
  emit_session_context "$mismatch_warning"
  exit 0
fi

# Slow path: rebuild this name's entry (keyed by the identity token).
rm -f "$HOME/.claude/running-agents/$name".*
printf '%s\n' "$self_token" > "$target"
log "wrote $target -> $self_token"

# tmux cosmetics — only when tmux is actually drivable (headless: skipped).
if fleet_tmux_ok 2>/dev/null; then
  # tmux pane title (right granularity for split panes).
  tmux select-pane -t "$TMUX_PANE" -T "$name" 2>/dev/null || true

  # tmux window rename — only when it would actually change something.
  if window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null); then
    current_window_name=$(tmux display-message -t "$window_id" -p '#{window_name}' 2>/dev/null)
    if [ "$current_window_name" != "$name" ]; then
      tmux set-window-option -t "$window_id" automatic-rename off 2>/dev/null || true
      tmux rename-window -t "$window_id" "$name" 2>/dev/null || true
    fi
  fi

  # Type /rename into the prompt on the initial-startup path — but ONLY when the
  # session isn't already named correctly (avoids a no-op /rename re-firing on
  # every start/resume) and WORKFLOW_AGENT_SKIP_RENAME isn't "1".
  if [ "$source" = "sessionstart" ] && [ "${WORKFLOW_AGENT_SKIP_RENAME:-}" != "1" ] && [ "$session_name_sanitized" != "$name" ]; then
    nohup bash -c "
      sleep 2
      tmux send-keys -t '$TMUX_PANE' -l '/rename $name'
      tmux send-keys -t '$TMUX_PANE' Enter
    " </dev/null >/dev/null 2>&1 &
    log "scheduled /rename via send-keys"
  else
    log "skip /rename (source=$source skip=${WORKFLOW_AGENT_SKIP_RENAME:-} session='$session_name_sanitized' name='$name')"
  fi
else
  log "tmux unavailable — skipped pane/window title + /rename (headless registration)"
fi

emit_session_context "$mismatch_warning"
exit 0
