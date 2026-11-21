#!/usr/bin/env python3
"""5-hour quota of the run's subscription, read without any live pane.

Claude: the Herdr usage bar's claude-limits-latest.json (fiveHour.usedPercentage, resetsAt).
Codex:  the newest rollout under $CODEX_HOME/sessions (rate_limits.primary, window 300 min).
Both stores keep the last value they saw. A window whose resets_at has passed is reported as
0% used: no newer record means no use since. Herdr's `tokens.limits` of a working pane
("5h N%" = N% left) is the fallback. Weekly windows are ignored on purpose.

Each call appends to a small history in the state root, which gives the burn rate and the
projected surplus: the share of the window that would still be unused at reset at the
current rate, i.e. quota that is about to be wasted.

With one subscription there is nowhere else to send work, so the question is pace:
`suggest` answers how many more helpers the window can carry now. A projected surplus
means quota that would be lost at reset, so it is spent on helpers; a window on pace, or
below the lead's reserve, gets no new helpers.

Usage: quota.py json | line | suggest --provider codex|claude [--live N]
"""
import argparse, fcntl, glob, json, math, os, re, subprocess, sys, tempfile, time

PROVIDERS = ("claude", "codex")
HOME = os.path.expanduser("~")
STATE_ROOT = os.environ.get("HERDR_SINGLE_STATE_ROOT") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "herdr-single")
CLAUDE_LIMITS = os.environ.get("HERDR_SINGLE_CLAUDE_LIMITS") or os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"), "herdr-usagebar", "claude-limits-latest.json")
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
CACHE_S = float(os.environ.get("HERDR_SINGLE_QUOTA_CACHE_S", "20"))
RESERVE = int(os.environ.get("HERDR_SINGLE_LEAD_RESERVE_PCT", "30"))
MAX_HELPERS = int(os.environ.get("HERDR_SINGLE_MAX_HELPERS", "6"))
RATE_WINDOW_S = 30 * 60


def read_json(path):
    with open(path) as f:
        return json.load(f)


def now():
    return float(os.environ.get("HERDR_SINGLE_NOW") or time.time())


def claude_reading():
    try:
        d = read_json(CLAUDE_LIMITS)
        w = d["fiveHour"]
        used, resets = float(w["usedPercentage"]), float(w["resetsAt"])
        if not math.isfinite(used) or not math.isfinite(resets) or not 0 <= used <= 100:
            return None
        return {"used": used, "resets_at": resets,
                "observed_at": float(d.get("fetchedAtMs", 0)) / 1000 or os.path.getmtime(CLAUDE_LIMITS),
                "source": "herdr-usagebar"}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def codex_reading():
    files = glob.glob(os.path.join(CODEX_HOME, "sessions", "**", "*.jsonl"), recursive=True)
    dated = []
    for path in files:
        try:
            dated.append((os.path.getmtime(path), path))
        except OSError:  # a rollout may disappear during cleanup
            continue
    for modified, path in sorted(dated, reverse=True):
        try:
            with open(path, "rb") as f:
                f.seek(max(0, os.path.getsize(path) - 2_000_000))
                text = f.read().decode("utf-8", "replace")
        except OSError:
            continue
        for line in reversed(text.splitlines()):
            try:
                record = json.loads(line)
                payload = record.get("payload", record)
                w = payload["rate_limits"]["primary"]
                used, resets = float(w["used_percent"]), float(w["resets_at"])
                if w.get("window_minutes") != 300 or not math.isfinite(used) or not math.isfinite(resets):
                    continue
                if not 0 <= used <= 100:
                    continue
                return {"used": used, "resets_at": resets,
                        "observed_at": modified, "source": "codex-rollout"}
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
    return None


def herdr_reading(provider):
    """Fallback: a working pane's figure is current; idle panes keep their last turn's."""
    try:
        out = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True, timeout=5).stdout
        for a in json.loads(out)["result"]["agents"]:
            if a.get("agent") == provider and a.get("agent_status") == "working":
                m = re.search(r"\b5h (\d+)%", (a.get("tokens") or {}).get("limits") or "")
                if m:
                    return {"used": 100.0 - int(m.group(1)), "resets_at": None,
                            "observed_at": now(), "source": "herdr-pane"}
    except Exception:
        pass
    return None


def history_path():
    return os.path.join(STATE_ROOT, "quota-history.jsonl")


def load_history():
    try:
        with open(history_path()) as f:
            return [json.loads(l) for l in f if l.strip()]
    except (OSError, ValueError):
        return []


