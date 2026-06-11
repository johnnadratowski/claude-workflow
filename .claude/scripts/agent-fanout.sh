#!/bin/bash
# Fleet orchestration backing script for the /agent-fanout skill.
#
# Subcommands:
#   status                          Read-only fleet snapshot (no side effects).
#   merge-down [targeting]          Canned: tell peers to run `/base-merge down`.
#   send [targeting] --stdin <<BODY Message a targeted set (reuses agent-send.sh).
#   restart --yes [targeting]       Kill idle agents' claude, relaunch `claude --continue`.
#
# Targeting (all but status): --role feature|review|test|coordinator|all (default all) ·
#   --only name1,name2 (explicit set) · --exclude a,b · --dry-run.
# Self is ALWAYS excluded. Roles derive from the agent name (matches resolve_role).
#
# SAFETY: `restart` is destructive (kills the live claude in each pane). It requires
# --yes AND only acts on IDLE agents (skips BUSY / copy-mode). The /agent-fanout SKILL
# passes --yes ONLY after explicit user confirmation in that turn — never blanket-run it.

set -u
reg="$HOME/.claude/running-agents"
here="$(cd "$(dirname "$0")" && pwd)"
SEND="$here/agent-send.sh"
# Load WORKFLOW_BASE_BRANCH (default main) for the merge-down body + behind-count.
# shellcheck disable=SC1090
[ -r "$here/_config.sh" ] && . "$here/_config.sh"
BASE="${WORKFLOW_BASE_BRANCH:-main}"

# Keep these patterns IDENTICAL to resolve_role() in hooks/register-agent.sh —
# a divergence means status/targeting classify an agent differently from the
# role context it was booted with (e.g. "x-print" must NOT read as review).
role_of() { case "$1" in cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo coordinator;; test|*-test|*-test-*|test-*) echo test;; review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*) echo review;; *) echo feature;; esac; }
self_name() { local f; for f in "$reg"/*; do [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "${TMUX_PANE:-}" ] && { basename "$f" | sed 's/\.[0-9]*$//'; return; }; done; }
is_busy()  { local m="$HOME/.claude/agent-busy/$1"; [ -f "$m" ] && [ -n "$(find "$m" -mmin -30 2>/dev/null)" ]; }
pane_in_mode() { [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ]; }
alive() { kill -0 "$1" 2>/dev/null && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$2"; }

enumerate() {  # args: role only_csv exclude_csv -> "name pid pane" per live peer (deduped, minus self)
  local want_role="$1" only="$2" excl="$3" self; self="$(self_name)"; shopt -s nullglob
  local seen=" "
  for f in "$reg"/*; do
    [ -f "$f" ] || continue
    local bn name pid pane; bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
    case "$seen" in *" $name "*) continue;; esac; seen="$seen$name "
    [ "$name" = "$self" ] && continue
    alive "$pid" "$pane" || continue
    case ",$excl," in *",$name,"*) continue;; esac
    [ -n "$only" ] && { case ",$only," in *",$name,"*) ;; *) continue;; esac; }
    [ "$want_role" != all ] && [ "$(role_of "$name")" != "$want_role" ] && continue
    printf '%s %s %s\n' "$name" "$pid" "$pane"
  done
}

ROLE=all; ONLY=""; EXCL=""; DRY=0; YES=0; STDIN=0; EXTRA=()
parse() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --role) shift; ROLE="${1:-all}";;
      --only) shift; ONLY="${1:-}";;
      --exclude) shift; EXCL="${1:-}";;
      --dry-run) DRY=1;;
      --yes) YES=1;;
      --stdin) STDIN=1;;
      *) EXTRA+=("$1");;
    esac; shift
  done
}

cmd="${1:-status}"; shift || true
parse "$@"

case "$cmd" in
  status)
    self="$(self_name)"; basesha="$(git rev-parse --short "$BASE" 2>/dev/null || echo '?')"; shopt -s nullglob
    printf '%-14s %-11s %-7s %-26s %s\n' NAME ROLE STATE BRANCH PANE
    seen=" "
    for f in "$reg"/*; do
      [ -f "$f" ] || continue
      bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
      case "$seen" in *" $name "*) continue;; esac; seen="$seen$name "
      st=live; alive "$pid" "$pane" || st=STALE
      is_busy "$name" && st="$st/BUSY" || st="$st/idle"
      br="$(cat "$HOME/.claude/agents/$name" 2>/dev/null || echo '?')"
      behind="$(git rev-list --count "${br}..${BASE}" 2>/dev/null || echo '?')"
      printf '%-14s %-11s %-7s %-26s %s%s\n' "$name" "$(role_of "$name")" "$st" "$br (behind $BASE $behind)" "$pane" "$([ "$name" = "$self" ] && echo '  <- you')"
    done
    echo "local $BASE @ $basesha"
    ;;

  merge-down|send)
    if [ "$cmd" = merge-down ]; then
      body="Fleet sync: local \`$BASE\` advanced. Please run \`/base-merge down\` to pick it up; if the down-merge conflicts, resolve it normally. Reply when done (or if blocked)."
    else
      [ "$STDIN" = 1 ] || { echo "send: pass --stdin and pipe the body via heredoc" >&2; exit 2; }
      body="$(cat)"
    fi
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    echo "recipients:"; echo "$targets" | awk '{print "  - "$1}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing sent)"; exit 0; fi
    echo "$targets" | while read -r name pid pane; do
      printf '%s' "$body" | "$SEND" "$name" --stdin >/dev/null 2>&1 && echo "  sent -> $name" || echo "  FAILED -> $name"
    done
    ;;

  restart)
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    echo "restart candidates:"; echo "$targets" | awk '{print "  - "$1" (pane "$3")"}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing restarted)"; exit 0; fi
    if [ "$YES" != 1 ]; then
      echo "REFUSING: restart needs --yes (the /agent-fanout skill passes it only after you confirm)." >&2; exit 3
    fi
    echo "$targets" | while read -r name pid pane; do
      if is_busy "$name"; then echo "  SKIP $name — BUSY (mid-turn)"; continue; fi
      if pane_in_mode "$pane"; then echo "  SKIP $name — pane in copy-mode"; continue; fi
      echo "  restarting $name (pid $pid, pane $pane) ..."
      tmux send-keys -t "$pane" C-c; sleep 1; tmux send-keys -t "$pane" C-c
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      if kill -0 "$pid" 2>/dev/null; then echo "    claude didn't exit on C-c; sending kill"; kill "$pid" 2>/dev/null; sleep 1; fi
      tmux send-keys -t "$pane" -l "claude --continue"; tmux send-keys -t "$pane" Enter
      ok=""; for _ in $(seq 1 30); do
        nf="$(ls "$reg/$name".* 2>/dev/null | head -1)"
        if [ -n "$nf" ] && [ "${nf##*.}" != "$pid" ] && [ "$(cat "$nf" 2>/dev/null)" = "$pane" ]; then ok=1; break; fi
        sleep 1
      done
      [ -n "$ok" ] && echo "    OK — $name back as $(basename "$nf")" || echo "    WARN — $name not re-registered yet; check pane $pane"
    done
    ;;

  *) echo "usage: agent-fanout.sh {status|merge-down|send|restart} [--role R] [--only a,b] [--exclude a,b] [--dry-run] [--yes]" >&2; exit 2;;
esac
