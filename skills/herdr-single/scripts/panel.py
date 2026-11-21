#!/usr/bin/env python3
"""Status panel and lead watchdog for a herdr-single run. Started by panel.sh in its own
pane; uses no model. Each tick it redraws the run's progress, the run's 5h window and how
many more helpers it can carry, the lead and its sessions, checks, git and CI.

It watches the lead's window through quota.py (no live pane needed):
  - it warns the lead when its 5h window runs low;
  - when an idle lead has run out, it PARKS the run (handoff.sh): there is no other
    subscription to hand it to;
  - when the window resets, it resumes the run (handoff.sh --resume): the same lead pane
    continues if it is alive, else a fresh lead of the same provider starts.
HERDR_SINGLE_LEAD_RESUME=off makes it only warn and alert. The panel exits when the run is
marked finished."""
import datetime, json, os, re, shutil, subprocess, sys, time

RUN = sys.argv[1] if len(sys.argv) > 1 else ""
# Dynamic imports must not leave generated files in the installed skill.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
INTERVAL = float(os.environ.get("HERDR_SINGLE_PANEL_INTERVAL", "5"))
WARN_PCT = int(os.environ.get("HERDR_SINGLE_LEAD_WARN_PCT", "10"))
HANDOFF_PCT = int(os.environ.get("HERDR_SINGLE_LEAD_HANDOFF_PCT", "2"))
# Backup signal for limits the 5h figure does not show. Only the bottom of a lead's
# screen is searched, so a conversation about limits does not match.
LIMIT_RE = re.compile(os.environ.get("HERDR_SINGLE_LIMIT_REGEX",
    r"(?i)(hit your (usage )?limit|usage limit reached|reached your (\w+ )?usage limit|limit reached.{0,40}reset|"
    r"out of (usage|credits)|rate limit exceeded)"))
GONE = ("cleaned", "escalated", "promoted")
RESUME = os.environ.get("HERDR_SINGLE_LEAD_RESUME", "auto")

sys.path.insert(0, HERE)
import importlib.util
_spec = importlib.util.spec_from_file_location("quota", os.path.join(HERE, "quota.py"))
quota = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(quota)

events, cache = [], {}
out_ticks = {}