def record(hist, provider, used, resets_at):
    def append(current):
        t = now()
        last = next((h for h in reversed(current) if h["p"] == provider), None)
        if last and t - last["t"] < 60 and last["used"] == used and last.get("r") == resets_at:
            return current
        return (current + [{"t": t, "p": provider, "used": used, "r": resets_at}])[-600:]
    try:
        os.makedirs(STATE_ROOT, exist_ok=True)
        with open(history_path() + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # Another pane may have recorded a sample since snapshot() read history.
            hist = append(load_history())
            with tempfile.NamedTemporaryFile(mode="w", dir=STATE_ROOT, prefix="quota-history-", suffix=".tmp", delete=False) as f:
                tmp = f.name
                f.write("".join(json.dumps(h) + "\n" for h in hist))
            os.replace(tmp, history_path())
    except OSError:
        hist = append(hist)
    return hist


def rate_per_hour(hist, provider, resets_at):
    """Used-% per hour over the last 30 min of the same window; None without enough data."""
    t = now()
    s = [h for h in hist if h["p"] == provider and t - h["t"] <= RATE_WINDOW_S
         and (resets_at is None or h.get("r") is None or abs(h["r"] - resets_at) < 120)]
    if len(s) < 2 or s[-1]["t"] - s[0]["t"] < 300:
        return None
    return max(0.0, (s[-1]["used"] - s[0]["used"]) / ((s[-1]["t"] - s[0]["t"]) / 3600))


def snapshot(providers=PROVIDERS):
    """Quota of PROVIDERS (both by default; a run reads only its own)."""
    providers = tuple(providers)
    cache = os.path.join(STATE_ROOT, "quota-cache-" + "-".join(providers) + ".json")
    try:
        c = read_json(cache)
        if now() - c["at"] < CACHE_S and not os.environ.get("HERDR_SINGLE_NOW"):
            return c["quota"]
    except (OSError, ValueError, KeyError):
        pass
    hist = load_history()
    out = {}
    for p in providers:
        r = (claude_reading() if p == "claude" else codex_reading()) or herdr_reading(p)
        if not r:
            out[p] = {"known": False}
            continue
        used, resets = r["used"], r["resets_at"]
        note = ""
        if resets is not None and now() >= resets:
            used, resets, note = 0.0, None, "window reset since last use"
        hist = record(hist, p, used, resets)
        rate = rate_per_hour(hist, p, resets)
        mins = None if resets is None else max(0.0, (resets - now()) / 60)
        left = max(0.0, 100.0 - used)
        surplus = None
        if rate is not None and mins is not None:
            surplus = max(0.0, min(left, left - rate * mins / 60))
        elif note:
            surplus = left  # nobody is using a fresh window
        out[p] = {"known": True, "used": round(used, 1), "left": round(left, 1), "resets_at": resets,
                  "mins_to_reset": None if mins is None else round(mins), "rate_per_hour": None if rate is None else round(rate, 1),
                  "surplus": None if surplus is None else round(surplus, 1), "source": r["source"],
                  "age_s": round(now() - r["observed_at"]), "note": note}
    try:
        os.makedirs(STATE_ROOT, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=STATE_ROOT, prefix="quota-cache-", suffix=".tmp", delete=False) as f:
            tmp = f.name
            json.dump({"at": now(), "quota": out}, f)
        os.replace(tmp, cache)
    except OSError:
        pass
    return out


def suggest(x, live=0):
    """(how many more helpers to open now, why) for one window X, with LIVE helpers open.
    Never more than MAX_HELPERS live in total."""
    def room(target, why):
        return max(0, min(target, MAX_HELPERS) - live), why
    if not x.get("known"):
        return room(2, "quota unknown; open helpers sparingly")
    left, surplus, mins = x["left"], x.get("surplus"), x.get("mins_to_reset")
    if left < RESERVE:
        return 0, f"{left:.0f}% left is below the lead's {RESERVE}% reserve; no new helpers"
    if mins is not None and mins <= 45 and left >= 30:
        return room(MAX_HELPERS, f"resets in {mins:.0f} min with {left:.0f}% left; spend it")
    if surplus is None:
        if x.get("note"):
            return room(MAX_HELPERS // 2, "fresh window; no burn rate yet")
        return room(MAX_HELPERS // 2 if left >= 70 else 2, f"{left:.0f}% left; no burn rate yet")
    if surplus >= 20:
        return room(MAX_HELPERS, f"~{surplus:.0f}% would go unused at reset; spend it on helpers")
    if surplus >= 5:
        return room(MAX_HELPERS // 2, f"~{surplus:.0f}% would go unused at reset")
    return room(1, "on pace to use the window; keep helpers few")


def fmt(p, x):
    if not x.get("known"):
        return f"{p} ?"
    s = f"{p} {x['left']:.0f}% left"
    if x.get("mins_to_reset") is not None:
        s += f" (reset {time.strftime('%H:%M', time.localtime(x['resets_at']))}"
        if x.get("surplus") is not None:
            s += f", ~{x['surplus']:.0f}% would go unused"
        s += ")"
    elif x.get("note"):
        s += " (fresh window)"
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("json", "line", "suggest"))
    ap.add_argument("--provider", choices=PROVIDERS, help="the run's subscription (required for suggest)")
    ap.add_argument("--live", type=int, default=0, help="helpers already open")
    a = ap.parse_args()
    providers = (a.provider,) if a.provider else PROVIDERS
    if a.cmd == "suggest" and not a.provider:
        ap.error("suggest needs --provider")
    q = snapshot(providers)
    if a.cmd == "json":
        print(json.dumps(q, indent=2))
    elif a.cmd == "line":
        print("5h quota: " + " · ".join(fmt(p, q[p]) for p in providers))
    else:
        n, why = suggest(q[a.provider], a.live)
        print(n)
        print(why)


if __name__ == "__main__":
    main()
