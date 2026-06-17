#!/bin/sh
# Register the per-clone git merge driver(s) this repo's .gitattributes reference.
# git refuses to auto-run a committed merge driver (code-exec safety), so the
# driver must be configured locally — run this once per clone (wire it into your
# project's own prepare/postinstall step). Config lives in the shared `.git`
# common dir, so it also applies to the transient worktrees the fleet merge
# helpers create.
#
# `merge.ours.driver true`: the `true` command always exits 0, leaving the
# result file as our version — i.e. `merge=ours` in .gitattributes keeps the
# current branch's copy of a generated artifact instead of conflicting. This is
# the documented git idiom (see gitattributes(5)); `ours` here is a *driver*,
# unrelated to the `-s ours` merge *strategy*. `true` is a shell builtin, so this
# works in a bare worktree with no project dependencies installed.
#
# Idempotent and silent. Never fails: a missing git or a bare checkout just
# leaves the driver unregistered (merges fall back to normal, possibly-
# conflicting behavior — safe).
set -e
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git config merge.ours.driver true
exit 0
