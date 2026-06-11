---
name: agent-fanout
description: Orchestrate the agent fleet — show fleet status, fan a message or canned action out to a targeted set of peers (by role), and optionally force-restart idle agents (kill the pane's claude, relaunch with `claude --continue` to preserve context). Backed by `.claude/scripts/agent-fanout.sh` (one allow-listed command per action). High blast-radius; every fan-out needs explicit user authorization and every restart is confirmed first. Use for "show me the fleet", "tell the feature agents to merge down", "restart the test agent".
---

# agent-fanout — fleet orchestration

A higher-level wrapper over `/agent-send` / `/agent-broadcast` that knows the fleet's
**roles** (feature / review / test / coordinator — derived from agent names the same way
`register-agent.sh` does) so you can target a fan-out, see the fleet before acting, and
force-restart agents safely.

This is **high blast-radius**. Two hard gates:

- **Message fan-outs** need the user to have asked for *this* fan-out in the current turn
  (same rule as `/agent-broadcast`). If you merely think one would help, propose it with
  `status` / `--dry-run` and let the user approve.
- **Restarts ALWAYS ask first** — never kill+relaunch an agent without an explicit confirmation
  in this turn, even when relaying a coordinator instruction.

## Backing script

The mechanics live in **`.claude/scripts/agent-fanout.sh`** — one allow-listed command per
action, so you don't re-prompt on ad-hoc bash. Subcommands:

```
.claude/scripts/agent-fanout.sh status
.claude/scripts/agent-fanout.sh merge-down [--role R] [--exclude a,b] [--dry-run]
.claude/scripts/agent-fanout.sh send  [--role R] [--only a,b] [--exclude a,b] [--dry-run] --stdin <<'BODY' … BODY
.claude/scripts/agent-fanout.sh restart --yes [--role R] [--only a,b] [--exclude a,b] [--dry-run]
```

The script always excludes self, idle-gates `restart` (skips BUSY / copy-mode panes), and
relaunches with `claude --continue` (no session-id needed — it resumes the pane's latest
conversation). **`restart` refuses to run without `--yes`** — the human gate below decides when
to pass it; the allow-list removes the bash prompt, NOT the confirmation.

## Modes

```
/agent-fanout status                              # read-only fleet snapshot (no auth needed)
/agent-fanout msg --role <r> --stdin <<'BODY'…    # fan a message out to a role/set
/agent-fanout merge-down [--role all]             # canned: peers run /base-merge down
/agent-fanout restart [--role <r>|<names>]        # idle-gated, confirmed, claude --continue
```

Targeting flags (all modes): `--role feature|review|test|coordinator|all` · `--only name1,name2`
explicit list · `--exclude a,b` · `--dry-run`.

Roles are derived from the agent name: `*-test*`/`test-*`→test, `*-pr*`/`pr-*`/`*-review*`→review,
`cc`/`*-cc`/`coordinator`→coordinator, else feature (matches `register-agent.sh`'s `resolve_role`).
**You are never a target of your own fan-out** (self is excluded by `$TMUX_PANE`).

## Mode: `status` (read-only — start here)

Enumerate the registry and print a table. No authorization needed; do this before any fan-out so
you (and the user) see who's live, busy, and on what branch.

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"   # for $WORKFLOW_BASE_BRANCH
reg="$HOME/.claude/running-agents"; shopt -s nullglob
self="$(for f in "$reg"/*; do [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ] && basename "$f" | sed 's/\.[0-9]*$//' && break; done)"
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
  alive=yes; kill -0 "$pid" 2>/dev/null || alive="DEAD(stale)"
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane" || alive="no-pane(stale)"
  bm="$HOME/.claude/agent-busy/$name"; busy=idle
  [ -f "$bm" ] && [ -n "$(find "$bm" -mmin -30 2>/dev/null)" ] && busy=BUSY
  branch="$(cat "$HOME/.claude/agents/$name" 2>/dev/null || echo '?')"   # recorded base branch
  role="$(case "$name" in *-test*|test-*) echo test;; *-pr*|pr-*|*-review*) echo review;; cc|*-cc|coordinator) echo coordinator;; *) echo feature;; esac)"
  printf '%-16s %-10s %-7s %-12s pane=%s pid=%s%s\n' "$name" "$role" "$busy" "$branch" "$pane" "$pid" "$( [ "$name" = "$self" ] && echo '  <- you')"
done
```

Report live agents grouped by role, flag any `DEAD`/`no-pane` stale entries (offer to prune them
with `rm`), and note who's BUSY. This is also the "look before you leap" step for the other modes.

## Mode: `msg` / canned actions — targeted message fan-out

The deliberate version of "broadcast, but only to the agents that should act."

1. **Resolve the audience.** From `status`, filter to the requested `--role` / names, drop self +
   `--exclude`. **Show the resolved recipient list and the exact body to the user and get explicit
   go** (unless they already named this exact fan-out this turn). `--dry-run` prints the list and stops.
2. **Deliver** by reusing the durable mailbox — one `/agent-send` per recipient (so each gets the
   at-least-once drain guarantee), or `/agent-broadcast` with `--exclude` for "all":
   ```bash
   for peer in $RECIPIENTS; do
     .claude/scripts/agent-send.sh "$peer" --stdin <<'BODY'
   <the message>
   BODY
   done
   ```
   Use `--followup` instead of the default request-kind when you expect each peer to reply.
3. **Report** per-peer delivery (agent-send prints nudged/queued/failed).

**Canned actions** encode the rituals teams actually use:

- `merge-down` → body: "local `<base>` advanced — please `/base-merge down` to pick it up."
  Default audience: all feature/review/test peers (not the coordinator — it refreshes its own
  `<base>-cc` on demand). This is the standard **post-`/base-push` sync** — still gated on the
  user asking; after a push, *propose* it, don't auto-fire.
- `pause "<reason>"` → body: "pause — <reason> (e.g. rebasing the base). I'll ping when clear."

## Mode: `restart` — force-restart agents (idle-gated, always confirmed)

Kill an agent's `claude` in its pane and relaunch it with **`claude --continue`**, which resumes
the pane's most recent conversation (no session-id lookup needed) — so context is preserved.
Useful when an agent is wedged, on a stale version of the skills/hooks, or needs a clean reload
without losing history.

> **Never restart without an explicit confirmation in this turn.** Restart kills the live process.
> Always show the plan and ask first.

How to run it: confirm with the user (show the candidate list — `agent-fanout.sh restart
--dry-run [targeting]` prints it), then:

```bash
.claude/scripts/agent-fanout.sh restart --yes [--role R] [--only a,b] [--exclude a,b]
```

What the script does per target (sequential, fail-contained):

1. **Idle-gate** — skips any agent with a fresh `~/.claude/agent-busy/<name>` marker or a pane in
   copy-mode (killing mid-turn loses in-flight work). To wait for a busy agent instead of skipping,
   poll with the **Monitor** tool until idle, then re-run.
2. **Kill** — `tmux send-keys C-c` twice, then waits for the pid to exit. In current Claude Code the
   double-`C-c` often does NOT exit, so the script falls back to `kill <pid>` once the grace window
   passes. (SessionEnd fires either way → unregisters.)
3. **Relaunch** — `tmux send-keys "claude --continue" Enter` in the same pane. The `SessionStart`
   hook re-registers the agent (new pid) and re-injects its role context; `--continue` resumes the
   prior conversation. No session-id lookup needed. For a genuine clean slate (loses history),
   launch plain `claude` manually with a separate explicit confirmation.
4. **Verify** — polls for a NEW `<name>.<newpid>` registry entry on that pane; prints OK or a WARN
   (with the pane) if it didn't come back.

**Never restarts the caller** (self is always excluded). A coordinator on `<base>-cc` keeps its
`cc` name across `--continue` (the session `.name` persists), so no re-`/agent-rename` is needed.

## Other useful behaviors (built in / suggested)

Built in (in `agent-fanout.sh`): read-only `status` (no auth), role/`--only`/`--exclude` targeting,
`--dry-run` everywhere, self-exclusion, idle-gating (skip BUSY/copy-mode), sequential restart via
`claude --continue` with re-registration verification, and the `--yes` tripwire on `restart`.

Worth considering (ask the user before adding — out of scope unless requested):

- **Auto-prune stale entries** during `status` (currently it only *reports* them).
- **Restart-on-version-drift**: detect agents whose `.claude/` is behind the local base (they
  haven't merged down the latest hooks/skills) and offer a targeted `merge-down` + restart.
- **Ack-collection**: for a `--followup` fan-out, watch each recipient's `*.rep.txt` and summarize
  who has/hasn't replied (reuse the `/afk` receipt-watching pattern via Monitor).
- **A background crash-watcher** that notices a `claude` pid vanished without `SessionEnd` and offers
  to relaunch — deliberately NOT built (a daemon doesn't belong in a hook, and it would still need
  the never-without-asking gate).

## What this skill will NOT do

- Fan out a message or restart anything without explicit user authorization in the current turn (the script's `restart` refuses without `--yes`, which you pass only after confirming).
- Kill or restart a BUSY agent (idle-gated — skipped).
- Restart the caller (self is always excluded).
- Touch `origin` (it only sends messages + manages local panes). Publishing stays `/base-push`.

## Companion skills

- **`agent-send`** / **`agent-broadcast`** — the delivery primitives this reuses.
- **`agent-msg`** — how recipients handle what you fan out.
- **`add-worktree`** — creates the agents (incl. the coordinator worktree on `<base>-cc`).
- **`afk`** — the receipt-watching / Monitor patterns the ack-collection idea would reuse.
