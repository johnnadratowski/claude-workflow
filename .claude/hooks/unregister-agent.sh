#!/bin/bash
# SessionEnd hook — removes this Claude session from ~/.claude/running-agents.
# Best-effort cleanup; senders also prune stale entries on send (PID-not-alive
# check), so this hook missing or failing isn't load-bearing.

set -u

cat >/dev/null 2>&1 || true

shopt -s nullglob 2>/dev/null || true
for f in "$HOME/.claude/running-agents/"*."$PPID"; do
  rm -f "$f"
done

exit 0
