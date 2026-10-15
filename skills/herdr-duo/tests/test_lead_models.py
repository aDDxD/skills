"""Lead pair, model detection and principal handoff with synthetic sessions and a fake
Herdr CLI; no live providers."""
import importlib.util
import json
import os
import subprocess
import time
import unittest
from unittest.mock import patch

import test_goal_handoff as goals

spec = importlib.util.spec_from_file_location('lead_models', goals.SCRIPTS / 'lead-models.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ModelTests(goals.GoalFixture, unittest.TestCase):
    def test_fixed_pair_for_any_lead(self):
        with patch.dict(os.environ, {}, clear=True):
            for model in ('claude-opus-5-5', 'gpt-6.1-sol', 'claude-sonnet-5-5', None):
                with self.subTest(model=model):
                    profile = m.profile(model)
                    self.assertEqual(profile['band'], 'opus-sol')
                    self.assertEqual(m.select(profile, 'codex'), {'model': 'gpt-6.1-sol', 'effort': 'medium'})
                    self.assertEqual(m.select(profile, 'claude')['model'], 'claude-opus-5-5')

    def test_snapshot_and_legacy_runs_never_pick_astra(self):
        with patch.dict(os.environ, {'HERDR_DUO_SOL_MODEL': 'custom-sol', 'HERDR_DUO_SOL_EFFORT': 'high'}, clear=True):
            snapshot = m.profile('claude-opus-5-5')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(m.select(snapshot, 'codex'), {'model': 'custom-sol', 'effort': 'high'})
            legacy = {'band': 'opus-astra', 'destinations': {'codex': {'model': 'gpt-6-astra', 'effort': 'medium'},
                                                            'claude': {'model': 'claude-opus-5-5'}}}
            self.assertEqual(m.select(legacy, 'codex')['model'], 'gpt-6.1-sol')
            self.assertEqual(m.select({}, 'claude')['model'], 'claude-opus-5-5')

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

    def test_detect_effort_from_both_transcripts(self):
        path = self.transcript([])
        path.write_text('\n'.join(json.dumps(r) for r in (
            {'type': 'api-request', 'params': {'output_config': {'effort': 'xhigh'}}},
            {'type': 'assistant', 'message': {'model': 'claude-opus-5-5'}},
            {'type': 'api-request', 'params': {'output_config': {'effort': 'low'}}})) + '\n')
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({'result': {'agent': self.info()}}))):
            self.assertEqual(m.detect_all('exact-pane'), ('claude-opus-5-5', 'low'))
        folder = self.codex / 'sessions' / '2026' / '10' / '11'
        folder.mkdir(parents=True)
        (folder / 'rollout-date-session-1.jsonl').write_text(json.dumps(
            {'type': 'turn_context', 'payload': {'model': 'gpt-6.1-sol', 'effort': 'medium'}}) + '\n')
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({'result': {'agent': self.info('codex')}}))):
            self.assertEqual(m.detect_all('exact-pane'), ('gpt-6.1-sol', 'medium'))
        profile = m.profile('gpt-6.1-sol', 'ultra')
        self.assertEqual((profile['destinations']['codex']['effort'], profile['destinations']['claude']['effort']),
                         ('ultra', 'max'))

    def test_detect_codex_turn_context(self):
        folder = self.codex / 'sessions' / '2026' / '10' / '10'
        folder.mkdir(parents=True)
        path = folder / 'rollout-date-session-1.jsonl'
        path.write_text(json.dumps({'type': 'turn_context', 'payload': {'model': 'gpt-6.1-sol'}}) + '\n')
        original = path.read_bytes()
        self.assertEqual(self.detect(self.info('codex')), 'gpt-6.1-sol')
        self.assertEqual(path.read_bytes(), original)


