"""Lead model routing with synthetic sessions and CLI; no live providers."""
import datetime
import importlib.util
import json
import os
import subprocess
import unittest
from unittest.mock import patch

import test_goal_handoff as goals

spec = importlib.util.spec_from_file_location('lead_models', goals.SCRIPTS / 'lead-models.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ModelTests(goals.GoalFixture, unittest.TestCase):
    def test_pairs_and_unknown(self):
        with patch.dict(os.environ, {}, clear=True):
            for model, band, codex, claude in (
                    ('claude-opus-5-5', 'opus-astra', 'gpt-6-astra', 'claude-opus-5-5'),
                    ('gpt-6-astra', 'opus-astra', 'gpt-6-astra', 'claude-opus-5-5'),
                    ('claude-sonnet-5-5', 'sonnet-sol', 'gpt-6.1-sol', 'claude-sonnet-5-5'),
                    ('gpt-6.1-sol', 'sonnet-sol', 'gpt-6.1-sol', 'claude-sonnet-5-5')):
                with self.subTest(model=model):
                    profile = m.profile(model)
                    self.assertEqual(profile['band'], band)
                    self.assertEqual(m.select(profile, 'codex')['model'], codex)
                    self.assertEqual(m.select(profile, 'claude')['model'], claude)
            for model in (None, 'gpt-6-luna', 'gpt-6-sol', 'unknown'):
                with self.assertRaises(ValueError):
                    m.select(m.profile(model), 'codex')

    def test_snapshot_overrides_and_legacy(self):
        with patch.dict(os.environ, {'HERDR_DUO_LEAD_CODEX_MODEL': 'custom-codex',
                                    'HERDR_DUO_LEAD_CLAUDE_MODEL': 'custom-claude',
                                    'HERDR_DUO_LEAD_CODEX_EFFORT': 'medium'}, clear=True):
            snapshot = m.profile('gpt-6-astra')
            self.assertEqual(m.select({}, 'claude')['model'], 'custom-claude')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(m.select(snapshot, 'codex'), {'model': 'custom-codex', 'effort': 'medium'})
            self.assertEqual(m.select(snapshot, 'claude')['model'], 'custom-claude')
            self.assertEqual(m.select({}, 'codex')['model'], 'gpt-6.1-sol')
            self.assertEqual(m.select({}, 'claude')['model'], 'claude-sonnet-5-5')

    def detect(self, info):
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({'result': {'agent': info}}))):
            return m.detect('exact-pane')

    def test_detect_metadata_and_exact_claude_transcript(self):
        info = self.info()
        self.assertEqual(self.detect(info | {'model': 'claude-opus-5-5'}), 'claude-opus-5-5')
        path = self.transcript([])
        path.write_text(json.dumps({'type': 'assistant', 'message': {'model': 'claude-opus-5-5'}}) + '\n')
        other = self.transcript([], 'other-session')
        other.write_text(json.dumps({'type': 'assistant', 'message': {'model': 'claude-sonnet-5-5'}}) + '\n')
        self.assertEqual(self.detect(info), 'claude-opus-5-5')
        duplicate = self.claude / 'projects' / 'duplicate' / 'session-1.jsonl'
        duplicate.parent.mkdir()
        duplicate.write_text(path.read_text())
        self.assertIsNone(self.detect(info))
        self.assertIsNone(self.detect(info | {'agent_session': {'kind': 'id', 'value': '../other'}}))

    def test_detect_codex_turn_context(self):
        folder = self.codex / 'sessions' / '2026' / '10' / '10'
        folder.mkdir(parents=True)
        path = folder / 'rollout-date-session-1.jsonl'
        path.write_text(json.dumps({'type': 'turn_context', 'payload': {'model': 'gpt-6-astra'}}) + '\n')
        original = path.read_bytes()
        self.assertEqual(self.detect(self.info('codex')), 'gpt-6-astra')
        self.assertEqual(path.read_bytes(), original)


