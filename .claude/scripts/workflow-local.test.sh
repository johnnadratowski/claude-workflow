#!/bin/bash
# Tests for workflow-local.sh — the single writer of .claude/workflow.config.local.
# Hermetic: scratch dirs only, no tmux, no $HOME writes.
#
# The rows that matter most are the ones that would have been born-green if written lazily:
#   - `set` on a MISSING file must CREATE it (the base-initialize case: .local does not exist
#     there, so the sed-on-a-commented-line idiom the sibling skills use would silently no-op)
#   - `seed` must strip PER-CLONE keys, in their non-canonical `export`-prefixed form
#   - a failed write must leave the original byte-identical (atomicity)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/workflow-local.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: workflow-local.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
      else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi; }

REL=".claude/workflow.config.local"
echo "workflow-local.sh"

# ---------------------------------------------------------------- set
R="$(cd "$(mktemp -d)" && pwd -P)"
bash "$SCRIPT" set "$R" WORKFLOW_FLEET_HOME_SESSION main >/dev/null 2>&1; rc=$?
eq "set: CREATES .local when absent (base-initialize's case — a sed would no-op here)" "0" "$rc"
eq "set: …and the value is there, quoted" "1" "$(grep -c '^WORKFLOW_FLEET_HOME_SESSION="main"$' "$R/$REL")"

# replace, not duplicate — with a value containing `/`, which the refusal list ALLOWS and a
# naive sed-with-/-delimiters would choke on
bash "$SCRIPT" set "$R" WORKFLOW_MAIN_PATH /home/me/code/proj >/dev/null 2>&1
bash "$SCRIPT" set "$R" WORKFLOW_MAIN_PATH /home/me/code/other >/dev/null 2>&1
eq "set: replaces an existing key (never duplicates) — value containing '/'" "1" "$(grep -c '^WORKFLOW_MAIN_PATH=' "$R/$REL")"
eq "set: …and the NEW value won" "1" "$(grep -c '^WORKFLOW_MAIN_PATH="/home/me/code/other"$' "$R/$REL")"
eq "set: …and the untouched key survived" "1" "$(grep -c '^WORKFLOW_FLEET_HOME_SESSION=' "$R/$REL")"

# the export-prefixed form is an assignment too — replacing must not leave a duplicate behind
printf 'export WORKFLOW_TODO_NS="zz"\n' >> "$R/$REL"
bash "$SCRIPT" set "$R" WORKFLOW_TODO_NS ab >/dev/null 2>&1
eq "set: replaces an EXPORT-prefixed assignment (no duplicate left behind)" "1" "$(grep -c 'WORKFLOW_TODO_NS=' "$R/$REL")"

# the file must stay SOURCEABLE — an unsourceable .local silently breaks every workflow script
src_rc=0; ( . "$R/$REL" ) >/dev/null 2>&1 || src_rc=$?
eq "set: the file it writes is still sourceable" "0" "$src_rc"

# shell-hostile values are REFUSED (they would make the file unsourceable, or execute).
# The backslash and newline branches get their own inputs: `\` because awk -v processes escape
# sequences, and a real newline because the FIRST version of this validator matched newlines with
# "$(printf '\n')" — which command-substitution-strips to empty, collapsing the pattern to `**`
# and refusing EVERY value. Without an input that exercises the branch, deleting it stays green.
for bad in 'a"b' 'a$b' 'a`b`' "a'b" 'a\b' "$(printf 'a\nb')"; do
  before="$(cat "$R/$REL")"
  bash "$SCRIPT" set "$R" WORKFLOW_CELL_COMMAND "$bad" >/dev/null 2>&1; brc=$?
  eq "set: refuses a shell-hostile value [$bad]" "1" "$([ "$brc" -ne 0 ] && echo 1 || echo 0)"
  eq "set: …and left the file byte-identical" "1" "$([ "$before" = "$(cat "$R/$REL")" ] && echo 1 || echo 0)"
done

# a value with a SPACE is fine (it is quoted) — a session can legitimately be named `my project`
bash "$SCRIPT" set "$R" WORKFLOW_CELL_COMMAND "my tool" >/dev/null 2>&1
sp_rc=0; ( . "$R/$REL" ) >/dev/null 2>&1 || sp_rc=$?
eq "set: a spaced value is quoted, and the file still sources" "0" "$sp_rc"
eq "set: …and reads back whole" "my tool" "$( . "$R/$REL"; printf '%s' "$WORKFLOW_CELL_COMMAND" )"

# REGEX-METACHARACTER VALUES: these are the NORMAL case, not an edge case — a clone path can hold
# parens/spaces, and WORKFLOW_CELL_COMMAND is documented as a shell command (globs, pipes). The
# post-write verification must therefore be a FIXED-STRING whole-line match; interpolating the
# value into a regex makes a perfectly good write report FAILURE, and the skills' "a non-zero
# aborts the phase" pin would turn that into an aborted onboarding with .local already mutated.
for good in '/Users/me/Google Drive (work)/proj' 'tail -f *.log' 'a+b?c.d' '/path/with[brackets]'; do
  bash "$SCRIPT" set "$R" WORKFLOW_MAIN_PATH "$good" >/dev/null 2>&1; grc=$?
  eq "set: accepts a regex-metachar value and reports SUCCESS [$good]" "0" "$grc"
  eq "set: …and it round-trips through a source" "$good" "$( . "$R/$REL"; printf '%s' "$WORKFLOW_MAIN_PATH" )"
