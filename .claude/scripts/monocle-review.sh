#!/bin/bash
# monocle-review.sh — workflow glue for sending review context to Monocle (DX-jn-8-017).
#
# Monocle reviews the uncommitted working-tree DIFF natively (and renders it
# properly). This script does the two things the agent can't get cleanly from the
# diff itself:
#
#   1. DETECT whether the Monocle engine is live for THIS repo (a clean, scriptable
#      probe — unlike the MCP connection, which flaps).
#   2. SEND the context artifacts that aren't in the diff (the TODO + its plan),
#      keyed by STABLE id so re-sends UPDATE in place instead of piling up.
#
# Retrieving the verdict (the blocking wait) is left to the normal Monocle path —
# the agent's MCP `get_feedback` (wait=true), the `/get-feedback-wait` command, or
# the on-stop hook — so a long human review doesn't run into a Bash-tool timeout.
# (`monocle review get-feedback --wait` exists too, for non-MCP contexts.)
#
# Usage:
#   monocle-review.sh available                 # exit 0 = engine live for this repo, 2 = not running
#   monocle-review.sh list <context> <ID>       # print the artifacts that WOULD be sent (no send)
#   monocle-review.sh send <context> <ID>       # send the context's artifacts (stable ids)
#
#   <context> ∈ keys of .claude/monocle-artifacts.json "contexts" (plan | todo | diff)
#   <ID>      = the TODO id (e.g. DX-jn-8-017); resolves docs/todos/<ID>.md (or completed/)
#              and the plan from that TODO's `plan:` frontmatter.
#
# Exit codes: 0 ok · 1 usage/resolution error · 2 Monocle engine not running.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
MONOCLE="${MONOCLE_BIN:-monocle}"
ARTIFACTS_JSON="$ROOT/.claude/monocle-artifacts.json"

_die() { echo "monocle-review: $*" >&2; exit 1; }

# --- detection ---------------------------------------------------------------
# `monocle review status` is a pure probe: it does NOT spawn an engine, and exits
# non-zero with "monocle is not running" when none is up for this repo. The repo's
# socket is derived from the working directory, so just run it in-repo.
mr_available() {
  "$MONOCLE" review status --json >/dev/null 2>&1
}

# --- artifact resolution -----------------------------------------------------
# Resolve the TODO file (active or completed) and the plan path from frontmatter.
_todo_file() {
  local id="$1"
  for p in "docs/todos/$id.md" "docs/todos/completed/$id.md"; do
    [ -f "$ROOT/$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# Emit, for the given context, one TSV line per resolvable artifact:
#   <abs-path>\t<stable-id>\t<type>\t<title>
# Missing files (e.g. a grandfathered TODO with no plan) are skipped with a warning.
_resolve() {
  local context="$1" id="$2"
  [ -f "$ARTIFACTS_JSON" ] || _die "missing $ARTIFACTS_JSON"
  local todo_rel plan_rel
  todo_rel="$(_todo_file "$id")" || _die "no TODO file for $id (looked in docs/todos and completed/)"
  plan_rel="$(awk -F': *' '/^plan:/ {sub(/^plan: */,""); print; exit}' "$ROOT/$todo_rel")"

  ROOT="$ROOT" ID="$id" TODO_REL="$todo_rel" PLAN_REL="$plan_rel" \
  python3 - "$ARTIFACTS_JSON" "$context" <<'PY'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
context = sys.argv[2]
root, ID = os.environ["ROOT"], os.environ["ID"]
todo_rel, plan_rel = os.environ["TODO_REL"], os.environ.get("PLAN_REL", "")
roles = cfg["roles"]
order = cfg["contexts"].get(context)
if order is None:
    sys.stderr.write("monocle-review: unknown context '%s' (have: %s)\n" % (context, ", ".join(cfg["contexts"])))
    sys.exit(1)

def expand(tmpl):
    return tmpl.replace("{ID}", ID).replace("{plan}", plan_rel).replace("{todo}", todo_rel)

for role in order:
    spec = roles.get(role)
    if not spec:
        sys.stderr.write("monocle-review: context '%s' names unknown role '%s'\n" % (context, role)); continue
    rel = expand(spec["path"])
    if not rel:
        sys.stderr.write("monocle-review: role '%s' unresolved (no path) — skipping\n" % role); continue
    ap = os.path.join(root, rel)
    if not os.path.isfile(ap):
        sys.stderr.write("monocle-review: %s not found at %s — skipping\n" % (role, rel)); continue
    print("\t".join([ap, expand(spec["id"]), spec.get("type", "md"), expand(spec.get("title", role))]))
PY
}

# --- commands ----------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  available)
    if mr_available; then echo "monocle: engine live for this repo"; exit 0
    else echo "monocle: not running for this repo"; exit 2; fi
    ;;
  list)
    [ $# -eq 2 ] || _die "usage: monocle-review.sh list <context> <ID>"
    _resolve "$1" "$2"
    ;;
  send)
    [ $# -eq 2 ] || _die "usage: monocle-review.sh send <context> <ID>"
    mr_available || { echo "monocle: not running — nothing sent (fall back to git diff / peer review)" >&2; exit 2; }
    # Resolve up front so a hard error (unknown context, no TODO file) fails the
    # whole command rather than being swallowed inside the loop's subshell.
    resolved="$(_resolve "$1" "$2")"
    sent=0
    while IFS=$'\t' read -r path id type title; do
      [ -n "$path" ] || continue
      "$MONOCLE" review send-artifact --title "$title" --file "$path" --type "$type" --id "$id" >/dev/null
      echo "  → sent $title  (id=$id)"
      sent=$((sent+1))
    done <<< "$resolved"
    [ "$sent" -gt 0 ] && echo "monocle: $sent artifact(s) sent/updated for context '$1' ($2)" || echo "monocle: no artifacts resolved for '$1' ($2)"
    ;;
  *)
    _die "usage: monocle-review.sh {available|list|send} [<context> <ID>]"
    ;;
esac
