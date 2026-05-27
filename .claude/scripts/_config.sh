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

# Defaults — overridden by env or config file below.
: "${WORKFLOW_BASE_BRANCH:=main}"
: "${WORKFLOW_MAIN_PATH:=$_workflow_root}"

if [ -f "$_workflow_root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$_workflow_root/.claude/workflow.config"
fi

export WORKFLOW_BASE_BRANCH WORKFLOW_MAIN_PATH
unset _workflow_root
