#!/usr/bin/env python3
"""Find room for a new session pane and create it. Prints "PANE_ID TAB_ID".

Splits the largest pane this run owns (workers, reviewers, and the status panel in the
lead's tab) along its longer side, so panes stay balanced instead of piling up next to
the lead. A split is allowed only when both halves stay at least MIN_COLS x MIN_ROWS
(the panel keeps PANEL_ROWS). The lead's pane and panes the run does not own are never
split. When nothing fits, it opens a new tab ("duo 2", "duo 3", ...) for further sessions.

Usage: place.py RUN_DIR CWD"""
import fcntl, json, os, subprocess, sys

MIN_COLS = int(os.environ.get("HERDR_DUO_MIN_PANE_COLS", "70"))
MIN_ROWS = int(os.environ.get("HERDR_DUO_MIN_PANE_ROWS", "18"))
PANEL_ROWS = 20


def herdr(*args):
    r = subprocess.run(["herdr", *args], capture_output=True, text=True, timeout=20)
    if r.returncode != 0:
        raise RuntimeError(f"herdr {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return json.loads(r.stdout)["result"]


def direction(rect, min_rows):
    """Best split direction for a pane, or None when a half would be too small.
    A terminal cell is about twice as tall as wide, so compare width with 2 x height."""
    w, h = rect["width"], rect["height"]
    right = w // 2 >= MIN_COLS and h >= min_rows
    down = h // 2 >= min_rows and w >= MIN_COLS
    if right and down:
        return "right" if w >= 2 * h else "down"
    return "right" if right else "down" if down else None


def choose(candidates):
    """candidates: [(pane_id, rect, min_rows)] -> (pane_id, direction) or None."""
    best = None
    for pane, rect, min_rows in candidates:
        d = direction(rect, min_rows)
        if d and (best is None or rect["width"] * rect["height"] > best[2]):
            best = (pane, d, rect["width"] * rect["height"])
    return best[:2] if best else None


def main():
    run, cwd = sys.argv[1], sys.argv[2]
    state = json.load(open(os.path.join(run, "state.json")))
    lead = {}
    if os.path.exists(os.path.join(run, "lead.json")):
        lead = json.load(open(os.path.join(run, "lead.json")))
    live = [r for k in ("workers", "reviewers") for r in state.get(k, [])
            if r.get("pane") and r.get("status") not in ("cleaned", "escalated")]
    owned = {r["pane"]: MIN_ROWS for r in live}
    if lead.get("panel_pane"):
        owned[lead["panel_pane"]] = PANEL_ROWS

    # Tabs to try, in order: the lead's tab, then the tabs this run opened.
    probes = []
    anchor = lead.get("pane") or os.environ.get("HERDR_PANE_ID")
    if anchor:
        probes.append(anchor)
    for tab in state.get("tabs", []):
        probes += [r["pane"] for r in live if r.get("tab") == tab][:1]
    seen = set()
    for probe in probes:
        try:
            layout = herdr("pane", "layout", "--pane", probe)["layout"]
        except Exception:
            continue
        if layout["tab_id"] in seen:
            continue
        seen.add(layout["tab_id"])
        pick = choose([(p["pane_id"], p["rect"], owned[p["pane_id"]])
                       for p in layout["panes"] if p["pane_id"] in owned])
        if pick:
            res = herdr("pane", "split", pick[0], "--direction", pick[1], "--cwd", cwd, "--no-focus")
            print(res["pane"]["pane_id"], layout["tab_id"])
            return

    # No room left in any tab: open a new one. Its first pane is used as is.
    label = f"duo {len(state.get('tabs', [])) + 2}"
    res = herdr("tab", "create", "--label", label, "--cwd", cwd, "--no-focus")
    tab = res["tab"]["tab_id"]
    path = os.path.join(run, "state.json")
    with open(path + ".lock", "w") as lock:  # same lock as state_edit in common.sh
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.load(open(path))
        state.setdefault("tabs", []).append(tab)
        with open(path + ".tmp", "w") as f:
            json.dump(state, f, indent=2)
        os.replace(path + ".tmp", path)
    print(res["root_pane"]["pane_id"], tab)


if __name__ == "__main__":
    main()