class HandoffTests(goals.GoalFixture, unittest.TestCase):
    fake_herdr = goals.DeliveryTests.fake_herdr

    def setup_run(self, initial, provider='codex'):
        env = self.fake_herdr()
        env.update(HERDR_PANE_ID='old', XDG_CONFIG_HOME=str(self.root / 'config'),
                   HERDR_DUO_LEAD_FALLBACK='auto', SYNTHETIC_OLD_PROVIDER=provider,
                   SYNTHETIC_NEW_PROVIDER='claude' if provider == 'codex' else 'codex')
        for key in ('HERDR_DUO_LEAD_CODEX_MODEL', 'HERDR_DUO_LEAD_CLAUDE_MODEL'):
            env.pop(key, None)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
        executable = bin_dir / 'codex'
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        with patch.dict(os.environ, {}, clear=True):
            profile = m.profile(initial)
        goals.g.atomic_json(self.run / 'lead.json', {
            'name': 'lead1', 'pane': 'old', 'kind': provider,
            'generation': 1, 'status': 'active', **profile})
        return env

    def handoff(self, env, *extra):
        return subprocess.run(['bash', str(goals.SCRIPTS / 'handoff.sh'), '--run', str(self.run),
                               '--reason', 'synthetic quota test', *extra], env=env,
                              capture_output=True, text=True, timeout=20)

    def calls(self):
        return [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]

    def test_launch_arguments_both_bands_and_providers(self):
        for initial, provider, target in (
                ('gpt-6-astra', 'codex', 'claude-opus-5-5'),
                ('claude-opus-5-5', 'claude', 'gpt-6-astra'),
                ('gpt-6.1-sol', 'codex', 'claude-sonnet-5-5'),
                ('claude-sonnet-5-5', 'claude', 'gpt-6.1-sol')):
            with self.subTest(initial=initial):
                env = self.setup_run(initial, provider)
                (self.root / 'calls.jsonl').unlink(missing_ok=True)
                result = self.handoff(env)
                self.assertEqual(result.returncode, 0, result.stderr)
                starts = [c for c in self.calls() if c[:2] == ['agent', 'start']]
                self.assertEqual(len(starts), 1)
                self.assertIn(target, starts[0])
                lead = goals.g.read_json(self.run / 'lead.json')
                self.assertEqual(lead['model'], target)
                self.assertEqual(lead['initial_model'], initial)
                self.assertEqual(lead['history'][0]['model'], initial)
                self.assertEqual(lead['band'], m.band_for(initial))
                self.assertFalse(any(c[:3] == ['agent', 'prompt', 'old'] for c in self.calls()))

    def test_unknown_stops_before_opening_pane_then_explicit_resolution(self):
        env = self.setup_run(None)
        result = self.handoff(env)
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown', result.stderr)
        self.assertFalse((self.root / 'calls.jsonl').exists())
        result = self.handoff(env, '--lead-model', 'gpt-6-astra')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(goals.g.read_json(self.run / 'lead.json')['band'], 'opus-astra')

    def test_exhausted_provider_stays_blocked_without_lowering_band(self):
        env = self.setup_run('gpt-6-astra')
        lead = goals.g.read_json(self.run / 'lead.json')
        lead['exhausted'] = {'claude': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        goals.g.atomic_json(self.run / 'lead.json', lead)
        result = self.handoff(env)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertFalse((self.root / 'calls.jsonl').exists())
        self.assertEqual(goals.g.read_json(self.run / 'lead.json')['band'], 'opus-astra')

    def test_adoption_preserves_pair(self):
        env = self.setup_run('gpt-6-astra')
        env['HERDR_PANE_ID'] = 'new'
        result = subprocess.run(['bash', str(goals.SCRIPTS / 'handoff.sh'), '--run', str(self.run),
                                 '--adopt'], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lead = goals.g.read_json(self.run / 'lead.json')
        self.assertEqual(lead['pane'], 'new')
        self.assertEqual(lead['band'], 'opus-astra')
        self.assertEqual(m.select(lead, 'codex')['model'], 'gpt-6-astra')

    def test_existing_band_cannot_be_replaced_by_resolution_flag(self):
        env = self.setup_run('gpt-6-astra')
        result = self.handoff(env, '--lead-model', 'gpt-6.1-sol')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(goals.g.read_json(self.run / 'lead.json')['band'], 'opus-astra')

    def test_two_generations_keep_initial_band_despite_config_change(self):
        env = self.setup_run('gpt-6-astra')
        first = self.handoff(env)
        self.assertEqual(first.returncode, 0, first.stderr)
        lead = goals.g.read_json(self.run / 'lead.json')
        # Make the synthetic successor the next old pane and simulate quota reset.
        lead['pane'] = 'old'
        lead['exhausted'] = {}
        goals.g.atomic_json(self.run / 'lead.json', lead)
        env.update(SYNTHETIC_OLD_PROVIDER='claude', SYNTHETIC_NEW_PROVIDER='codex',
                   HERDR_DUO_LEAD_CODEX_MODEL='gpt-6.1-sol')
        second = self.handoff(env)
        self.assertEqual(second.returncode, 0, second.stderr)
        lead = goals.g.read_json(self.run / 'lead.json')
        self.assertEqual(lead['generation'], 3)
        self.assertEqual(lead['initial_model'], 'gpt-6-astra')
        self.assertEqual(lead['model'], 'gpt-6-astra')
        self.assertEqual([h['model'] for h in lead['history']],
                         ['gpt-6-astra', 'claude-opus-5-5'])

    def test_run_init_records_profile_and_live_strong_excludes_lead(self):
        env = self.setup_run('gpt-6-astra')
        env['HERDR_DUO_STATE_ROOT'] = str(self.root / 'state')
        repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Synthetic',
                        '-c', 'user.email=synthetic@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-q', '--allow-empty', '-m', 'Synthetic baseline'],
                       check=True, capture_output=True)
        result = subprocess.run(['bash', str(goals.SCRIPTS / 'run-init.sh'), '--repo', str(repo),
                                 '--no-panel', '--lead-model', 'gpt-6-astra'], env=env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        run_dir = next((self.root / 'state' / 'runs').glob('*/*'))
        lead = goals.g.read_json(run_dir / 'lead.json')
        self.assertEqual(lead['initial_model'], 'gpt-6-astra')
        self.assertEqual(lead['band'], 'opus-astra')
        self.assertEqual(lead['destinations']['claude']['model'], 'claude-opus-5-5')
        state = goals.g.read_json(run_dir / 'state.json')
        state['workers'] = [{'name': 'single-strong', 'tier': 'strong', 'status': 'dispatched'}]
        goals.g.atomic_json(run_dir / 'state.json', state)
        result = subprocess.run(['bash', '-c', '. "$1"; live_strong "$2"', 'test',
                                 str(goals.SCRIPTS / 'common.sh'), str(run_dir)], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'single-strong')


if __name__ == '__main__':
    unittest.main()