def sh(*cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def load(name, default):
    try:
        return json.load(open(os.path.join(RUN, name)))
    except Exception:
        return default


def every(key, seconds, fn):
    t, v = cache.get(key, (0, None))
    if time.time() - t >= seconds:
        v = fn()
        cache[key] = (time.time(), v)
    return v


def event(msg):
    events.append(time.strftime("%H:%M:%S ") + msg)
    del events[:-4]


def pane_remaining(agent):
    # 'limits' carries the current 5h and 7d windows; 'limit' can be stale. Only the 5h entry counts.
    tokens = (agent or {}).get("tokens") or {}
    m = re.search(r"\b5h (\d+)%", tokens.get("limits") or "") or re.search(r"\b5h (\d+)%", tokens.get("limit") or "")
    return int(m.group(1)) if m else None


def left_of(provider, agent, q):
    """5h left for PROVIDER: the quota sensor, else the pane's own figure."""
    x = q.get(provider) or {}
    if x.get("known"):
        return round(x["left"])
    return pane_remaining(agent)


def agents_by_pane():
    try:
        return {a["pane_id"]: a for a in json.loads(sh("herdr", "agent", "list"))["result"]["agents"]}
    except Exception:
        return {}


def git_info(repo):
    branch = sh("git", "-C", repo, "symbolic-ref", "-q", "--short", "HEAD").strip() or "(detached)"
    changed = len([l for l in sh("git", "-C", repo, "status", "--porcelain").splitlines() if l.strip()])
    return branch, changed


def ci_info(repo, branch):
    if not shutil.which("gh") or "github.com" not in sh("git", "-C", repo, "remote", "get-url", "origin"):
        return None
    try:
        runs = json.loads(subprocess.run(
            ["gh", "run", "list", "--branch", branch, "--limit", "1", "--json", "headSha,status,conclusion,workflowName"],
            cwd=repo, capture_output=True, text=True, timeout=20).stdout or "[]")
    except Exception:
        return None
    if not runs:
        return "no runs on this branch"
    r = runs[0]
    return f"{r['headSha'][:7]} {r['workflowName']}: {r['status']} {r.get('conclusion') or ''}".strip()


def limit_hit(pane):
    screen = "\n".join(sh("herdr", "pane", "read", pane, "--source", "visible").splitlines()[-15:])
    return LIMIT_RE.search(screen)


def set_warning(path, left, who):
    if left is not None and left <= WARN_PCT and not os.path.exists(path):
        open(path, "w").write(f"{left}% of {who}'s 5h quota left")
        event(f"warned {who}: {left}% quota left")
    elif left is not None and left > WARN_PCT + 5 and os.path.exists(path):
        os.remove(path)


def alert(msg):
    with open(os.path.join(RUN, "alerts.log"), "a") as f:
        f.write(time.strftime("%H:%M ") + msg + "\n")
    event(msg[:70])


def update_lead(change):
    """Apply CHANGE(lead) under the lock every lead.json writer holds; returns the result.
    The file is re-read under the lock, so a concurrent handoff is never overwritten."""
    import fcntl, tempfile
    path = os.path.join(RUN, "lead.json")
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(path) as f:
            lead = json.load(f)
        if not change(lead):
            return lead
        with tempfile.NamedTemporaryFile("w", dir=RUN, prefix="lead-", suffix=".tmp", delete=False) as f:
            json.dump(lead, f, indent=2)
        os.replace(f.name, path)
        return lead


def handoff(*args):
    r = subprocess.run([os.path.join(HERE, "handoff.sh"), "--run", RUN, *args],
                       capture_output=True, text=True, timeout=180)
    text = (r.stdout or r.stderr).strip()
    event(text.splitlines()[0] if text else f"handoff exit {r.returncode}")


def at(ts):
    return time.strftime("%H:%M", time.localtime(ts)) if ts else "?"


def watchdog(lead, agents, q, provider):
    if not lead or not lead.get("pane"):
        return "no lead recorded"
    status = lead.get("status", "active")
    if status in ("awaiting_approval", "awaiting_delivery"):
        sh(os.path.join(HERE, "handoff.sh"), "--run", RUN, "--deliver", timeout=30)
        return f"{lead['name']} resuming in pane {lead['pane']} (answer its dialog there if one shows)"
    a = agents.get(lead["pane"])
    if status == "parked":
        left = left_of(provider, None, q)
        until = lead.get("parked_until") or 0
        ready = time.time() >= until and (left is None or left > WARN_PCT)
        if not ready:
            return f"PARKED until {at(until)}: {lead.get('parked_reason') or 'window out'}"
        if RESUME == "off":
            return (f"window reset at {at(until)}; resume by hand (HERDR_SINGLE_LEAD_RESUME=off): "
                    "ask any lead to resume the run")
        handoff("--resume")
        return "window reset; resuming the run"
    if not a:
        out_ticks["lead"] = 0
        return f"lead {lead['name']} not detected in pane {lead['pane']}"
    left = left_of(provider, a, q)
    set_warning(os.path.join(RUN, "lead.warning"), left, lead["name"])
    hit = limit_hit(lead["pane"])
    out = a.get("agent_status") != "working" and ((left is not None and left <= HANDOFF_PCT) or hit)
    out_ticks["lead"] = out_ticks.get("lead", 0) + 1 if out else 0
    if out_ticks["lead"] >= 2:
        out_ticks["lead"] = 0
        sensor = left is not None and left <= HANDOFF_PCT
        why = f"quota exhausted ({left}% of 5h left)" if sensor else f"limit message: {hit.group(0)}"
        if RESUME == "off":
            if not os.path.exists(os.path.join(RUN, "lead.out")):
                with open(os.path.join(RUN, "lead.out"), "w") as f:
                    f.write(time.strftime("%H:%M"))
                alert(f"lead {lead['name']} is out of {provider} 5h quota ({why}); resume after the reset")
        else:
            handoff("--reason", why, *(() if sensor else ("--park",)))
    elif not out and left is not None and left > WARN_PCT:
        try:
            os.remove(os.path.join(RUN, "lead.out"))
        except OSError:
            pass
    q_txt = f"{left}% 5h left" if left is not None else "quota ?"
    return f"{lead['name']} {lead.get('model') or provider} {a.get('agent_status')} · {q_txt}"


def render(state, progress, lead, agents, q):
    provider = state.get("provider") or (lead or {}).get("kind") or "?"
    L = []
    goal = state.get("goal") or os.path.basename(state.get("repo", ""))
    L.append(f"{goal[:60]} · herdr-single ({provider})   {time.strftime('%H:%M:%S')}")
    steps = progress.get("steps", [])
    if steps:
        done = sum(1 for s in steps if s["status"] == "done")
        w = 20
        fill = round(w * done / len(steps))
        L.append(f"PROGRESS [{'#' * fill}{'.' * (w - fill)}] {done}/{len(steps)} ({100 * done // len(steps)}%)")
    L.append("")
    L.append("Now: " + (progress.get("now") or "-"))
    if steps:
        L.append("")
        mark = {"done": "✔", "active": "▶", "failed": "✖", "todo": "○"}
        L += [f" {mark.get(s['status'], '?')} {s['title']}" for s in steps]

    recs = [r for k in ("workers", "reviewers") for r in state.get(k, [])]
    live = [r for r in recs if r.get("status") not in GONE]
    x = q.get(provider) or {}
    L.append("")
    L.append("5h quota")
    L.append("  " + quota.fmt(provider, x))
    n, why = quota.suggest(x, len(live))
    L.append(f"  new helpers now: {n} ({why})")

    L.append("")
    L.append("Lead")
    L.append("  " + watchdog(lead, agents, q, provider))

    def line(r):
        a = agents.get(r.get("pane"), {})
        st = a.get("agent_status") or r.get("status", "?")
        extra = [r.get("model") or r["provider"]]
        if r["role"] == "reviewer": extra.append(f"reviews {r.get('review_of')}")
        if r.get("fix_rounds"): extra.append(f"fix {r['fix_rounds']}")
        if st == "working" and r.get("dispatched_at"):
            extra.append(f"{int(time.time() - r['dispatched_at']) // 60}m")
        if r.get("status") in ("needs_approval", "blocked", "settled_no_report", "timeout_or_stalled"):
            extra.append(r["status"])
        return f"  {r['name']:<14} {st:<8} {' · '.join(extra)}"

    L.append("")
    L.append(f"Sessions ({len(live)} live, {len(recs) - len(live)} closed)")
    L += [line(r) for r in live]

    checks = progress.get("checks", [])
    if checks:
        L.append("")
        L.append("Checks")
        for c in checks[-4:]:
            L.append(f"  {'✔' if c['rc'] == 0 else '✖'} {c['label']}: {c['summary']} (exit {c['rc']})")
    repo = state.get("repo", "")
    branch, changed = every("git", 15, lambda: git_info(repo))
    ci = every("ci", 60, lambda: ci_info(repo, branch))
    L.append("")
    L.append("Git / CI")
    L.append(f"  {changed} changed files · branch {branch}")
    if ci:
        L.append(f"  last run: {ci}")
    if events:
        L.append("")
        L.append("Watchdog")
        L += ["  " + e for e in events]
    return L


def main():
    while True:
        if not os.path.isdir(RUN):
            print("run directory removed; panel closed")
            return
        state = load("state.json", {})
        if state.get("status") == "finished":
            print("run finished; panel closed")
            return
        try:
            provider = state.get("provider")
            q = every("quota", 15, lambda: quota.snapshot((provider,) if provider in quota.PROVIDERS else quota.PROVIDERS))
            lines = render(state, load("progress.json", {}), load("lead.json", {}), agents_by_pane(), q)
        except Exception as exc:  # keep the panel alive through transient errors
            lines = [f"panel error: {exc}"]
        cols, rows = shutil.get_terminal_size((100, 40))
        # Cut instead of wrapping, so a narrow pane keeps one line per item.
        lines = [l if len(l) < cols else l[:max(cols - 2, 10)] + "…" for l in lines]
        sys.stdout.write("\x1b[H\x1b[2J" + "\n".join(lines[:max(rows - 1, 5)]) + "\n")
        sys.stdout.flush()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
