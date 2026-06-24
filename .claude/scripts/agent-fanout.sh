#!/bin/bash
# Fleet orchestration backing script for the /agent-fanout skill.
#
# Subcommands:
#   status                          Read-only fleet snapshot (incl. CTX% per agent).
#   merge-down [targeting]          Canned: tell peers to run `/base-merge down`.
#   send [targeting] --stdin <<BODY Message a targeted set (reuses agent-send.sh).
#   restart --yes [targeting]       Kill idle agents' claude, relaunch `claude --continue`.
#   compact --yes [--threshold N]   Inject `/compact` into idle agents at/above N% context.
#
# Targeting (all but status): --role feature|review|test|coordinator|all (default all) ·
#   --only name1,name2 (explicit set) · --exclude a,b · --threshold N (compact) · --dry-run.
# CTX% finds each agent's transcript via recorded transcript_path/cwd sidecars (tmux only as
# an optional fallback); window = $WORKFLOW_CTX_WINDOW or a model default (opus/sonnet-4.x→1M).
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
# shellcheck disable=SC1090
[ -r "$here/_fleet.sh" ] && . "$here/_fleet.sh"   # fleet_self_token/_tmux_ok/_alive/_find_self
BASE="${WORKFLOW_BASE_BRANCH:-main}"

# Keep these patterns IDENTICAL to resolve_role() in hooks/register-agent.sh —
# a divergence means status/targeting classify an agent differently from the
# role context it was booted with (e.g. "x-print" must NOT read as review).
role_of() { case "$1" in cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo coordinator;; test|*-test|*-test-*|test-*) echo test;; review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*) echo review;; *) echo feature;; esac; }
# Identity/liveness via the shared helper (tmux-optional); fall back inline if unsourced.
self_name() { fleet_find_self "$reg" 2>/dev/null; }
is_busy()  { local m="$HOME/.claude/agent-busy/$1"; [ -f "$m" ] && [ -n "$(find "$m" -mmin -5 2>/dev/null)" ]; }
pane_in_mode() { [ "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ]; }
alive() { fleet_alive "$1" "$2"; }

# --- Context usage (DX-jn-8-018) ----------------------------------------------
# Find an agent's live transcript WITHOUT requiring tmux. Precedence:
#   1) recorded transcript_path sidecar (direct)         2) recorded cwd → project dir
#   3) tmux pane_current_path → project dir (optional)   else: unknown.
_ctx_transcript() {  # name pane -> transcript path (empty if not resolvable)
  local name="$1" pane="$2" p cwd pd
  p="$(cat "$HOME/.claude/agents/$name.transcript" 2>/dev/null)"
  [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return; }
  cwd="$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)"
  if [ -z "$cwd" ] && [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    cwd="$(tmux display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  fi
  [ -n "$cwd" ] || return
  pd="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')"
  [ -d "$pd" ] || return
  ls -t "$pd"/*.jsonl 2>/dev/null | head -1
}

# Echo "pct raw" (e.g. "25 253k") for the agent's main-loop context, or nothing.
# Window: $WORKFLOW_CTX_WINDOW if set, else model table (opus/sonnet-4.x → 1M, else 200k).
ctx_info() {  # name pane
  local path; path="$(_ctx_transcript "$1" "$2")"; [ -n "$path" ] && [ -f "$path" ] || return
  tail -n 1200 "$path" 2>/dev/null | python3 -c '
import sys, os, json
ctx = 0; model = None
for line in sys.stdin:
    try: o = json.loads(line)
    except Exception: continue
    if o.get("isSidechain"): continue          # skip subagent turns — main loop only
    u = (o.get("message") or {}).get("usage")
    if not u: continue
    ctx = (u.get("input_tokens",0) or 0) + (u.get("cache_creation_input_tokens",0) or 0) + (u.get("cache_read_input_tokens",0) or 0)
    model = (o.get("message") or {}).get("model") or model
if not ctx: sys.exit(0)
env = os.environ.get("WORKFLOW_CTX_WINDOW","").strip()
if env.isdigit() and int(env) > 0:
    win = int(env)
else:
    m = model or ""
    win = 1000000 if ("opus-4" in m or "sonnet-4" in m) else 200000
pct = round(100 * ctx / win)
raw = "%dk" % round(ctx/1000) if ctx >= 1000 else str(ctx)
print("%d %s" % (pct, raw))
'
}

# "⚠"/"🔴" flag for a percentage (empty below 80).
ctx_flag() { if [ "${1:-0}" -ge 90 ] 2>/dev/null; then printf '🔴'; elif [ "${1:-0}" -ge 80 ] 2>/dev/null; then printf '⚠'; fi; }

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

ROLE=all; ONLY=""; EXCL=""; DRY=0; YES=0; STDIN=0; THRESH=80; EXTRA=()
parse() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --role) shift; ROLE="${1:-all}";;
      --only) shift; ONLY="${1:-}";;
      --exclude) shift; EXCL="${1:-}";;
      --threshold) shift; THRESH="${1:-80}";;
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
    printf '%-14s %-11s %-9s %-24s %-7s %s\n' NAME ROLE STATE BRANCH CTX PANE
    seen=" "
    for f in "$reg"/*; do
      [ -f "$f" ] || continue
      bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
      case "$seen" in *" $name "*) continue;; esac; seen="$seen$name "
      st=live; alive "$pid" "$pane" || st=STALE
      is_busy "$name" && st="$st/BUSY" || st="$st/idle"
      br="$(cat "$HOME/.claude/agents/$name" 2>/dev/null || echo '?')"
      behind="$(git rev-list --count "${br}..${BASE}" 2>/dev/null || echo '?')"
      ci="$(ctx_info "$name" "$pane")"; if [ -n "$ci" ]; then ctxd="$(ctx_flag "${ci%% *}")${ci%% *}%"; else ctxd='—'; fi
      printf '%-14s %-11s %-9s %-24s %-7s %s%s\n' "$name" "$(role_of "$name")" "$st" "$br (behind $behind)" "$ctxd" "$pane" "$([ "$name" = "$self" ] && echo '  <- you')"
    done
    echo "local $BASE @ $basesha   (CTX = main-loop context vs window; ⚠≥80% 🔴≥90%; window via WORKFLOW_CTX_WINDOW or model default)"
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
    if ! fleet_tmux_ok 2>/dev/null; then
      echo "restart needs tmux (it drives panes via send-keys) — tmux unavailable, skipping. Restart the agent manually." >&2; exit 0
    fi
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

  compact)
    if ! fleet_tmux_ok 2>/dev/null; then
      echo "compact needs tmux (it injects /compact via send-keys) — tmux unavailable, skipping. (A tmux-free compact would need the command-mailbox model; see DX-jn-8-019.)" >&2; exit 0
    fi
    targets="$(enumerate "$ROLE" "$ONLY" "$EXCL")"
    [ -n "$targets" ] || { echo "no live peers match (role=$ROLE only=$ONLY exclude=$EXCL)"; exit 1; }
    # Keep only agents at/above the context threshold; annotate each with pct + raw.
    cand=""
    while read -r name pid pane; do
      [ -n "$name" ] || continue
      ci="$(ctx_info "$name" "$pane")"
      if [ -z "$ci" ]; then echo "  skip $name — context unknown"; continue; fi
      pct="${ci%% *}"; raw="${ci#* }"
      if [ "$pct" -lt "$THRESH" ] 2>/dev/null; then echo "  skip $name — ${pct}% < ${THRESH}%"; continue; fi
      cand="$cand$name $pid $pane $pct $raw"$'\n'
    done <<EOF
$targets
EOF
    [ -n "$cand" ] || { echo "no agents at/above ${THRESH}% context."; exit 0; }
    echo "compact candidates (≥${THRESH}%):"; printf '%s' "$cand" | awk 'NF{print "  - "$1"  "$4"% ("$5")  pane "$3}'
    if [ "$DRY" = 1 ]; then echo "(dry-run — nothing compacted)"; exit 0; fi
    if [ "$YES" != 1 ]; then
      echo "REFUSING: compact needs --yes (the /agent-fanout skill passes it only after you confirm)." >&2; exit 3
    fi
    printf '%s' "$cand" | while read -r name pid pane pct raw; do
      [ -n "$name" ] || continue
      if is_busy "$name"; then echo "  SKIP $name — BUSY (mid-turn)"; continue; fi
      if pane_in_mode "$pane"; then echo "  SKIP $name — pane in copy-mode"; continue; fi
      tmux send-keys -t "$pane" -l "/compact"; tmux send-keys -t "$pane" Enter
      echo "  /compact -> $name (${pct}%)"
    done
    ;;

  *) echo "usage: agent-fanout.sh {status|merge-down|send|restart|compact} [--role R] [--only a,b] [--exclude a,b] [--threshold N] [--dry-run] [--yes]" >&2; exit 2;;
esac
