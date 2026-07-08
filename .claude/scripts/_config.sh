#!/bin/bash
# Source-only helper. Reads .claude/workflow.config (if present) from the
# git toplevel and exports the two settings the workflow scripts care about:
#
#   WORKFLOW_BASE_BRANCH   — the personal coordination branch (a branch off the
#                            trunk, NOT the trunk itself) other branches merge into
#                            and pull from. NO default: unset = solo mode (see
#                            WORKFLOW_FLEET_MODE); set it via /base-setup.
#   WORKFLOW_MAIN_PATH     — path to the canonical clone used as the anchor
#                            for transient worktrees. Default: git toplevel
#                            of the calling cwd.
#
# A project's .claude/workflow.config is just a shell snippet, e.g.:
#
#   WORKFLOW_BASE_BRANCH="trunk"
#   WORKFLOW_MAIN_PATH="$HOME/code/myproject"
#
# Existing env-var values win over the config file (so callers can override
# per-invocation without editing the file).

_workflow_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

# Snapshot exported WORKFLOW_*/AGENT_INBOX_GC_DAYS values BEFORE defaults and
# config so they can be re-applied after sourcing — the config file assigns
# plain `VAR="value"` lines, which would otherwise clobber a caller's
# per-invocation override and break the documented "env wins" contract.
_wf_overrides="$(env | LC_ALL=C grep -E '^(WORKFLOW_[A-Za-z0-9_]+|AGENT_INBOX_GC_DAYS)=' || true)"

# Defaults — overridden by the config file below; env overrides win last.
# The base branch is OPT-IN: a PERSONAL coordination branch off the trunk (never the trunk
# itself), configured via /base-setup into workflow.config.local. UNSET = solo mode — there is
# NO fleet coordination, so base-* skills disable and /todo + /afk fall back to plain git. So NO
# default here: a `main`/`master` default would wrongly coordinate work onto the shared trunk.
# Define-as-empty only so `set -u` consumers read "" instead of hitting an unbound variable.
: "${WORKFLOW_BASE_BRANCH:=}"
: "${WORKFLOW_MAIN_PATH:=$_workflow_root}"

if [ -f "$_workflow_root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$_workflow_root/.claude/workflow.config"
fi

# Per-clone overrides (gitignored, NOT shared). Sourced AFTER the committed
# config so an engineer can set per-machine values (e.g. WORKFLOW_TODO_NS) that
# differ from the repo default, and BEFORE the env re-apply so env still wins.
if [ -f "$_workflow_root/.claude/workflow.config.local" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$_workflow_root/.claude/workflow.config.local"
fi

# Env wins over config: re-apply anything that was already in the environment.
if [ -n "$_wf_overrides" ]; then
  while IFS= read -r _wf_line; do
    [ -n "$_wf_line" ] && export "${_wf_line%%=*}=${_wf_line#*=}"
  done <<WF_EOF
$_wf_overrides
WF_EOF
fi

# WORKFLOW_TODO_NS — per-clone/per-engineer TODO-ID namespace (cross-engineer
# collision guard; see the /todo skill's "ID allocation"). Precedence:
#   1. explicit knob (env, or .claude/workflow.config.local) — RECOMMENDED;
#   2. else derived from `git config user.email` — the FULL local-part, lowercased,
#      alnum-only (e.g. jane.doe@… → janedoe). Full, not truncated: a short cut
#      collides on common prefixes (john.smith / john.doe), which would remint the
#      very collision this guards against;
#   3. else "0" (CI / no git identity — matches the un-laned lane fallback).
if [ -z "${WORKFLOW_TODO_NS:-}" ]; then
  _wf_ns_email="$(git -C "$_workflow_root" config user.email 2>/dev/null || true)"
  if [ -n "$_wf_ns_email" ]; then
    WORKFLOW_TODO_NS="$(printf '%s' "${_wf_ns_email%@*}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  fi
fi
: "${WORKFLOW_TODO_NS:=0}"

# WORKFLOW_DOCS_URL — base URL of the local docs:dev server, for the /todo skill's clickable TODO
# links + its plan/TODO link output. Neutral default :4000; a consuming project overrides it
# per-clone in workflow.config.local (e.g. to a per-lane port).
: "${WORKFLOW_DOCS_URL:=http://localhost:4000}"

# WORKFLOW_TODO_AGENT — this agent's fleet id (cc | f<N> | pr<N> | test<N>), the per-worktree
# segment the /todo skill mints into new IDs — AREA-<NS>-<agentid>-NNN — so an id names WHICH agent
# made it. Resolved from the agent's registered name via fleet_agent_id (_fleet.sh); falls back to
# "0" when self can't be resolved (headless / CI / unregistered). A consuming project that derives a
# numeric worktree lane may instead fall this back to that lane (see the /todo ID-allocation notes).
# Computed in a subshell so sourcing _fleet.sh here doesn't leak its functions into the caller.
if [ -z "${WORKFLOW_TODO_AGENT:-}" ]; then
  WORKFLOW_TODO_AGENT="$(
    _f="$_workflow_root/.claude/scripts/_fleet.sh"
    [ -r "$_f" ] || exit 0
    # shellcheck disable=SC1090
    . "$_f"
    _self="$(fleet_find_self "$HOME/.claude/running-agents" 2>/dev/null || true)"
    [ -n "$_self" ] && fleet_agent_id "$_self"
  )"
fi
: "${WORKFLOW_TODO_AGENT:=0}"

# WORKFLOW_FLEET_MODE — 1 when a coordination base branch is configured (FLEET mode: base-*
# skills + agent comms are active), 0 when the base is unset (SOLO mode: base-* skills disable
# themselves, /todo + /afk fall back to plain git + prompting the user). Turned on by
# /base-setup, which creates the personal base branch and writes WORKFLOW_BASE_BRANCH into the
# gitignored workflow.config.local. Skills read this instead of re-checking the base themselves.
if [ -n "${WORKFLOW_BASE_BRANCH:-}" ]; then WORKFLOW_FLEET_MODE=1; else WORKFLOW_FLEET_MODE=0; fi

export WORKFLOW_BASE_BRANCH WORKFLOW_MAIN_PATH WORKFLOW_TODO_NS WORKFLOW_DOCS_URL WORKFLOW_TODO_AGENT WORKFLOW_FLEET_MODE
unset _workflow_root _wf_overrides _wf_line _wf_ns_email
