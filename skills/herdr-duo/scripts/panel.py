#!/usr/bin/env python3
"""Status panel and lead watchdog for a herdr-duo run. Started by panel.sh in its own
pane; uses no model. Each tick it redraws the run's progress, sessions, checks, git and
CI, and watches the lead's quota: it warns the lead when the 5h quota runs low and calls
handoff.sh when an idle lead has run out. It exits when the run is marked finished."""
import datetime, json, os, re, shutil, subprocess, sys, time

RUN = sys.argv[1]
HERE = os.path.dirname(os.path.realpath(__file__))
INTERVAL = float(os.environ.get("HERDR_DUO_PANEL_INTERVAL", "5"))
WARN_PCT = int(os.environ.get("HERDR_DUO_LEAD_WARN_PCT", "10"))
HANDOFF_PCT = int(os.environ.get("HERDR_DUO_LEAD_HANDOFF_PCT", "2"))
# Backup signal for limits the 5h figure does not show (weekly limits). Only the
# bottom of the lead's screen is searched, so a conversation about limits does not match.
LIMIT_RE = re.compile(os.environ.get("HERDR_DUO_LIMIT_REGEX",
    r"(?i)(hit your (usage )?limit|usage limit reached|reached your (\w+ )?usage limit|limit reached.{0,40}reset|"
    r"out of (usage|credits)|rate limit exceeded)"))

events, cache = [], {}
out_ticks = 0


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


def remaining(agent):
    m = re.search(r"(\d+)%", ((agent or {}).get("tokens") or {}).get("limit") or "")
    return int(m.group(1)) if m else None


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


def watchdog(lead, agents):
    global out_ticks
    if not lead or not lead.get("pane"):
        return "no lead recorded"
    status = lead.get("status", "active")
    if status == "awaiting_approval":
        sh(os.path.join(HERE, "handoff.sh"), "--run", RUN, "--deliver", timeout=30)
        return f"successor {lead['name']} starting in pane {lead['pane']} (answer its dialog there if one shows)"
    a = agents.get(lead["pane"])
    screen = "\n".join(sh("herdr", "pane", "read", lead["pane"], "--source", "visible").splitlines()[-15:]) if a else ""
    hit = LIMIT_RE.search(screen)
    if status == "stranded":
        left = remaining(a)
        # A weekly limit leaves the 5h figure high, so the limit message must be gone too.
        if left is None or left <= WARN_PCT or hit:
            return "NO LEAD: every provider ran out of quota. Resume manually later (SKILL.md, Resume a run)"
        lead["status"] = "active"  # the lead's quota has reset; watch it again
        with open(os.path.join(RUN, "lead.json.tmp"), "w") as f:
            json.dump(lead, f, indent=2)
        os.replace(os.path.join(RUN, "lead.json.tmp"), os.path.join(RUN, "lead.json"))
        event(f"{lead['name']} has quota again ({left}% left)")
    if not a:
        out_ticks = 0
        return f"lead {lead['name']} not detected in pane {lead['pane']}"
    left = remaining(a)
    warn = os.path.join(RUN, "lead.warning")
    if left is not None and left <= WARN_PCT and not os.path.exists(warn):
        open(warn, "w").write(f"{left}% of the lead's 5h quota left")
        event(f"warned {lead['name']}: {left}% quota left")
    elif left is not None and left > WARN_PCT + 5 and os.path.exists(warn):
        os.remove(warn)
    out = a.get("agent_status") != "working" and ((left is not None and left <= HANDOFF_PCT) or hit)
    out_ticks = out_ticks + 1 if out else 0
    if out_ticks >= 2:
        reason = f"quota exhausted ({left}% of 5h left)" if left is not None and left <= HANDOFF_PCT else f"limit message: {hit.group(0)}"
        r = subprocess.run([os.path.join(HERE, "handoff.sh"), "--run", RUN, "--reason", reason],
                           capture_output=True, text=True, timeout=180)
        event((r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else f"handoff exit {r.returncode}")
        out_ticks = 0
    q = f"{left}% 5h left" if left is not None else "quota ?"
    return f"{lead['name']} {lead.get('kind') or '?'} {a.get('agent_status')} · {q}"


def render(state, progress, lead, agents):
    L = []
    goal = state.get("goal") or os.path.basename(state.get("repo", ""))
    L.append(f"{goal[:60]} · herdr-duo   {time.strftime('%H:%M:%S')}")
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
    L.append("")
    L.append("Lead")
    L.append("  " + watchdog(lead, agents))
    if lead:
        band = lead.get('band') or ('unknown' if 'destinations' in lead else 'legacy')
        L.append(f"  model: {lead.get('model') or '?'} · band: {band}")
        if 'destinations' in lead:
            L.append("  lead destinations: " + " · ".join(
                f"{p}={d.get('model') or 'unresolved'}" for p, d in lead['destinations'].items()))
    recs = [r for k in ("workers", "reviewers") for r in state.get(k, [])]
    live = [r for r in recs if r.get("status") not in ("cleaned", "escalated")]
    L.append("")
    L.append(f"Agents ({len(live)} live, {len(recs) - len(live)} closed)")
    quota = {}
    for r in live:
        a = agents.get(r.get("pane"), {})
        st = a.get("agent_status") or r.get("status", "?")
        extra = []
        if r.get("tier") == "strong": extra.append("STRONG")
        if r.get("fix_rounds"): extra.append(f"fix {r['fix_rounds']}")
        if st == "working" and r.get("dispatched_at"):
            extra.append(f"{int(time.time() - r['dispatched_at']) // 60}m")
        if r.get("status") in ("needs_approval", "blocked", "settled_no_report", "timeout_or_stalled"):
            extra.append(r["status"])
        left = remaining(a)
        # Idle panes keep the figure of their last turn; only working panes are current.
        if left is not None and a.get("agent_status") == "working":
            quota[r["provider"]] = min(left, quota.get(r["provider"], 100))
        L.append(f"  {r['name']:<14} {st:<8} {' · '.join(extra)}")
    if lead and agents.get(lead.get("pane")):
        left = remaining(agents[lead["pane"]])
        if left is not None and lead.get("kind"):
            quota[lead["kind"]] = min(left, quota.get(lead["kind"], 100))
    if quota:
        L.append("  quota (5h left): " + " · ".join(f"{k} {v}%" for k, v in sorted(quota.items())))
    for e in state.get("escalations", [])[-3:]:
        L.append(f"  ↑ {e['from']} -> {e['to']}: {e['reason'][:60]}")
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
        state = load("state.json", {})
        if state.get("status") == "finished":
            print("run finished; panel closed")
            return
        try:
            lines = render(state, load("progress.json", {}), load("lead.json", {}), agents_by_pane())
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
