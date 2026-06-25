#!/bin/bash
# .claude/scripts/statusline-todo.sh
#
# ccstatusline `custom-command` widget: prints "▸ <ID>" = the in-progress TODO in this
# worktree (the file-per-TODO ledger under docs/todos/). If more than one is
# in-progress, shows the first plus a "+N" overflow count. Silent (exit 0, no output)
# when nothing is in-progress or there's no docs/todos/ — harmless in a non-TODO repo.

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
todos="$root/docs/todos"
[ -d "$todos" ] || exit 0

# One grep over the active TODO files (completed/ is a subdir and excluded by the glob).
shopt -s nullglob
files=("$todos"/*.md)
[ ${#files[@]} -gt 0 ] || exit 0

ids=()
for f in $(grep -l '^status:[[:space:]]*in-progress' "${files[@]}" 2>/dev/null); do
  ids+=("$(basename "$f" .md)")
done

n=${#ids[@]}
if [ "$n" -eq 0 ]; then
  printf '▸ <none>'
elif [ "$n" -eq 1 ]; then
  printf '▸ %s' "${ids[0]}"
else
  printf '▸ %s +%s' "${ids[0]}" "$((n - 1))"
fi
exit 0
