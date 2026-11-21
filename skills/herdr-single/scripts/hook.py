#!/usr/bin/env python3
"""Quota guardian hook for herdr-single leads (Claude Code and Codex use the same format).

Installed by install-hooks.sh for UserPromptSubmit and PostToolUse. It does nothing unless
the calling pane (HERDR_PANE_ID) is the lead of an active herdr-single run. For the lead
it adds one line of context: the run's 5h window, how many more helpers it can carry now,
and, when it applies, a low-quota warning or new alerts.
  UserPromptSubmit: always.
  PostToolUse:      only when a warning or alert is new, or every 30 minutes, so a lead
                    working alone for a long turn still learns that its window is closing.
It never fails the caller: any error means no output."""
import importlib.util, json, os, sys, tempfile, time

# Dynamic imports must not leave generated files in the installed skill.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
WARN_PCT = 10
REFRESH_S = 30 * 60


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def context(run, role, q, quota):
    state = json.load(open(os.path.join(run, "state.json")))
    mine = state.get("provider")
    live = sum(1 for k in ("workers", "reviewers") for r in state.get(k, [])
               if r.get("status") not in ("cleaned", "escalated", "promoted"))
    x = q.get(mine) or {}
    n, why = quota.suggest(x, live)
    text = (f"herdr-single (lead, run {run}) · 5h quota: {quota.fmt(mine, x)}"
            f" · new helpers now: {n} ({why}).")
    urgent = []
    if x.get("known") and x["left"] <= WARN_PCT:
        urgent.append(f"QUOTA LOW: your {mine} 5h window has {x['left']:.0f}% left and no other subscription "
                      f"can take over. Checkpoint now (progress.sh note) and reach a safe point; the panel parks "
                      f"the run when the window is out and resumes it at the reset.")
    alerts = []
    path = os.path.join(run, "alerts.log")
    if os.path.exists(path):
        alerts = [l.strip() for l in open(path) if l.strip()]
    return text, urgent, alerts


def main():
    global WARN_PCT
    WARN_PCT = int(os.environ.get("HERDR_SINGLE_LEAD_WARN_PCT", "10"))
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    event = data.get("hook_event_name") or (sys.argv[1] if len(sys.argv) > 1 else "UserPromptSubmit")
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane:
        return
    members = module("members", "members.py")
    run, role = members.find(pane)
    if not run:
        return
    quota = module("quota", "quota.py")
    provider = json.load(open(os.path.join(run, "state.json"))).get("provider")
    q = quota.snapshot((provider,) if provider in quota.PROVIDERS else quota.PROVIDERS)
    text, urgent, alerts = context(run, role, q, quota)

    seen_path = os.path.join(run, f"hook-{pane.replace(':', '_')}.json")
    try:
        seen = json.load(open(seen_path))
    except (OSError, ValueError):
        seen = {}
    new_alerts = alerts[seen.get("alerts", 0):]
    key = " | ".join(urgent)
    if event == "PostToolUse":
        fresh = (urgent and key != seen.get("urgent")) or new_alerts
        if not fresh and time.time() - seen.get("at", 0) < REFRESH_S:
            return
    parts = [text] + urgent + [f"ALERT: {a}" for a in new_alerts]
    with tempfile.NamedTemporaryFile(mode="w", dir=run, prefix="hook-", suffix=".tmp", delete=False) as f:
        tmp = f.name
        json.dump({"at": time.time(), "urgent": key, "alerts": len(alerts)}, f)
    os.replace(tmp, seen_path)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": "\n".join(parts)}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
