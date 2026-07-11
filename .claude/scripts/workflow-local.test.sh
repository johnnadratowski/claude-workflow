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

# shell-hostile values are REFUSED (they would make the file unsourceable, or execute)
for bad in 'a"b' 'a$b' 'a`b`' "a'b"; do
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
WORKFLOW_SOMETHING_NEW="future-knob"
EOF
bash "$SCRIPT" seed "$M" "$W" >/dev/null 2>&1; src=$?
eq "seed: copies into a worktree that has none" "0" "$src"
eq "seed: carries the engineer-level keys" "1" "$(grep -c '^WORKFLOW_BASE_BRANCH="mybase"$' "$W/$REL")"
eq "seed: carries an UNKNOWN key (carry-through, not an allow-list)" "1" "$(grep -c 'WORKFLOW_SOMETHING_NEW' "$W/$REL")"
eq "seed: STRIPS the per-clone key" "0" "$(grep -c 'WORKFLOW_DOCS_URL' "$W/$REL")"
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

# copy failure → loud non-zero (a caller that swallows this ships a worktree with no .local)
W4="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$W4/.claude"; chmod 500 "$W4/.claude"
bash "$SCRIPT" seed "$M" "$W4" >/dev/null 2>&1; frc=$?
chmod 700 "$W4/.claude"
eq "seed: refuses non-zero when the copy cannot land" "1" "$([ "$frc" -ne 0 ] && echo 1 || echo 0)"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
