---
name: agent-fanout
description: Orchestrate the agent fleet — show fleet status, fan a message or canned action out to a targeted set of peers (by role), and optionally force-restart idle agents (kill the pane's claude, relaunch with `claude --resume` to preserve context). High blast-radius; every fan-out needs explicit user authorization and every restart is confirmed first. Use for "show me the fleet", "tell the feature agents to merge down", "restart the test agent".
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

## Modes

```
/agent-fanout status                              # read-only fleet snapshot (no auth needed)
/agent-fanout msg --role <r> --stdin <<'BODY'…    # fan a message out to a role/set
/agent-fanout merge-down [--role all]             # canned: peers run /base-merge down
/agent-fanout pause "<reason>"                    # canned: tell peers to pause
/agent-fanout restart [--role <r>|<names>]        # idle-gated, confirmed, claude --resume
```

Targeting flags (all modes): `--role feature|review|test|coordinator|all` · `<name1,name2>`
explicit list · `--exclude a,b` · `--dry-run`. Restart adds `--resume` (default) / `--fresh`,
`--wait` (wait for busy→idle), `--parallel` (default sequential).

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
     "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" "$peer" --stdin <<'BODY'
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

Kill an agent's `claude` in its pane and relaunch it, **preserving its conversation** via
`claude --resume`. Useful when an agent is wedged, on a stale version of the skills/hooks, or its
context needs a clean reload without losing history.

> **Never restart without an explicit confirmation in this turn.** Restart kills the live process.
> Always show the plan and ask first.

Per target, in order:

1. **Resolve identity + session.** From the registry: `pid="${bn##*.}"`. Get the resumable session
   id from the session file Claude Code writes:
   ```bash
   sid="$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$pid.json" 2>/dev/null)"
   ```
   If `sid` is empty (no session file), you **cannot** `--resume` — offer `--fresh` (a brand-new
   `claude`, which **loses the conversation**, extra confirmation) or skip that agent.
2. **Idle-gate.** Refuse to restart a BUSY agent (fresh `~/.claude/agent-busy/<name>`, <30 min) or
   one whose pane is in copy-mode — killing mid-turn loses in-flight work. Skip it and report, or
   with `--wait` poll (use the **Monitor** tool with an until-condition; foreground `sleep` is
   blocked) until the busy marker clears, up to a timeout, then proceed.
3. **Confirm with the user.** Show the table: each target's name, role, pane, pid, recorded branch,
   and the relaunch command (`claude --resume <sid>` or `claude` for `--fresh`). Get an explicit yes.
   Default is **sequential** (one at a time) so a failure is contained; `--parallel` does them at
   once (riskier — don't nuke the whole fleet blindly).
4. **Kill** the running claude in the pane (Claude Code exits on a double Ctrl-C):
   ```bash
   tmux send-keys -t "$pane" C-c; sleep 1; tmux send-keys -t "$pane" C-c
   ```
   Wait until the claude pid is actually gone before relaunching (so the shell prompt is back):
   ```bash
   for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
   kill -0 "$pid" 2>/dev/null && { echo "$name: claude (pid $pid) didn't exit on C-c; killing"; kill "$pid"; sleep 1; }
   ```
5. **Relaunch** in the same pane:
   ```bash
   tmux send-keys -t "$pane" "claude --resume $sid" Enter      # or just "claude" for --fresh
   ```
   The `SessionStart` hook re-registers the agent (new pid) and re-injects its role context.
6. **Verify it came back.** Poll the registry for a NEW `<name>.<newpid>` entry whose contents match
   `$pane` and whose pid ≠ the old one (it may also need an `/agent-rename` if the branch-derived
   name differs — e.g. a coordinator on `<base>-cc` should re-rename to `cc`). Report success/failure
   per agent; on failure, surface the pane so the user can look.

**Never restart yourself** (the caller / coordinator). If a target resolves to self, skip it and say so.

## Other useful behaviors (built in / suggested)

Built in above: read-only `status` (no auth), role-targeted audiences, `--dry-run` everywhere,
self-exclusion, idle-gating + optional `--wait`, sequential-by-default restart with re-registration
verification, `--resume` (preserve context) vs `--fresh` (clean slate, extra confirm), stale-entry
surfacing.

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

- Fan out a message or restart anything without explicit user authorization in the current turn.
- Kill or restart a BUSY agent (skips it unless `--wait` is used and it goes idle).
- Restart the caller, or `--fresh`-restart (losing context) without a second explicit confirm.
- Touch `origin` (it only sends messages + manages local panes). Publishing stays `/base-push`.

## Companion skills

- **`agent-send`** / **`agent-broadcast`** — the delivery primitives this reuses.
- **`agent-msg`** — how recipients handle what you fan out.
- **`add-worktree`** — creates the agents (incl. the coordinator worktree on `<base>-cc`).
- **`afk`** — the receipt-watching / Monitor patterns the ack-collection idea would reuse.
