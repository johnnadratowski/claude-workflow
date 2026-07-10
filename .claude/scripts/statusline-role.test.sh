#!/bin/bash
# Self-contained tests for statusline-role.sh.  Run: bash .claude/scripts/statusline-role.test.sh
#
# Hermetic: a throwaway $HOME (never touches the real registry / sidecars) and fixture
# worktree dirs outside any git repo (so the lane lookup stays silent and the badge is
# just the role label).
#
# Locks in the DX-jn-cc-007 statusline hardening:
#   - a LIVE registration beats an alphabetically-earlier stale sidecar (the `4afe6cdd`
#     crash-debris shadow that mislabeled the coordinator `feat` on 2026-07-10)
#   - a DEAD registration does not win — self-ID falls back to the sidecar glob
#   - the sidecar fallback still resolves unregistered/headless sessions
#   - a non-agent cwd stays silent (exit 0, no output)

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/statusline-role.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: statusline-role.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
  else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi
}

FAKEHOME="$(cd "$(mktemp -d)" && pwd -P)"
T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup(){ rm -rf "$FAKEHOME" "$T"; }
trap cleanup EXIT INT TERM

mkdir -p "$FAKEHOME/.claude/running-agents" "$FAKEHOME/.claude/agents" "$T/wt" "$T/wt2"

# A provably dead pid: a subshell that has already been reaped.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null

# run <cwd> — the widget reads $PWD, $HOME, and drains stdin.
run(){ (cd "$1" && HOME="$FAKEHOME" bash "$SCRIPT" </dev/null); }

echo "statusline-role.sh"

# THE 2026-07-10 REPRO: crash debris — an alphabetically-earlier sidecar pointing at the
# coordinator's cwd, no live registration of its own. The pre-hardening picker took the
# first glob match and badged the coordinator `feat`.
printf '%s\n' "$T/wt" > "$FAKEHOME/.claude/agents/4afe6cdd.cwd"
printf '%s\n' "$T/wt" > "$FAKEHOME/.claude/agents/john-cc.cwd"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/john-cc.$$"
eq "a LIVE registration beats alphabetically-earlier stale debris (the 4afe6cdd shadow)" \
   "cc" "$(run "$T/wt")"

# Same debris, but the registration is DEAD → the live pass yields nothing and the
# sidecar-glob fallback (first match) is the documented behavior.
rm -f "$FAKEHOME/.claude/running-agents/john-cc.$$"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/john-cc.$DEADPID"
eq "a DEAD registration does not win — falls back to the sidecar glob (first match)" \
   "feat" "$(run "$T/wt")"

# Unregistered/headless: no running-agents entry at all — the fallback still resolves.
printf '%s\n' "$T/wt2" > "$FAKEHOME/.claude/agents/zz-9.cwd"
eq "sidecar fallback still resolves an unregistered agent" "feat" "$(run "$T/wt2")"

# .role override wins over the name pattern, on the live path too.
printf 'cwd:%s\n' "$T/wt2" > "$FAKEHOME/.claude/running-agents/zz-9.$$"
printf 'review\n' > "$FAKEHOME/.claude/agents/zz-9.role"
eq "the .role override applies on the live-registration path" "rev" "$(run "$T/wt2")"
rm -f "$FAKEHOME/.claude/agents/zz-9.role" "$FAKEHOME/.claude/running-agents/zz-9.$$"

# A cwd no agent claims: silent (exit 0, empty output) — the widget must not guess.
mkdir -p "$T/nobody"
out="$(run "$T/nobody")"; rc=$?
eq "an unclaimed cwd prints nothing" "" "$out"
eq "…and exits 0"                    "0" "$rc"

# A running-agents entry whose name has NO .cwd sidecar must not blow up the live pass —
# john-cc's live registration (restored) must still win past it. `aa-no-sidecar` sorts
# before john-cc, so a picker that trips on the missing sidecar would misresolve or die.
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/aa-no-sidecar.$$"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/john-cc.$$"
eq "a registration with no .cwd sidecar is skipped, not fatal" "cc" "$(run "$T/wt")"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
