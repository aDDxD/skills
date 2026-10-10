#!/usr/bin/env python3
"""Detect the exact lead session's model and preserve its handoff pair."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def band_for(model):
    if re.fullmatch(r'(?:claude-)?opus(?:-[\w.-]+)?|gpt-6-astra', model or ''):
        return 'opus-astra'
    if re.fullmatch(r'(?:claude-)?sonnet(?:-[\w.-]+)?|gpt-6\.1-sol', model or ''):
        return 'sonnet-sol'
    return None


def detect(pane):
    try:
        result = subprocess.run(['herdr', 'agent', 'get', pane], check=True,
                                capture_output=True, text=True, timeout=10)
        info = json.loads(result.stdout)['result']['agent']
        provider = info.get('agent')
        for key in ('model', 'agent_model'):
            model = info.get(key)
            if isinstance(model, str) and model:
                return model
        session = info.get('agent_session', {})
        sid = session.get('value')
        if session.get('kind') != 'id' or not isinstance(sid, str) or not re.fullmatch(r'[\w-]+', sid):
            return None
        if provider == 'claude':
            root = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude'))
            paths = list((root / 'projects').glob('*/' + sid + '.jsonl'))
        elif provider == 'codex':
            root = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
            paths = list((root / 'sessions').glob('**/*-' + sid + '.jsonl'))
            paths += list((root / 'archived_sessions').glob('*-' + sid + '.jsonl'))
        else:
            return None
        if len(paths) != 1:
            return None
        model = None
        with paths[0].open() as transcript:
            for line in transcript:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if provider == 'claude' and record.get('type') == 'assistant':
                    candidate = record.get('message', {}).get('model')
                elif provider == 'codex' and record.get('type') == 'turn_context':
                    candidate = record.get('payload', {}).get('model')
                else:
                    continue
                if isinstance(candidate, str) and candidate and candidate != '<synthetic>':
                    model = candidate
        return model
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError):
        return None


def profile(model):
    band = band_for(model)
    env = os.environ
    if band == 'opus-astra':
        codex = env.get('HERDR_DUO_LEAD_ASTRA_MODEL', 'gpt-6-astra')
        claude = env.get('HERDR_DUO_LEAD_OPUS_MODEL', 'claude-opus-5-5')
    elif band == 'sonnet-sol':
        codex = env.get('HERDR_DUO_SOL_MODEL', 'gpt-6.1-sol')
        claude = env.get('HERDR_DUO_SONNET_MODEL', 'claude-sonnet-5-5')
    else:
        codex = claude = None
    return {'initial_model': model, 'model': model, 'band': band,
            'destinations': {
                'codex': {'model': env.get('HERDR_DUO_LEAD_CODEX_MODEL') or codex,
                          'effort': env.get('HERDR_DUO_LEAD_CODEX_EFFORT', 'high')},
                'claude': {'model': env.get('HERDR_DUO_LEAD_CLAUDE_MODEL') or claude}}}


def select(lead, provider):
    if 'destinations' in lead:
        destination = lead['destinations'].get(provider, {})
        if not destination.get('model'):
            raise ValueError('lead model band is unknown; use handoff.sh --lead-model MODEL '
                             'with the original lead model to resolve it before handoff')
        return destination
    # Existing runs predate model snapshots and retain their configured behavior.
    env = os.environ
    if provider == 'codex':
        return {'model': env.get('HERDR_DUO_LEAD_CODEX_MODEL') or env.get('HERDR_DUO_SOL_MODEL', 'gpt-6.1-sol'),
                'effort': env.get('HERDR_DUO_LEAD_CODEX_EFFORT', 'high')}
    return {'model': env.get('HERDR_DUO_LEAD_CLAUDE_MODEL') or env.get('HERDR_DUO_SONNET_MODEL', 'claude-sonnet-5-5')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('init')
    init.add_argument('--pane', required=True)
    init.add_argument('--model')
    choice = sub.add_parser('select')
    choice.add_argument('--lead-file', type=Path, required=True)
    choice.add_argument('--provider', choices=('codex', 'claude'), required=True)
    detection = sub.add_parser('detect')
    detection.add_argument('--pane', required=True)
    args = parser.parse_args()
    if args.command == 'init':
        print(json.dumps(profile(args.model or detect(args.pane))))
    elif args.command == 'detect':
        print(detect(args.pane) or '')
    else:
        try:
            destination = select(json.loads(args.lead_file.read_text()), args.provider)
        except ValueError as error:
            parser.exit(2, f'ERROR: {error}\n')
        print(destination['model'])
        print(destination.get('effort', ''))


if __name__ == '__main__':
    main()
