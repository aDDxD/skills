#!/usr/bin/env python3
"""Read session-owned goals and restore them through Herdr; never edit provider state."""
import argparse
from contextlib import closing
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def agent_info(pane):
    result = subprocess.run(['herdr', 'agent', 'get', pane], check=True,
                            capture_output=True, text=True, timeout=10)
    return json.loads(result.stdout)['result']['agent']


def native_goal(info):
    """Return None for unavailable storage; status=none means authoritative absence."""
    session = info.get('agent_session', {})
    sid = session.get('value')
    if session.get('kind') != 'id' or not isinstance(sid, str) or not re.fullmatch(r'[\w-]+', sid):
        return None
    provider = info.get('agent')
    if provider == 'codex':
        root = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
        # The schema is private: fail closed on changes, never create or migrate it.
        databases = sorted((p for p in root.glob('goals_*.sqlite')
                            if re.fullmatch(r'goals_\d+\.sqlite', p.name)),
                           key=lambda p: int(p.stem.split('_')[-1]), reverse=True)
        if not databases:
            return None
        try:
            with closing(sqlite3.connect(databases[0].resolve().as_uri() + '?mode=ro', uri=True,
                                         timeout=1)) as db:
                db.row_factory = sqlite3.Row
                row = db.execute('SELECT objective,status,token_budget,tokens_used,'
                                 'time_used_seconds,updated_at_ms FROM thread_goals '
                                 'WHERE thread_id=?', (sid,)).fetchone()
            if row is None:
                return {'status': 'none', 'session_id': sid, 'provider': provider}
            goal = dict(row)
            if goal['token_budget'] is not None:
                goal['remaining_tokens'] = max(0, goal['token_budget'] - goal['tokens_used'])
        except (OSError, sqlite3.Error):
            return None
    elif provider == 'claude':
        root = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude'))
        paths = list((root / 'projects').glob('*/' + sid + '.jsonl'))
        if not paths:
            return None
        if len(paths) != 1:
            return None
        goal = {'status': 'none'}
        try:
            with paths[0].open() as transcript:
                for line in transcript:
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue  # A writer may still be appending the final line.
                    attachment = record.get('attachment', {})
                    if record.get('type') != 'attachment' or attachment.get('type') != 'goal_status':
                        continue
                    condition = attachment.get('condition')
                    if not isinstance(condition, str) or not condition.strip():
                        return None
                    goal = {'objective': condition,
                            'status': 'complete' if attachment.get('met') else
                                      'blocked' if attachment.get('failed') else 'active'}
        except OSError:
            return None
    else:
        return None
    goal.update(session_id=sid, provider=provider)
    return goal


