#!/bin/bash
# Rename this Claude agent. Updates both the registry file and the tmux window.
#
# Usage: agent-rename.sh <new-name>

set -u

[ "$#" -lt 1 ] && { echo "usage: $(basename "$0") <new-name>" >&2; exit 2; }
new_name="$1"

if [ -z "${TMUX_PANE:-}" ]; then
  echo "not running inside tmux — \$TMUX_PANE unset; cannot identify self" >&2
  exit 1
fi

# Self-heal the registry first (idempotent fast-path no-op if already
# correct). Defends against the case where SessionStart didn't fire on
# `claude --resume` and the existing entry is stale.
hook_dir="$(cd "$(dirname "$0")/../hooks" 2>/dev/null && pwd)"
if [ -x "$hook_dir/register-agent.sh" ]; then
  "$hook_dir/register-agent.sh" rename-selfheal </dev/null >/dev/null 2>&1 || true
fi

# Sanitize new name same as register-agent.sh
new_name=$(printf '%s' "$new_name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
[ -z "$new_name" ] && { echo "new name sanitized to empty string — pick something with alnum chars" >&2; exit 2; }

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg" >&2; exit 1; }

# Discover self via $TMUX_PANE
self_file=""
shopt -s nullglob
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ]; then
    self_file="$f"
    break
  fi
done
if [ -z "$self_file" ]; then
  echo "this agent isn't registered" >&2
  exit 1
fi

old_name=$(basename "$self_file")
old_name="${old_name%.*}"
pid="$(basename "$self_file")"
pid="${pid##*.}"

if [ "$old_name" = "$new_name" ]; then
  echo "already named '$new_name' — nothing to do"
  exit 0
fi

# Wipe any conflicting <new_name>.* entries (overwrite policy)
for f in "$reg/$new_name".*; do
  [ -f "$f" ] && rm -f "$f"
done

mv "$self_file" "$reg/$new_name.$pid"

# --- Rename the base branch + persistent base-branch file ---
# The registry file at ~/.claude/agents/<name> records the agent's
# "home" git branch. Move it to the new name, and try to rename the
# local git branch to match.
agents_dir="$HOME/.claude/agents"
mkdir -p "$agents_dir"
base_branch=""
if [ -f "$agents_dir/$old_name" ]; then
  base_branch=$(cat "$agents_dir/$old_name" 2>/dev/null)
fi

git_rename_result="no-op"
if [ -n "$base_branch" ] && git -C "$PWD" rev-parse --verify "$base_branch" >/dev/null 2>&1; then
  # The recorded base branch exists locally — try to rename it.
  if git -C "$PWD" branch -m "$base_branch" "$new_name" 2>/dev/null; then
    git_rename_result="renamed git branch $base_branch -> $new_name"
  else
    git_rename_result="git branch rename failed ($base_branch -> $new_name); branch may already exist or be checked out elsewhere"
  fi
else
  # No recorded base — fall back to renaming whatever we're currently on.
  current_branch=$(git -C "$PWD" branch --show-current 2>/dev/null)
  if [ -n "$current_branch" ] && [ "$current_branch" != "$new_name" ]; then
    if git -C "$PWD" branch -m "$new_name" 2>/dev/null; then
      git_rename_result="renamed current git branch $current_branch -> $new_name"
    else
      git_rename_result="git branch rename failed ($current_branch -> $new_name); branch may already exist"
    fi
  fi
fi

# Persist the new base branch name.
rm -f "$agents_dir/$old_name"
printf '%s\n' "$new_name" > "$agents_dir/$new_name"

# --- Migrate the durable mailbox + clear the stale busy marker ---
# Both are keyed by agent name. After this rename our Stop-drain reads
# ~/.claude/agent-inbox/<new_name>/, so any message a peer already staged under
# <old_name> would be stranded and eventually GC'd UNREAD — the exact silent loss
# the durable mailbox exists to prevent. Move them so nothing INBOUND is lost.
# (uuid-prefixed filenames make collisions with existing <new_name> mail
# impossible.) Only reached because old_name != new_name (guarded above).
#
# We deliberately do NOT touch messages we SENT to other agents: those live under
# the RECIPIENT's inbox as <recipient>/<uuid>.<old_name>.<kind>.txt, may be
# unprocessed, and are the recipient's to drain — deleting them would lose
# information. They aren't under our own old mailbox dir, so this block can't.
inbox="$HOME/.claude/agent-inbox"
migrated=0
if [ -d "$inbox/$old_name" ]; then
  mkdir -p "$inbox/$new_name"
  # Migrate, then re-scan: a message racing into <old_name>/ between a single glob
  # expansion and the rmdir would be missed (stranded → GC'd unread). Re-pass a few
  # times so a straggler is caught; rmdir only succeeds once <old_name>/ is truly
  # empty, which is the loop's exit. Bounded (won't spin on a pathological flood).
  for _ in 1 2 3 4 5; do
    for m in "$inbox/$old_name"/*; do   # nullglob (set above) → skipped if empty
      [ -e "$m" ] || continue
      mv -f "$m" "$inbox/$new_name/" && migrated=$((migrated + 1))
    done
    rmdir "$inbox/$old_name" 2>/dev/null && break   # empty → removed → done
  done
fi
# Busy marker is ephemeral + name-keyed; mark-busy re-stamps <new_name> on our
# next tool call, so just clear the stale leftover.
rm -f "$HOME/.claude/agent-busy/$old_name"

# Set the tmux pane title (right granularity — survives split-pane setups).
tmux select-pane -t "$TMUX_PANE" -T "$new_name" 2>/dev/null || true

# Also rename the window for convenience on single-pane windows.
if window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null); then
  tmux set-window-option -t "$window_id" automatic-rename off 2>/dev/null || true
  tmux rename-window -t "$window_id" "$new_name" 2>/dev/null || true
fi

# Also rename the Claude session itself via its built-in /rename slash
# command. We're inside the running session, so just type it into our
# own prompt — it'll fire on the next turn.
tmux send-keys -t "$TMUX_PANE" -l "/rename $new_name"
tmux send-keys -t "$TMUX_PANE" Enter

echo "renamed: $old_name -> $new_name (registry + tmux + Claude session)"
echo "git: $git_rename_result"
echo "base branch tracked at: $agents_dir/$new_name"
echo "mailbox: migrated $migrated inbound message(s) $old_name -> $new_name; stale busy marker cleared (outbound messages to peers left untouched)"
