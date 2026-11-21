#!/usr/bin/env python3
"""Who is who in a herdr-single run.

A run has one lead (lead.json), the status panel, and helpers and reviewers the lead
owns. There is no sibling lead: the run uses one subscription only.

Usage: members.py whoami RUN PANE   -> lead | panel | outsider
       members.py find PANE         -> "<run dir> lead" of the newest active run PANE leads
"""
import glob, json, os, sys

STATE_ROOT = os.environ.get("HERDR_SINGLE_STATE_ROOT") or os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "herdr-single")


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def whoami(run, pane):
    lead = load(os.path.join(run, "lead.json"), {})
    if pane == lead.get("pane"):
        return "lead"
    if pane == lead.get("panel_pane"):
        return "panel"
    return "outsider"


def find(pane):
    leads = glob.glob(os.path.join(STATE_ROOT, "runs", "*", "*", "lead.json"))
    dated = []
    for lj in leads:
        try:
            dated.append((os.path.getmtime(lj), lj))
        except OSError:
            continue
    for _, lj in sorted(dated, reverse=True):
        run = os.path.dirname(lj)
        state = load(os.path.join(run, "state.json"), {})
        if state.get("status") == "finished":
            continue
        if whoami(run, pane) == "lead":
            return run, "lead"
    return None, None


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "whoami":
        print(whoami(sys.argv[2], sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "find":
        run, role = find(sys.argv[2])
        if run:
            print(run, role)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