def capture(run, pane):
    try:
        goal = native_goal(agent_info(pane))
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        goal = None
    if goal is None:
        portable = read_json(run / 'goal.json', {})
        goal = dict(portable) if portable.get('objective') else {'status': 'unknown'}
        goal['source'] = 'portable' if portable.get('objective') else 'unavailable'
    else:
        goal['source'] = 'native'
    previous = read_json(run / 'goal-native.json', {})
    transfer = read_json(run / 'goal-transfer.json', {})
    objective = goal.get('objective', '')
    if (objective and transfer.get('pane') == pane and
            transfer.get('objective_sha256') == hashlib.sha256(objective.encode()).hexdigest()):
        # Do not append recovery instructions again on every provider switch.
        goal['objective'] = previous.get('objective', objective)
        if goal.get('provider') == 'claude' and (previous.get('token_budget') is not None or
                                               previous.get('remaining_tokens') is not None or
                                               previous.get('budget_accounting_unavailable')):
            goal['inherited_budget'] = previous.get('inherited_budget') or {
                k: previous.get(k) for k in ('token_budget', 'tokens_used', 'remaining_tokens')}
            # Claude does not expose equivalent budget accounting. Never present
            # an old allowance as measured remaining budget after it did work.
            goal['budget_accounting_unavailable'] = True
    # A manual checkpoint can preserve explicit user pause even if a native hook
    # is still active. Goal state must never grant fresh permissions or budget.
    portable = read_json(run / 'goal.json', {})
    budget = goal.get('budget', {})
    if isinstance(budget, dict):
        for key in ('token_budget', 'tokens_used', 'remaining_tokens'):
            if key in budget and key not in goal:
                goal[key] = budget[key]
    if portable.get('status') == 'paused':
        goal['status'] = 'paused'
    goal['captured_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    goal['pane'] = pane
    atomic_json(run / 'goal-native.json', goal)
    return goal


def transferable(source, provider):
    # Provider quota is why leadership changes; it does not revoke the goal.
    # A user pause or a goal token budget is different and remains binding.
    return source.get('status') == 'active' or (
        source.get('status') == 'usage_limited' and source.get('source') == 'native' and
        source.get('provider') in ('claude', 'codex') and source['provider'] != provider)


def command_for(run, source, provider):
    if not transferable(source, provider) or not source.get('objective', '').strip():
        return None, 'inactive'
    if source.get('remaining_tokens') == 0 or (
            source.get('token_budget') is not None and
            source.get('tokens_used', 0) >= source['token_budget']):
        return None, 'budget_exhausted'
    # /goal has no token-budget argument. A budgeted Codex goal must be created
    # using the successor's native tool with the remaining allowance instead.
    if provider == 'codex' and (source.get('token_budget') is not None or
                                source.get('remaining_tokens') is not None or
                                source.get('budget_accounting_unavailable')):
        return None, 'needs_budget_tool'
    context = (f'\n\nLeadership continuation: first read {run}/lead-resume.md and '
               'goal-native.json in that directory. Resume existing workers and finish '
               'the inherited task within its recorded authorization and remaining budget.')
    objective = source['objective'] + context
    if provider == 'claude' and len(objective.encode('utf-16-le')) // 2 > 4000:
        # Preserve the entire objective in the checkpoint, rather than truncate it.
        objective = ('Complete the exact inherited objective and remaining acceptance criteria '
                     f'recorded in {run}/goal-native.json.' + context)
    if provider == 'claude' and len(objective.encode('utf-16-le')) // 2 > 4000:
        return None, 'command_too_long'
    return objective, 'ready'


def restore(run, pane):
    source = read_json(run / 'goal-native.json', {})
    transfer_path = run / 'goal-transfer.json'
    transfer = read_json(transfer_path, {})
    info = agent_info(pane)
    provider = info.get('agent')
    if provider not in ('codex', 'claude'):
        return 'fallback'
    objective, reason = command_for(run, source, provider)
    current = native_goal(info)
    if current and current.get('status') not in ('none',):
        # Never replace a live goal (including one set by the user in this pane).
        same = (current.get('status') == 'active' and transferable(source, provider) and
                objective is not None and current.get('objective') == objective)
        atomic_json(transfer_path, {'pane': pane, 'status': 'verified' if same else 'existing_goal',
                                    'objective_sha256': hashlib.sha256(current.get('objective', '').encode()).hexdigest()})
        return 'started' if same else 'fallback'
    if objective is None:
        atomic_json(transfer_path, {'pane': pane, 'status': reason})
        return 'fallback'
    if transfer.get('pane') == pane and transfer.get('status') in ('submitting', 'unconfirmed', 'verified'):
        return 'fallback'  # Ambiguous delivery is never blindly repeated.
    if info.get('agent_status') not in ('idle', 'done'):
        return 'defer'
    # caller checked the dialog; Herdr also atomically rejects blocked agents.
    attempt = {'pane': pane, 'status': 'submitting',
               'objective_sha256': hashlib.sha256(objective.encode()).hexdigest()}
    atomic_json(transfer_path, attempt)
    try:
        subprocess.run(['herdr', 'agent', 'prompt', pane, '/goal ' + objective],
                       check=True, capture_output=True, text=True, timeout=10)
    except subprocess.SubprocessError:
        atomic_json(transfer_path, attempt | {'status': 'unconfirmed'})
        return 'fallback'
    for _ in range(8):
        try:
            current = native_goal(agent_info(pane))
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            current = None
        if current and current.get('status') == 'active' and current.get('objective') == objective:
            atomic_json(transfer_path, attempt | {'status': 'verified'})
            return 'started'
        time.sleep(0.25)
    atomic_json(transfer_path, attempt | {'status': 'unconfirmed'})
    return 'fallback'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('capture', 'restore'))
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--pane', required=True)
    args = parser.parse_args()
    if args.mode == 'capture':
        print(capture(args.run, args.pane)['status'])
    else:
        try:
            print(restore(args.run, args.pane))
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
            print('fallback')


if __name__ == '__main__':
    main()
