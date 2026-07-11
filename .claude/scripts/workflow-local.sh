#!/bin/bash
# workflow-local.sh — THE single writer of .claude/workflow.config.local (DX-jn-cc-014).
#
#   workflow-local.sh set  <repo> <KEY> <VALUE>       append-or-create; replace, never duplicate
#   workflow-local.sh seed <main-clone> <worktree>    copy into a worktree that has none
#
# WHY A SCRIPT AND NOT PROSE IN A SKILL: three skills write this file (base-initialize,
# base-setup, add-worktree). As SKILL.md prose each would re-implement the same `cat >>`, and —
# decisively — a shell test suite cannot invoke a skill, so the row that owns the propagation
# behavior would have to hand-copy the file itself: it would test the READER and pass even with
# the writer broken. One executable owner makes that row bite on the real writer.
#
# WHY .local AND NOT workflow.config: `.claude/workflow.config` is COMMITTED and shared. The
# values written here are machine-local (the tmux session name is whatever THIS terminal called
# its session). A machine-local value in the committed file is worse than an absent one — it
# looks configured, and every other engineer inherits a wrong value silently.
#
# The file is SOURCED as shell (_config.sh), so a malformed line does not merely lose one value:
# it makes the file unsourceable and silently breaks every workflow script in the clone (hooks
# run output-suppressed). Hence: values are quoted, shell-hostile values are REFUSED, and both
# verbs write through a temp file + mv -f so a failed write can never leave a truncated line.
set -uo pipefail

LOCAL_REL=".claude/workflow.config.local"

# Keys that are PER-WORKTREE, not per-engineer: they must NOT propagate from the main clone into a
# worktree, or every worktree silently inherits one clone's value. A new per-worktree knob MUST be
# added here — this list is the schema `seed` honors.
#
#   WORKFLOW_DOCS_URL    — the local docs server's port, offset per worktree.
#   WORKFLOW_TODO_AGENT  — the id segment the /todo skill mints into new TODO ids. Copying ONE
#                          agent's segment into every worktree makes every agent mint ids under the
#                          same segment — re-arming the exact id collision the segment exists to
#                          prevent, silently.
#
# (Contrast WORKFLOW_TODO_NS / WORKFLOW_BASE_BRANCH / WORKFLOW_MAIN_PATH: per-ENGINEER — identical
# in all of that engineer's worktrees, so they must propagate.)
PER_CLONE_KEYS="WORKFLOW_DOCS_URL WORKFLOW_TODO_AGENT"

_die() { echo "workflow-local: $*" >&2; exit 1; }

# A value lands in a sourced shell file, so anything that can break the parse (or execute) is
# refused outright — fail closed, the same discipline boot applies to manifest agent names.
# `/` is deliberately ALLOWED (paths and URLs are the common case), which is exactly why the
# replace path below must not be a naive sed with `/` delimiters.
_validate_value() {
  # NOTE the newline pattern is $'\n', NOT "$(printf '\n')" — command substitution strips trailing
  # newlines, so the latter collapses to the empty string and the pattern becomes `**`, which
  # matches EVERY value (it refuses even `main`). Caught by this file's own first row.
  case "$1" in
    *'"'*|*'$'*|*'`'*|*'\'*|*"'"*) return 1 ;;
    *$'\n'*)                       return 1 ;;
  esac
  return 0
}

_validate_key() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

