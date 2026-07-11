#!/bin/bash
# Shared fleet identity/liveness helpers (DX-jn-8-019). Source-only.
#
# The fleet keys each agent by an IDENTITY TOKEN so it works with OR without tmux:
#   - inside tmux  → the token is $TMUX_PANE (e.g. "%3")
#   - headless     → the token is "cwd:<absolute-cwd>" (one agent per worktree here)
# The registry file ~/.claude/running-agents/<name>.<pid> stores this token; self-id
# matches it; liveness is pid-based, with a tmux pane-check only when the token is a pane.
#
# This makes tmux OPTIONAL: registration, self-identification, mailbox delivery/drain,
# busy-marking and status all work headless. Only live remote-drive (send-keys nudge,
# restart, compact, rename) needs tmux — callers gate those on fleet_tmux_ok and skip
# gracefully when it's absent.

# Identity token for THIS process.
fleet_self_token() {
  if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; else printf 'cwd:%s' "$PWD"; fi
}

# True when tmux can actually be driven (inside a pane AND the binary exists).
fleet_tmux_ok() { [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; }

# fleet_alive <pid> <token> — pid must be alive; if the token is a tmux pane, the pane
# must still exist (best-effort — a missing tmux binary doesn't fail a pane token, since
# we can't disprove liveness without it).
fleet_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$2" in
    %*) command -v tmux >/dev/null 2>&1 && ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$2" && return 1 ;;
  esac
  return 0
}

# fleet_find_self <registry-dir> — echo the name whose registry entry matches our token.
fleet_find_self() {
  local d="$1" tok f; tok="$(fleet_self_token)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$tok" ] && { basename "$f" | sed 's/\.[0-9]*$//'; return 0; }
  done
  return 1
}

# fleet_busy <name> — a fresh busy marker (~/.claude/agent-busy/<name>, touched within
# 5 min) means the agent is mid-turn. THE canonical predicate (DX-jn-cc-010/014).
#
# agent-fanout.sh, agent-send.sh, inbox-watcher.sh and statusline-fleet.sh all DELEGATE here
# (DX-jn-cc-011). Each keeps an inline copy only as a FALLBACK for a clone with no _fleet.sh, and
# each guards with `if command -v fleet_busy` — never `&& fleet_busy || inline`, in which the
# inline copy would run on every not-busy answer and the compound would be `fleet_busy OR inline`
# (two live predicates, biased toward "busy" — the direction that strands nudges). An undefined
# function would instead fail OPEN (busy reads as idle → duplicate nudges), which is why the
# fallback exists at all.
#
# NOTE the failure direction: an unreadable marker dir or a failed find reads as IDLE — right for
# status display, fail-OPEN for a kill gate. fleet-layout.sh's _down_busy wraps this with
# fail-closed unknown handling; use that (not this) to gate anything destructive.
fleet_busy() {
  local m="$HOME/.claude/agent-busy/$1"
  [ -f "$m" ] && [ -n "$(find "$m" -mmin -5 2>/dev/null)" ]
}

# fleet_resolve_role <name> — canonical agent-name → role classifier
# (coordinator|test|review|feature). THE single source of these name patterns;
# register-agent.sh's resolve_role() and agent-fanout.sh's role_of() delegate here so
# status/targeting/role-context can never classify an agent differently. Pure pattern
# match — callers that ALSO honor a per-agent ~/.claude/agents/<name>.role override
# (register-agent.sh, agent-rename.sh, statusline-role.sh) apply that override first and
# only fall back to this.
fleet_resolve_role() {
  case "$1" in
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo coordinator ;;
    test|*-test|*-test-*|test-*)                                       echo test ;;
    review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*)           echo review ;;
    *)                                                                 echo feature ;;
  esac
}

# fleet_agent_id <name> — the agent's short fleet id: cc | f<N> | pr<N> | test<N>. Used as the
# per-worktree segment of a TODO id (AREA-<NS>-<agentid>-NNN) in place of the numeric lane, so
# an id names WHICH agent minted it (DX-jn-8-032). Role from fleet_resolve_role; instance number
# = the trailing digits of the name, defaulting to 1 when the role has instances but the name
# carries none (pr → pr1). Coordinator is singular → no number (cc). Output is always
# [a-z0-9]+ (id-segment safe, no dashes).
#
# UNIQUENESS is convention-dependent (unlike the numeric lane, which was structurally unique per
# worktree): the id must be distinct across an engineer's CONCURRENT worktrees, since it's the
# per-(area,NS,agentid) sequence's collision guard. So **same-role agents MUST have distinct
# trailing numbers** (feature-1/feature-2, pr-1/pr-2) — two review agents both named without a
# number would both resolve to pr1. A fleet that can't guarantee this should set
# WORKFLOW_TODO_AGENT to the numeric lane (structurally unique) or leave it to fall back there.
fleet_agent_id() {
  local name="$1" role num
  role="$(fleet_resolve_role "$name")"
  num="$(printf '%s' "$name" | grep -oE '[0-9]+$' 2>/dev/null || true)"
  case "$role" in
    coordinator) printf 'cc' ;;
    feature)     printf 'f%s'    "${num:-1}" ;;
    review)      printf 'pr%s'   "${num:-1}" ;;
    test)        printf 'test%s' "${num:-1}" ;;
    *)           printf 'f%s'    "${num:-1}" ;;  # unreachable (role is exhaustive) — id-safe default
  esac
}

# fleet_manifest_path — echo the machine-local worktrees-manifest path (DX-jn-cc-014).
# THE single resolver: fleet-layout's boot/down, statusline-role's lane fallback, and any
# consuming project's config all route through here rather than hardcoding a path (one
# identity, one pipeline).
#
# WORKFLOW_WORKTREES_MANIFEST (env, or workflow.config[.local]) wins. Otherwise the default
# derives from the MAIN CLONE's basename via the shared git common dir — worktree-invariant
# by construction, since a linked worktree's own toplevel basename differs per worktree and
# would fork the default (myproject → ~/.config/myproject-worktrees.json, from every worktree).
#
# Return status is a CONTRACT: resolvable → 0 + the path on stdout; unresolvable (not a repo,
# degenerate basename) → non-zero + NO output. Callers that mutate (boot/down) treat a failed
# resolution as the same loud refusal as a missing manifest; display-only callers (statusline)
# degrade silently. NOTE: in a bare repo the common dir has no worktree parent, so the
# derivation names the bare dir's parent — harmless here (no fleet runs from a bare repo).
fleet_manifest_path() {
  if [ -n "${WORKFLOW_WORKTREES_MANIFEST:-}" ]; then
    printf '%s' "$WORKFLOW_WORKTREES_MANIFEST"; return 0
  fi
  local common base
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  base="$(basename "$(dirname "$common")")"
  case "$base" in ''|'/'|'.') return 1 ;; esac
  printf '%s' "$HOME/.config/${base}-worktrees.json"
}