done

# a failed write leaves the original intact (atomicity — a truncated line would break the clone)
RO="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$RO/.claude"
bash "$SCRIPT" set "$RO" WORKFLOW_TODO_NS aa >/dev/null 2>&1
orig="$(cat "$RO/$REL")"
chmod 500 "$RO/.claude"
bash "$SCRIPT" set "$RO" WORKFLOW_TODO_NS bb >/dev/null 2>&1; wrc=$?
chmod 700 "$RO/.claude"
eq "set: refuses non-zero when the write cannot land" "1" "$([ "$wrc" -ne 0 ] && echo 1 || echo 0)"
eq "set: …and the original is byte-identical (atomic)" "1" "$([ "$orig" = "$(cat "$RO/$REL")" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------- seed
M="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$M/.claude"
W="$(cd "$(mktemp -d)" && pwd -P)"
cat > "$M/$REL" <<'EOF'
WORKFLOW_BASE_BRANCH="mybase"
WORKFLOW_TODO_NS="me"
WORKFLOW_DOCS_URL="http://localhost:4008"
  export WORKFLOW_DOCS_URL="http://localhost:4009"
WORKFLOW_TODO_AGENT="cc"
WORKFLOW_SOMETHING_NEW="future-knob"
EOF
bash "$SCRIPT" seed "$M" "$W" >/dev/null 2>&1; src=$?
eq "seed: copies into a worktree that has none" "0" "$src"
eq "seed: carries the engineer-level keys" "1" "$(grep -c '^WORKFLOW_BASE_BRANCH="mybase"$' "$W/$REL")"
eq "seed: carries an UNKNOWN key (carry-through, not an allow-list)" "1" "$(grep -c 'WORKFLOW_SOMETHING_NEW' "$W/$REL")"
eq "seed: STRIPS the per-worktree docs port" "0" "$(grep -c 'WORKFLOW_DOCS_URL' "$W/$REL")"
# WORKFLOW_TODO_AGENT is the id segment /todo mints into TODO ids. Copying ONE agent's segment into
# every worktree makes every agent mint under the same segment — re-arming, silently, the exact id
# collision that segment exists to prevent.
eq "seed: STRIPS the per-worktree TODO agent-id segment" "0" "$(grep -c 'WORKFLOW_TODO_AGENT' "$W/$REL")"
eq "seed: …but KEEPS the per-engineer TODO namespace" "1" "$(grep -c 'WORKFLOW_TODO_NS' "$W/$REL")"
# ^ that last row reddens on a blind `cp` AND on a substring matcher (which the export-prefixed,
#   leading-whitespace second line would slip straight through).

# never overwrite an existing .local — it is the engineer's, and may hold per-worktree values
W2="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$W2/.claude"
printf 'SENTINEL="keep-me"\n' > "$W2/$REL"
bash "$SCRIPT" seed "$M" "$W2" >/dev/null 2>&1
eq "seed: NEVER overwrites an existing .local (sentinel survives)" "1" "$(grep -c 'SENTINEL' "$W2/$REL")"
eq "seed: …and did not append to it either" "0" "$(grep -c 'WORKFLOW_BASE_BRANCH' "$W2/$REL")"

# no source .local → silent no-op, exit 0 (a project with none is legitimate)
M2="$(cd "$(mktemp -d)" && pwd -P)"; W3="$(cd "$(mktemp -d)" && pwd -P)"
bash "$SCRIPT" seed "$M2" "$W3" >/dev/null 2>&1; nrc=$?
eq "seed: no source .local → exit 0 (nothing to do)" "0" "$nrc"
eq "seed: …and creates nothing" "0" "$([ -f "$W3/$REL" ] && echo 1 || echo 0)"

# a BOGUS <main-clone> must REFUSE — not fall into the legitimate "no source .local → rc 0" branch,
# which is indistinguishable from success and would ship an unseeded worktree the caller believes
# is configured.
W5="$(cd "$(mktemp -d)" && pwd -P)"
bash "$SCRIPT" seed "/no/such/clone" "$W5" >/dev/null 2>&1; brc=$?
eq "seed: refuses a nonexistent main clone (never a silent no-op)" "1" "$([ "$brc" -ne 0 ] && echo 1 || echo 0)"

# copy failure → loud non-zero (a caller that swallows this ships a worktree with no .local)
W4="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$W4/.claude"; chmod 500 "$W4/.claude"
bash "$SCRIPT" seed "$M" "$W4" >/dev/null 2>&1; frc=$?
chmod 700 "$W4/.claude"
eq "seed: refuses non-zero when the copy cannot land" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