class HandoffTests(goals.GoalFixture, unittest.TestCase):
    fake_herdr = goals.DeliveryTests.fake_herdr

    def setup_run(self, initial, provider='codex', workers=()):
        env = self.fake_herdr()
        env.update(HERDR_PANE_ID='old', XDG_CONFIG_HOME=str(self.root / 'config'),
                   HERDR_DUO_LEAD_FALLBACK='auto', SYNTHETIC_OLD_PROVIDER=provider,
                   SYNTHETIC_NEW_PROVIDER='claude' if provider == 'codex' else 'codex')
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
        goals.g.atomic_json(self.run / 'state.json', {'repo': str(self.root), 'workers': list(workers), 'reviewers': []})
        return env

    def claude_limits(self, used, resets_in_s):
        path = self.claude / 'herdr-usagebar' / 'claude-limits-latest.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'fiveHour': {'usedPercentage': used, 'resetsAt': time.time() + resets_in_s},
                                    'fetchedAtMs': time.time() * 1000}))

    def handoff(self, env, *extra):
        return subprocess.run(['bash', str(goals.SCRIPTS / 'handoff.sh'), '--run', str(self.run),
                               '--reason', 'synthetic quota test', *extra], env=env,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_fresh_successor_uses_the_pair_model(self):
        for initial, provider, target in (('claude-opus-5-5', 'claude', 'gpt-6.1-sol'),
                                          ('gpt-6.1-sol', 'codex', 'claude-opus-5-5')):
            with self.subTest(initial=initial):
                env = self.setup_run(initial, provider)
                (self.root / 'calls.jsonl').unlink(missing_ok=True)
                result = self.handoff(env)
                self.assertEqual(result.returncode, 0, result.stderr)
                starts = [c for c in self.calls() if c[:2] == ['agent', 'start']]
                self.assertEqual(len(starts), 1)
                self.assertIn(target, starts[0])
                lead = goals.g.read_json(self.run / 'lead.json')
                self.assertEqual((lead['model'], lead['initial_model']), (target, initial))
                self.assertIn(provider, lead['exhausted_until'])
                self.assertFalse(any(c[:3] == ['agent', 'prompt', 'old'] for c in self.calls()))

    def test_live_sibling_is_promoted_without_a_new_session(self):
        workers = [{'name': 'opus', 'provider': 'claude', 'level': 'sibling', 'model': 'claude-opus-5-5',
                    'pane': 'sib', 'status': 'dispatched', 'owner': 'lead'},
                   {'name': 'h1', 'provider': 'codex', 'level': 'helper', 'pane': 'p1', 'status': 'ready', 'owner': 'opus'},
                   {'name': 'h2', 'provider': 'claude', 'level': 'helper', 'pane': 'p2', 'status': 'ready', 'owner': 'lead'}]
        env = self.setup_run('gpt-6.1-sol', 'codex', workers)
        result = self.handoff(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('promoted', result.stdout)
        self.assertFalse([c for c in self.calls() if c[:2] in (['agent', 'start'], ['pane', 'split'])])
        lead = goals.g.read_json(self.run / 'lead.json')
        self.assertEqual((lead['pane'], lead['kind'], lead['model'], lead['status'], lead['generation']),
                         ('sib', 'claude', 'claude-opus-5-5', 'active', 2))
        prompts = [c for c in self.calls() if c[:2] == ['agent', 'prompt']]
        self.assertEqual([p[2] for p in prompts], ['sib'])
        self.assertIn('PRINCIPAL', prompts[0][-1])
        state = goals.g.read_json(self.run / 'state.json')
        by_name = {r['name']: r for r in state['workers']}
        self.assertEqual(by_name['opus']['status'], 'promoted')
        self.assertEqual((by_name['h1']['owner'], by_name['h2']['owner']), ('lead', 'lead'))

    def test_successor_without_quota_strands_until_its_reset(self):
        env = self.setup_run('gpt-6.1-sol', 'codex')
        self.claude_limits(99, 1800)
        result = self.handoff(env)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('no 5h quota until', result.stdout)
        # Only read-only lookups: no pane opened, no agent started, nothing typed.
        self.assertEqual([c for c in self.calls() if c[:2] != ['agent', 'list']], [])
        lead = goals.g.read_json(self.run / 'lead.json')
        self.assertEqual((lead['status'], lead['pane']), ('stranded', 'old'))

    def test_exhausted_provider_waits_for_its_real_reset(self):
        env = self.setup_run('gpt-6.1-sol', 'codex')
        lead = goals.g.read_json(self.run / 'lead.json')
        lead['exhausted_until'] = {'claude': time.time() + 600}
        goals.g.atomic_json(self.run / 'lead.json', lead)
        self.assertEqual(self.handoff(env).returncode, 4)
        lead = goals.g.read_json(self.run / 'lead.json')
        lead['exhausted_until'] = {'claude': time.time() - 1}
        lead['status'] = 'active'
        goals.g.atomic_json(self.run / 'lead.json', lead)
        result = self.handoff(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(goals.g.read_json(self.run / 'lead.json')['kind'], 'claude')

    def test_adoption_keeps_the_pair(self):
        env = self.setup_run('gpt-6.1-sol')
        env['HERDR_PANE_ID'] = 'new'
        result = subprocess.run(['bash', str(goals.SCRIPTS / 'handoff.sh'), '--run', str(self.run),
                                 '--adopt'], env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lead = goals.g.read_json(self.run / 'lead.json')
        self.assertEqual(lead['pane'], 'new')
        self.assertEqual(m.select(lead, 'codex')['model'], 'gpt-6.1-sol')

    def test_old_lead_is_fenced_after_promotion(self):
        workers = [{'name': 'opus', 'provider': 'claude', 'level': 'sibling', 'pane': 'sib',
                    'status': 'dispatched', 'owner': 'lead'}]
        env = self.setup_run('gpt-6.1-sol', 'codex', workers)
        self.assertEqual(self.handoff(env).returncode, 0)
        again = self.handoff(env)
        self.assertEqual(again.returncode, 2)
        self.assertIn('not a lead of this run', again.stderr)

    def test_run_init_records_pair_and_balance(self):
        env = self.setup_run('claude-opus-5-5', 'claude')
        repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Synthetic',
                        '-c', 'user.email=synthetic@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-q', '--allow-empty', '-m', 'Synthetic baseline'],
                       check=True, capture_output=True)
        result = subprocess.run(['bash', str(goals.SCRIPTS / 'run-init.sh'), '--repo', str(repo),
                                 '--no-panel', '--lead-model', 'claude-opus-5-5', '--worker-tier', 'strong'],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ignored', result.stderr)
        self.assertIn('lead pair: claude=claude-opus-5-5  codex=gpt-6.1-sol', result.stdout)
        run_dir = next((self.root / 'state' / 'runs').glob('*/*'))
        lead = goals.g.read_json(run_dir / 'lead.json')
        self.assertEqual(lead['destinations']['codex']['model'], 'gpt-6.1-sol')
        self.assertNotIn('worker_tier', goals.g.read_json(run_dir / 'state.json'))
        balance = goals.g.read_json(self.root / 'state' / 'balance.json')
        self.assertEqual(balance['last_principal'], 'claude')  # the fake herdr reports the run's pane as claude


if __name__ == '__main__':
    unittest.main()
