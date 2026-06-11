#!/bin/bash
# Source-only helper. Reads .claude/workflow.config (if present) from the
# git toplevel and exports the two settings the workflow scripts care about:
#
#   WORKFLOW_BASE_BRANCH   — the shared "trunk" branch other branches merge
#                            into and pull from. Default: main.
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
: "${WORKFLOW_BASE_BRANCH:=main}"
: "${WORKFLOW_MAIN_PATH:=$_workflow_root}"

if [ -f "$_workflow_root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$_workflow_root/.claude/workflow.config"
fi

# Env wins over config: re-apply anything that was already in the environment.
if [ -n "$_wf_overrides" ]; then
  while IFS= read -r _wf_line; do
    [ -n "$_wf_line" ] && export "${_wf_line%%=*}=${_wf_line#*=}"
  done <<WF_EOF
$_wf_overrides
WF_EOF
fi

export WORKFLOW_BASE_BRANCH WORKFLOW_MAIN_PATH
unset _workflow_root _wf_overrides _wf_line
