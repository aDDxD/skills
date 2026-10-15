#!/usr/bin/env python3
"""Status panel and lead watchdog for a herdr-duo run. Started by panel.sh in its own
pane; uses no model. Each tick it redraws the run's progress, both subscriptions' 5h
quota, the two leads with the helpers each one owns, checks, git and CI.

It watches both leads' quota through quota.py (no live pane needed):
  - the principal: warns it when its 5h window runs low, and calls handoff.sh when an
    idle principal has run out (the live sibling is promoted; else a fresh lead starts);
  - the sibling: warns it when its window runs low, and alerts the principal when an idle
    sibling has run out, so the principal collects its slice and redistributes it.
A stranded run resumes when either window resets. The panel exits when the run is
marked finished."""
import datetime, json, os, re, shutil, subprocess, sys, time

RUN = sys.argv[1] if len(sys.argv) > 1 else ""
# Dynamic imports must not leave generated files in the installed skill.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.realpath(__file__))
INTERVAL = float(os.environ.get("HERDR_DUO_PANEL_INTERVAL", "5"))
WARN_PCT = int(os.environ.get("HERDR_DUO_LEAD_WARN_PCT", "10"))
HANDOFF_PCT = int(os.environ.get("HERDR_DUO_LEAD_HANDOFF_PCT", "2"))
# Backup signal for limits the 5h figure does not show. Only the bottom of a lead's
# screen is searched, so a conversation about limits does not match.
LIMIT_RE = re.compile(os.environ.get("HERDR_DUO_LIMIT_REGEX",
    r"(?i)(hit your (usage )?limit|usage limit reached|reached your (\w+ )?usage limit|limit reached.{0,40}reset|"
    r"out of (usage|credits)|rate limit exceeded)"))
GONE = ("cleaned", "escalated", "promoted")
OTHER = {"claude": "codex", "codex": "claude"}

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


def handoff(reason):
    r = subprocess.run([os.path.join(HERE, "handoff.sh"), "--run", RUN, "--reason", reason],
                       capture_output=True, text=True, timeout=180)
    text = (r.stdout or r.stderr).strip()
    event(text.splitlines()[0] if text else f"handoff exit {r.returncode}")


def watchdog(lead, agents, q):
    if not lead or not lead.get("pane"):
        return "no lead recorded"
    status = lead.get("status", "active")
    if status in ("awaiting_approval", "awaiting_delivery"):
        sh(os.path.join(HERE, "handoff.sh"), "--run", RUN, "--deliver", timeout=30)
        return f"successor {lead['name']} taking over in pane {lead['pane']} (answer its dialog there if one shows)"
    kind = lead.get("kind")
    a = agents.get(lead["pane"])
    hit = limit_hit(lead["pane"]) if a else None
    if status == "stranded":
        own = left_of(kind, a, q) if kind else None
        other = left_of(OTHER.get(kind), None, q) if kind else None
        if own is not None and own > WARN_PCT and not hit:
            def reactivate(current):  # the principal's own window has reset; watch it again
                if current.get("status") != "stranded" or current.get("pane") != lead.get("pane"):
                    return False
                current["status"] = "active"
                current.pop("stranded_reason", None)
                return True
            lead = update_lead(reactivate)
            event(f"{lead['name']} has quota again ({own}% left)")
        elif other is not None and other > WARN_PCT:
            handoff(f"{OTHER[kind]} window reset while the run was stranded")
            return "resuming on the other subscription"
        else:
            return "NO LEAD: both 5h windows are out. The run resumes when one resets (SKILL.md, Resume a run)"
    if not a:
        out_ticks["lead"] = 0
        return f"principal {lead['name']} not detected in pane {lead['pane']}"
    left = left_of(kind, a, q)
    set_warning(os.path.join(RUN, "lead.warning"), left, lead["name"])
    out = a.get("agent_status") != "working" and ((left is not None and left <= HANDOFF_PCT) or hit)
    out_ticks["lead"] = out_ticks.get("lead", 0) + 1 if out else 0
    if out_ticks["lead"] >= 2:
        handoff(f"quota exhausted ({left}% of 5h left)" if left is not None and left <= HANDOFF_PCT
                else f"limit message: {hit.group(0)}")
        out_ticks["lead"] = 0
    q_txt = f"{left}% 5h left" if left is not None else "quota ?"
    return f"{lead['name']} {kind or '?'} {lead.get('model') or ''} {a.get('agent_status')} · {q_txt}"


def watch_sibling(sib, agents, q):
    a = agents.get(sib.get("pane"))
    if not a:
        return "not detected"
    left = left_of(sib["provider"], a, q)
    set_warning(os.path.join(RUN, f"{sib['name']}.warning"), left, sib["name"])
    hit = limit_hit(sib["pane"])
    out = a.get("agent_status") != "working" and ((left is not None and left <= HANDOFF_PCT) or hit)
    key = "sib:" + sib["name"]
    out_ticks[key] = out_ticks.get(key, 0) + 1 if out else 0
    flag = os.path.join(RUN, f"{sib['name']}.out")
    if out_ticks[key] >= 2 and not os.path.exists(flag):
        open(flag, "w").write(time.strftime("%H:%M"))
        x = q.get(sib["provider"]) or {}
        back = time.strftime("%H:%M", time.localtime(x["resets_at"])) if x.get("resets_at") else "its window resets"
        alert(f"sibling {sib['name']} ({sib['provider']}) ran out of 5h quota. Collect its slice "
              f"(delta.sh --state {sib.get('state_dir')}), reassign the rest; reopen a sibling after {back}.")
    elif not out and os.path.exists(flag) and left is not None and left > WARN_PCT:
        os.remove(flag)
    return f"{a.get('agent_status')} · {left if left is not None else '?'}% 5h left"


def render(state, progress, lead, agents, q):
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
    L.append("5h quota")
    for p in quota.PROVIDERS:
        L.append("  " + quota.fmt(p, q.get(p) or {}))
    pick, why = quota.suggest(q, "helper", (lead or {}).get("kind"))
    L.append(f"  new helper work → {pick or '?'} ({why})")

    recs = [r for k in ("workers", "reviewers") for r in state.get(k, [])]
    live = [r for r in recs if r.get("status") not in GONE]
    sib = next((r for r in live if r.get("level") == "sibling"), None)
    L.append("")
    L.append("Leads")
    L.append("  principal: " + watchdog(lead, agents, q))
    if sib:
        L.append(f"  sibling {sib['name']}: {sib['provider']} {sib.get('model') or ''} · " + watch_sibling(sib, agents, q))
    else:
        L.append("  sibling: none (open one when the task has a separable slice)")

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
        return f"    {r['name']:<14} {st:<8} {' · '.join(extra)}"

    helpers = [r for r in live if r.get("level") != "sibling"]
    L.append("")
    L.append(f"Sessions ({len(live)} live, {len(recs) - len(live)} closed)")
    for owner in ["lead"] + ([sib["name"]] if sib else []):
        mine = [r for r in helpers if r.get("owner", "lead") == owner]
        if mine:
            L.append(f"  {'principal' if owner == 'lead' else owner}:")
            L += [line(r) for r in mine]
    orphans = [r for r in helpers if r.get("owner", "lead") not in (["lead"] + ([sib["name"]] if sib else []))]
    if orphans:
        L.append("  without a live owner:")
        L += [line(r) for r in orphans]

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
            q = every("quota", 15, quota.snapshot)
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
