#!/usr/bin/env bash
# Start a herdr-duo run for any git repository. Creates the run directory and
# state.json outside the repository, then prints the facts the lead needs as
# literal absolute paths (shell variables do not survive between tool calls).
#
# Usage: run-init.sh --repo DIR [--goal TEXT] [--lead-model MODEL] [--lead-effort LEVEL] [--commit] [--push] [--no-panel]
#   --lead-model / --lead-effort supply the principal's actual model and effort when the
#   exact session cannot be read; the sibling and any successor inherit that effort.
#   --commit / --push only when the user's initial request explicitly asked for them.
# Inside Herdr it also records the calling pane as the run's principal lead (lead.json),
# opens the status panel with the lead watchdog to the right of it, and records which
# subscription led this task, so the next task can start on the other one.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

repo=""; goal=""; commit=false; push=false; panel=yes; lead_model=""; lead_effort=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --goal) goal=$2; shift 2 ;;
    --lead-model) lead_model=$2; shift 2 ;;
    --lead-effort) lead_effort=$2; shift 2 ;;
    --worker-tier) echo "note: --worker-tier is ignored; leads choose helper models per task" >&2; shift 2 ;;
    --commit) commit=true; shift ;;
    --push) push=true; shift ;;
    --no-panel) panel=no; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] || die "--repo is required"
if [ -n "$lead_effort" ] && [ -z "$(lead_models effort --provider codex --value "$lead_effort")" ]; then
  die "--lead-effort must be one of: low medium high xhigh max ultra"
fi
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repository: $repo. Run 'git init' and make an initial commit (workers start from HEAD)"
repo=$top
git -C "$repo" rev-parse --verify -q HEAD >/dev/null \
  || die "no commits in $repo yet. Make an initial commit (workers start from HEAD)"

slug="$(basename "$repo")-$(printf %s "$repo" | sha256sum | cut -c1-8)"
run="$HERDR_DUO_STATE_ROOT/runs/$slug/$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "$run" ] || run="$run-$$"
# Stable worktree root per repository, so agent trust prompts are answered once per worker name.
wt_root="$HERDR_DUO_STATE_ROOT/wt/$slug"
mkdir -p "$run" "$wt_root"

branch=$(git -C "$repo" symbolic-ref -q --short HEAD || echo "(detached)")
head=$(git -C "$repo" rev-parse HEAD)
default_branch=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
if [ -z "$default_branch" ]; then
  for b in main master trunk; do
    git -C "$repo" show-ref -q --verify "refs/heads/$b" && { default_branch=$b; break; }
  done
fi
modified=$(git -C "$repo" status --porcelain --untracked-files=no | wc -l)
untracked=$(git -C "$repo" ls-files --others --exclude-standard | wc -l)

instructions=""
for f in AGENTS.md CLAUDE.md CONTRIBUTING.md README.md package.json Makefile justfile pyproject.toml Cargo.toml go.mod; do
  [ -e "$repo/$f" ] && instructions="$instructions $f"
done

deps=""
while IFS= read -r d; do
  d=${d%/}
  for name in $HERDR_DUO_DEPS_NAMES; do
    [ "$(basename "$d")" = "$name" ] && deps="$deps $d"
  done