cmd_set() {
  local repo="${1:-}" key="${2:-}" value="${3:-}" target tmp
  [ -n "$repo" ] && [ -n "$key" ] || _die "usage: set <repo> <KEY> <VALUE>"
  [ -d "$repo" ] || _die "set: '$repo' is not a directory"
  _validate_key "$key" || _die "set: invalid key '$key' (allowed: A-Za-z0-9_)"
  _validate_value "$value" || _die "set: value for $key contains a character that would break a sourced shell file (quote, \$, backtick, backslash, newline)"

  target="$repo/$LOCAL_REL"
  mkdir -p "$(dirname "$target")" || _die "set: cannot create $(dirname "$target")"
  tmp="$target.tmp.$$"

  # Replace an existing assignment (anchored, tolerating leading whitespace and `export`), else
  # append. Done with awk on a temp file: atomic, and immune to the `/` that sed would choke on.
  if [ -f "$target" ]; then
    awk -v k="$key" -v v="$value" '
      $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" { next }   # drop the old assignment
      { print }
      END { printf "%s=\"%s\"\n", k, v }
    ' "$target" > "$tmp" || { rm -f "$tmp"; _die "set: failed writing $tmp"; }
  else
    {
      printf '# Machine-local workflow config — gitignored, per-machine. Written by workflow-local.sh.\n'
      printf '%s="%s"\n' "$key" "$value"
    } > "$tmp" || { rm -f "$tmp"; _die "set: failed creating $tmp"; }
  fi
  mv -f "$tmp" "$target" || { rm -f "$tmp"; _die "set: failed installing $target"; }

  # VERIFY the write landed — a caller that ignores a silent no-op here would go on to seed a
  # .local that lacks the key into every agent worktree.
  #
  # FIXED-STRING, WHOLE-LINE (-qxF), never a regex: the value is user data and legitimately
  # contains regex metacharacters — `_validate_value` deliberately permits `/ ( ) * + ? .` and
  # spaces, because paths (`/Users/me/Google Drive (work)/proj`) and shell commands
  # (WORKFLOW_CELL_COMMAND is documented as one: `tail -f *.log`) are the normal case. Interpolated
  # into an ERE they stop matching the line we just wrote, so the check reports failure on a
  # PERFECTLY GOOD write — and the callers' "a non-zero aborts the phase" pin would turn that into
  # an aborted onboarding with .local already mutated. We control the written form exactly
  # (KEY="VALUE"), so match it literally.
  grep -qxF -- "$key=\"$value\"" "$target" \
    || _die "set: wrote $target but $key did not land — refusing to report success"
  echo "workflow-local: $key set in $target"
}

cmd_seed() {
  local main="${1:-}" wt="${2:-}" src dst tmp filter
  [ -n "$main" ] && [ -n "$wt" ] || _die "usage: seed <main-clone> <worktree>"
  # A bogus <main-clone> must REFUSE, not fall into the legitimate "source has no .local → nothing
  # to do, rc 0" branch below: that branch is indistinguishable from success, so a caller passing a
  # wrong path would ship a worktree with no .local and believe it was seeded.
  [ -d "$main" ] || _die "seed: main clone '$main' is not a directory"
  [ -d "$wt" ] || _die "seed: worktree '$wt' is not a directory"
  src="$main/$LOCAL_REL"
  dst="$wt/$LOCAL_REL"

  # No source: a project with no .local is legitimate (nothing machine-local configured yet).
  [ -f "$src" ] || { echo "workflow-local: no $src to seed from — nothing to do"; return 0; }
  # NEVER overwrite: the worktree's own .local is the engineer's, and may hold per-worktree values.
  [ -f "$dst" ] && { echo "workflow-local: $dst already exists — left untouched"; return 0; }

  mkdir -p "$(dirname "$dst")" || _die "seed: cannot create $(dirname "$dst")"
  tmp="$dst.tmp.$$"

  # Carry every key through EXCEPT the per-clone deny-list — unknown keys propagate (they are far
  # more likely engineer-level than clone-level, and an allow-list would silently drop them).
  # The match is ANCHORED and tolerates `export` + leading whitespace: a bare substring match
  # would let `export WORKFLOW_DOCS_URL=…` slip through and propagate the very value we exclude.
  filter="$(printf '%s' "$PER_CLONE_KEYS" | tr ' ' '|')"
  awk -v deny="$filter" '
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" deny ")=" { next }
    { print }
  ' "$src" > "$tmp" || { rm -f "$tmp"; _die "seed: failed writing $tmp"; }
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; _die "seed: failed installing $dst"; }
  [ -f "$dst" ] || _die "seed: $dst missing after the copy — refusing to report success"
  echo "workflow-local: seeded $dst from $src"
}

case "${1:-}" in
  set)  shift; cmd_set  "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  *)    echo "usage: workflow-local.sh <set <repo> <KEY> <VALUE> | seed <main-clone> <worktree>>" >&2; exit 2 ;;
esac
