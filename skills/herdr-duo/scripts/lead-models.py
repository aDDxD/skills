#!/usr/bin/env python3
"""Detect the exact lead session's model and effort, and record the fixed lead pair: Opus
(Claude) and Sol (Codex). The pair defines the sibling lead and the principal's handoff
destination. Both inherit the effort level the principal was started with, translated to
each CLI's vocabulary. Astra is never chosen: a recorded Astra destination maps to Sol."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

CLAUDE_EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')
CODEX_EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max', 'ultra')


def effort_for(provider, effort):
    """EFFORT as PROVIDER's CLI accepts it, or None when unknown."""
    if not effort:
        return None
    effort = {'minimal': 'low', 'none': 'low'}.get(effort, effort)
    if provider == 'claude':
        effort = {'ultra': 'max'}.get(effort, effort)
        return effort if effort in CLAUDE_EFFORTS else None
    return effort if effort in CODEX_EFFORTS else None


def pair(effort=None):
    env = os.environ
    fallback = env.get('HERDR_DUO_SOL_EFFORT', 'medium')
    codex = {'model': env.get('HERDR_DUO_SOL_MODEL', 'gpt-6.1-sol'),
             'effort': effort_for('codex', effort) or fallback}
    claude = {'model': env.get('HERDR_DUO_OPUS_MODEL', 'claude-opus-5-5')}
    if effort_for('claude', effort):
        claude['effort'] = effort_for('claude', effort)
    return {'codex': codex, 'claude': claude}


def transcript(info):
    """The exact session's transcript path and provider, or (None, provider)."""
    provider = info.get('agent')
    session = info.get('agent_session', {})
    sid = session.get('value')
    if session.get('kind') != 'id' or not isinstance(sid, str) or not re.fullmatch(r'[\w-]+', sid):
        return None, provider
    if provider == 'claude':
        root = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude'))
        paths = list((root / 'projects').glob('*/' + sid + '.jsonl'))
    elif provider == 'codex':
        root = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
        paths = list((root / 'sessions').glob('**/*-' + sid + '.jsonl'))
        paths += list((root / 'archived_sessions').glob('*-' + sid + '.jsonl'))
    else:
        return None, provider
    return (paths[0] if len(paths) == 1 else None), provider


def detect_all(pane):
    """(model, effort) of the session in PANE; either may be None."""
    try:
        result = subprocess.run(['herdr', 'agent', 'get', pane], check=True,
                                capture_output=True, text=True, timeout=10)
        info = json.loads(result.stdout)['result']['agent']
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return None, None
    model = next((info[k] for k in ('model', 'agent_model') if isinstance(info.get(k), str) and info[k]), None)
    effort = info.get('effort') if isinstance(info.get('effort'), str) else None
    try:
        path, provider = transcript(info)
        if path is None:
            return model, effort
        found_model = found_effort = None
        with path.open() as f:
            for line in f:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                kind = record.get('type')
                if provider == 'claude' and kind == 'assistant':
                    candidate = record.get('message', {}).get('model')
                    if isinstance(candidate, str) and candidate and candidate != '<synthetic>':
                        found_model = candidate
                elif provider == 'claude' and kind == 'api-request':
                    e = ((record.get('params') or {}).get('output_config') or {}).get('effort')
                    if isinstance(e, str) and e:
                        found_effort = e
                elif provider == 'codex' and kind == 'turn_context':
                    payload = record.get('payload', {})
                    if isinstance(payload.get('model'), str) and payload['model']:
                        found_model = payload['model']
                    if isinstance(payload.get('effort'), str) and payload['effort']:
                        found_effort = payload['effort']
        return model or found_model, effort or found_effort
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return model, effort


def detect(pane):
    return detect_all(pane)[0]


def profile(model, effort=None):
    return {'initial_model': model, 'model': model, 'band': 'opus-sol',
            'effort': effort, 'destinations': pair(effort)}


def select(lead, provider):
    """The pair model (and effort) for PROVIDER, as recorded at run creation."""
    destination = dict(lead.get('destinations', {}).get(provider) or {})
    if not destination.get('model') or 'astra' in destination['model']:
        destination = dict(pair(lead.get('effort'))[provider])
    if provider == 'codex':
        destination.setdefault('effort', pair()['codex']['effort'])
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('init')
    init.add_argument('--pane', required=True)
    init.add_argument('--model')
    init.add_argument('--effort')
    choice = sub.add_parser('select')
    choice.add_argument('--lead-file', type=Path, required=True)
    choice.add_argument('--provider', choices=('codex', 'claude'), required=True)
    detection = sub.add_parser('detect')
    detection.add_argument('--pane', required=True)
    level = sub.add_parser('effort', help='translate an effort level for a provider (empty if invalid)')
    level.add_argument('--provider', choices=('codex', 'claude'), required=True)
    level.add_argument('--value', default='')
    level.add_argument('--lead-file', type=Path, help='use the effort recorded for the principal')
    args = parser.parse_args()
    if args.command == 'effort':
        value = args.value
        if not value and args.lead_file and args.lead_file.exists():
            value = json.loads(args.lead_file.read_text()).get('effort') or ''
        print(effort_for(args.provider, value) or '')
        return
    if args.command == 'init':
        if args.effort and not (effort_for('codex', args.effort) or effort_for('claude', args.effort)):
            parser.error(f'invalid effort {args.effort!r}; use one of {", ".join(CODEX_EFFORTS)}')
        model, effort = (args.model, args.effort)
        if not model or not effort:
            found_model, found_effort = detect_all(args.pane)
            model, effort = model or found_model, effort or found_effort
        print(json.dumps(profile(model, effort)))
    elif args.command == 'detect':
        print(detect(args.pane) or '')
    else:
        destination = select(json.loads(args.lead_file.read_text()), args.provider)
        print(destination['model'])
        print(destination.get('effort', ''))


if __name__ == '__main__':
    main()