done < <(git -C "$repo" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

stale=""
for d in "$wt_root"/*/; do
  [ -d "$d" ] && stale="$stale $(basename "$d")"
done

python3 - "$run/state.json" "$repo" "$branch" "$head" "$default_branch" "$commit" "$push" "$goal" "$wt_root" <<'PY'
import json, sys, datetime
path, repo, branch, head, default_branch, commit, push, goal, wt_root = sys.argv[1:]
json.dump({
    "goal": goal, "repo": repo, "branch": branch, "head": head,
    "default_branch": default_branch or None,
    "commit_authorized": commit == "true", "push_authorized": push == "true",
    "wt_root": wt_root, "workers": [], "reviewers": [], "status": "planning",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(path, "w"), indent=2)
PY

cat <<EOF
SKILL_DIR=$(dirname "$(dirname "$(realpath "$0")")")
RUN=$run
WT_ROOT=$wt_root
REPO=$repo
branch: $branch  head: ${head:0:12}  default_branch: ${default_branch:-unknown}
commit_authorized: $commit  push_authorized: $push
uncommitted: $modified modified tracked, $untracked untracked (use --from-checkout if workers need them)
instruction_files:${instructions:- none}
deps_candidates:${deps:- none}  (pass --deps-auto to copy them)
stale_worktrees_in_WT_ROOT:${stale:- none}  (integrate or remove before reusing a name)
lead pair: claude=$HERDR_DUO_OPUS_MODEL  codex=$HERDR_DUO_SOL_MODEL
helpers: claude=$HERDR_DUO_HAIKU_MODEL  codex=$HERDR_DUO_LUNA_MODEL (effort $HERDR_DUO_HELPER_EFFORT); any model via spawn.sh --model
access: codex=$HERDR_DUO_CODEX_ACCESS  claude=$HERDR_DUO_CLAUDE_MODE
EOF
quota line || true

# The lead is the pane that started the run; the panel and handoff build on this record.
if [ -n "${HERDR_PANE_ID:-}" ]; then
  lead_kind=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"].get("agent") or "")' 2>/dev/null || true)
  profile_args=(init --pane "$HERDR_PANE_ID")
  [ -z "$lead_model" ] || profile_args+=(--model "$lead_model")
  [ -z "$lead_effort" ] || profile_args+=(--effort "$lead_effort")
  lead_profile=$(lead_models "${profile_args[@]}")
  panel_pane=""
  if [ "$panel" = yes ]; then
    script_dir=$(dirname "$(realpath "$0")")
    if [[ "$script_dir$run" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] \
      && split_out=$(herdr pane split "$HERDR_PANE_ID" --direction right --cwd "$repo" --no-focus 2>/dev/null); then
      panel_pane=$(printf %s "$split_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' 2>/dev/null || true)
      [ -z "$panel_pane" ] || {
        herdr pane rename "$panel_pane" "herdr-duo panel" >/dev/null 2>&1 || true
        herdr pane run "$panel_pane" "$script_dir/panel.sh --run $run" >/dev/null 2>&1 || true
      }
    fi
  fi
  python3 - "$run/lead.json" "$HERDR_PANE_ID" "$lead_kind" "$panel_pane" "$lead_profile" <<'PY'
import json, sys
path, pane, kind, panel, profile = sys.argv[1:]
json.dump({"name": "lead1", "pane": pane, "kind": kind or None, "generation": 1, "status": "active",
           "panel_pane": panel or None, **json.loads(profile)}, open(path, "w"), indent=2)
PY
  echo "lead: pane $HERDR_PANE_ID (${lead_kind:-unknown provider})  panel: ${panel_pane:-not started}  handoff: $HERDR_DUO_LEAD_FALLBACK"
  echo "lead model: $(json_get "$run/lead.json" model)  effort: $(json_get "$run/lead.json" effort || true)  sibling/successor: $(json_get "$run/lead.json" destinations)"
  echo "effort parity: sibling inherits the principal's effort; helpers run at $HERDR_DUO_HELPER_EFFORT"
  # The next task should start on the other subscription when headroom is similar.
  [ -z "$lead_kind" ] || python3 - "$HERDR_DUO_STATE_ROOT/balance.json" "$lead_kind" "$run" <<'PY'
import json, os, sys, datetime
path, kind, run = sys.argv[1:]
try: b = json.load(open(path))
except (OSError, ValueError): b = {}
b["last_principal"] = kind
b["history"] = (b.get("history", []) + [{"run": run, "principal": kind,
                "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}])[-50:]
with open(path + ".tmp", "w") as f: json.dump(b, f, indent=2)
os.replace(path + ".tmp", path)
PY
fi

# Hint for a failed origin check. Never prints the URL itself, so no credentials leak.
push_hint() {
  case "$1" in
    https://*)
      if compgen -G "$HOME/.ssh/id_*.pub" >/dev/null; then
        echo "credentials are not available to git for https; an SSH key exists, so run 'git remote set-url origin git@github.com:OWNER/REPO.git' (ask the user first)"
      else
        echo "credentials are not available to git for https; run 'gh auth setup-git' (ask the user first)"
      fi ;;
    *) echo "check the remote URL and access: git ls-remote origin" ;;
  esac
}

origin_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
# Mask user:password@ in the printed URL.
origin_shown=$(printf '%s' "$origin_url" | sed -E 's#^([a-zA-Z+.-]+://)[^/@]*@#\1***@#')
echo "remote: ${origin_shown:-none}"
if [ "$push" = true ]; then
  if [ -z "$origin_url" ]; then
    echo "push_check: skipped (no origin remote)"
  elif GIT_TERMINAL_PROMPT=0 timeout 15 git -C "$repo" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "push_check: ok"
  else
    echo "push_check: FAILED ($(push_hint "$origin_url"))"
  fi
fi
