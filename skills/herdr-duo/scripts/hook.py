#!/usr/bin/env python3
"""Quota guardian hook for herdr-duo leads (Claude Code and Codex use the same format).

Installed by install-hooks.sh for UserPromptSubmit and PostToolUse. It does nothing unless
the calling pane (HERDR_PANE_ID) is the principal or the sibling lead of an active run.
For a lead it adds one line of context: both subscriptions' 5h quota, the provider to
give new helper work to, and, when it applies, a low-quota warning or new alerts.
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
    lead = json.load(open(os.path.join(run, "lead.json")))
    state = json.load(open(os.path.join(run, "state.json")))
    if role == "lead":
        mine, who = lead.get("kind"), "principal"
    else:
        rec = next((r for r in state.get("workers", []) if r.get("name") == role), {})
        mine, who = rec.get("provider"), f"sibling '{role}'"
    pick, why = quota.suggest(q, "helper", mine)
    text = (f"herdr-duo ({who}, run {run}) · 5h quota: "
            + " · ".join(quota.fmt(p, q.get(p) or {}) for p in quota.PROVIDERS)
            + f" · new helper work → {pick or '?'} ({why}).")
    urgent = []
    x = q.get(mine) or {}
    if x.get("known") and x["left"] <= WARN_PCT:
        if role == "lead":
            urgent.append(f"QUOTA LOW: your {mine} 5h window has {x['left']:.0f}% left. Checkpoint now "
                          f"(progress.sh note), then at a safe point: {HERE}/handoff.sh --run {run} --reason \"quota low\".")
        else:
            urgent.append(f"QUOTA LOW: your {mine} 5h window has {x['left']:.0f}% left. Stop at a safe point and "
                          f"send the principal your report block with STATUS: partial.")
    alerts = []
    if role == "lead":
        path = os.path.join(run, "alerts.log")
        if os.path.exists(path):
            alerts = [l.strip() for l in open(path) if l.strip()]
    return text, urgent, alerts


def main():
    global WARN_PCT
    WARN_PCT = int(os.environ.get("HERDR_DUO_LEAD_WARN_PCT", "10"))
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
    q = quota.snapshot()
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
