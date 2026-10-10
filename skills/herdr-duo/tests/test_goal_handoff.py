"""Synthetic provider storage and Herdr tests; no live pane or model requests."""
import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
spec = importlib.util.spec_from_file_location('goal_handoff', SCRIPTS / 'goal-handoff.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class GoalFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / 'run'
        self.run.mkdir()
        self.codex = self.root / 'codex'
        self.codex.mkdir()
        self.claude = self.root / 'claude'
        self.env = patch.dict(os.environ, {'CODEX_HOME': str(self.codex),
                                          'CLAUDE_CONFIG_DIR': str(self.claude)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def info(self, provider='claude', sid='session-1', status='idle'):
        return {'agent': provider, 'agent_session': {'kind': 'id', 'value': sid},
                'agent_status': status}

    def transcript(self, attachments, sid='session-1'):
        path = self.claude / 'projects' / '-synthetic-repo' / (sid + '.jsonl')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps({'type': 'attachment', 'attachment': a}) + '\n'
                                for a in attachments))
        return path

    def native(self, objective='Finish CI and cleanup', **extra):
        value = {'status': 'active', 'objective': objective} | extra
        g.atomic_json(self.run / 'goal-native.json', value)
        (self.run / 'lead-resume.md').write_text('Continue the synthetic task')
        return value


class GoalTests(GoalFixture, unittest.TestCase):
    def test_codex_exact_session_readonly_and_budget(self):
        path = self.codex / 'goals_1.sqlite'
        with closing(sqlite3.connect(path)) as db:
            db.execute('CREATE TABLE thread_goals(thread_id, objective, status, token_budget, '
                       'tokens_used, time_used_seconds, updated_at_ms)')
            db.executemany('INSERT INTO thread_goals VALUES(?,?,?,?,?,?,?)', [
                ('session-1', 'Correct goal', 'active', 1000, 350, 7, 1),
                ('other', 'Wrong goal', 'active', None, 0, 0, 2)])
            db.commit()
        original = path.read_bytes()
        result = g.native_goal(self.info('codex'))
        self.assertEqual(result['objective'], 'Correct goal')
        self.assertEqual(result['remaining_tokens'], 650)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(g.native_goal(self.info('codex', 'absent'))['status'], 'none')

    def test_codex_schema_change_and_missing_storage(self):
        self.assertIsNone(g.native_goal(self.info('codex')))
        with closing(sqlite3.connect(self.codex / 'goals_1.sqlite')) as db:
            db.execute('CREATE TABLE incompatible(x)')
        self.assertIsNone(g.native_goal(self.info('codex')))

    def test_claude_latest_goal_clear_and_failure(self):
        base = {'type': 'goal_status', 'met': False, 'condition': 'First'}
        self.transcript([base, base | {'condition': 'Latest'}])
        self.assertEqual(g.native_goal(self.info())['objective'], 'Latest')
        path = self.transcript([base, base | {'met': True, 'sentinel': True}])
        self.assertEqual(g.native_goal(self.info())['status'], 'complete')
        self.transcript([base | {'failed': True}])
        self.assertEqual(g.native_goal(self.info())['status'], 'blocked')
        with path.open('a') as f:
            f.write('{unfinished')
        self.assertEqual(g.native_goal(self.info())['status'], 'blocked')

    def test_session_paths_fail_closed(self):
        self.assertIsNone(g.native_goal(self.info(sid='../escape')))
        self.assertIsNone(g.native_goal({'agent': 'claude'}))
        self.assertIsNone(g.native_goal(self.info('unknown')))
        self.transcript([])
        duplicate = self.claude / 'projects' / '-other' / 'session-1.jsonl'
        duplicate.parent.mkdir()
        duplicate.write_text('')
        self.assertIsNone(g.native_goal(self.info()))

    def test_capture_fallback_and_no_inferred_native_goal(self):
        (self.run / 'state.json').write_text('{"goal":"ordinary task title"}')
        with patch.object(g, 'agent_info', return_value=self.info()):
            self.assertEqual(g.capture(self.run, 'old')['status'], 'unknown')
            g.atomic_json(self.run / 'goal.json', {'objective': 'Explicit portable goal',
                                                  'status': 'active', 'budget': {'remaining_tokens': 50}})
            result = g.capture(self.run, 'old')
            self.assertEqual(result['source'], 'portable')
            self.assertEqual(result['remaining_tokens'], 50)
        self.assertIsNone(g.command_for(self.run, result, 'codex')[0])

    def test_authoritative_clear_overrides_portable_active(self):
        self.transcript([{'type': 'goal_status', 'met': True, 'condition': 'Done'}])
        g.atomic_json(self.run / 'goal.json', {'objective': 'Old', 'status': 'active'})
        with patch.object(g, 'agent_info', return_value=self.info()):
            result = g.capture(self.run, 'old')
        self.assertEqual(result['status'], 'complete')
        self.assertIsNone(g.command_for(self.run, result, 'claude')[0])

    def test_explicit_pause_and_inactive_states(self):
        self.transcript([{'type': 'goal_status', 'met': False, 'condition': 'Work'}])
        g.atomic_json(self.run / 'goal.json', {'objective': 'Work', 'status': 'paused'})
        with patch.object(g, 'agent_info', return_value=self.info()):
            self.assertEqual(g.capture(self.run, 'old')['status'], 'paused')
        for state in ('none', 'unknown', 'paused', 'blocked', 'complete', 'usage_limited', 'budget_limited'):
            self.assertIsNone(g.command_for(self.run, {'objective': 'Work', 'status': state}, 'claude')[0])

    def test_provider_quota_handoff_preserves_goal_without_renewing_budget(self):
        source = {'objective': 'Work', 'status': 'usage_limited', 'source': 'native', 'provider': 'codex'}
        self.assertEqual(g.command_for(self.run, source, 'claude')[1], 'ready')
        self.assertEqual(g.command_for(self.run, source, 'codex')[1], 'inactive')
        self.assertEqual(g.command_for(self.run, source | {'source': 'portable'}, 'claude')[1], 'inactive')
        self.assertEqual(g.command_for(self.run, source | {'remaining_tokens': 0}, 'claude')[1], 'budget_exhausted')

    def test_budgets_never_reset(self):
        for budget in ({'token_budget': 100, 'tokens_used': 40}, {'remaining_tokens': 60},
                       {'budget_accounting_unavailable': True}):
            source = {'objective': 'Work', 'status': 'active'} | budget
            self.assertEqual(g.command_for(self.run, source, 'codex')[1], 'needs_budget_tool')
        for budget in ({'remaining_tokens': 0}, {'token_budget': 100, 'tokens_used': 100}):
            self.assertEqual(g.command_for(self.run, {'objective': 'Work', 'status': 'active'} | budget,
                                          'claude')[1], 'budget_exhausted')

    def test_long_unicode_goal_uses_full_checkpoint(self):
        source = self.native('😀' * 2500)
        objective, reason = g.command_for(self.run, source, 'claude')
        self.assertEqual(reason, 'ready')
        self.assertLessEqual(len(objective.encode('utf-16-le')) // 2, 4000)
        self.assertIn('goal-native.json', objective)
        self.assertEqual(g.read_json(self.run / 'goal-native.json')['objective'], source['objective'])

    def test_restore_command_verified_no_duplicate(self):
        self.native()
        self.transcript([])
        calls = []
        def prompt(argv, **kwargs):
            calls.append(argv)
            self.transcript([{'type': 'goal_status', 'met': False, 'condition': argv[-1][6:]}])
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(g, 'agent_info', return_value=self.info()), patch.object(g.subprocess, 'run', side_effect=prompt):
            self.assertEqual(g.restore(self.run, 'new'), 'started')
            self.assertEqual(g.restore(self.run, 'new'), 'started')
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][-1].startswith('/goal Finish CI and cleanup'))
        self.assertIn('lead-resume.md', calls[0][-1])
        self.assertEqual(g.read_json(self.run / 'goal-transfer.json')['status'], 'verified')

    def test_capture_next_handoff_does_not_grow_objective(self):
        source = self.native(token_budget=1000, tokens_used=100, remaining_tokens=900)
        objective = g.command_for(self.run, source, 'claude')[0]
        self.transcript([{'type': 'goal_status', 'met': False, 'condition': objective}])
        import hashlib
        g.atomic_json(self.run / 'goal-transfer.json', {'pane': 'new', 'status': 'verified',
                      'objective_sha256': hashlib.sha256(objective.encode()).hexdigest()})
        with patch.object(g, 'agent_info', return_value=self.info()):
            result = g.capture(self.run, 'new')
        self.assertEqual(result['objective'], source['objective'])
        self.assertTrue(result['budget_accounting_unavailable'])
        self.assertEqual(result['inherited_budget']['remaining_tokens'], 900)

    def test_restore_codex_native_command_verified(self):
        self.native()
        path = self.codex / 'goals_1.sqlite'
        with closing(sqlite3.connect(path)) as db:
            db.execute('CREATE TABLE thread_goals(thread_id, objective, status, token_budget, '
                       'tokens_used, time_used_seconds, updated_at_ms)')
        def prompt(argv, **kwargs):
            with closing(sqlite3.connect(path)) as db:
                db.execute('INSERT INTO thread_goals VALUES(?,?,?,?,?,?,?)',
                           ('session-1', argv[-1][6:], 'active', None, 0, 0, 1))
                db.commit()
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(g, 'agent_info', return_value=self.info('codex')), patch.object(g.subprocess, 'run', side_effect=prompt):
            self.assertEqual(g.restore(self.run, 'new'), 'started')
        self.assertEqual(g.read_json(self.run / 'goal-transfer.json')['status'], 'verified')

    def test_existing_goal_not_replaced(self):
        self.native()
        for condition, met in [('User goal', False), ('User goal', True), ('Finish CI and cleanup', False)]:
            self.transcript([{'type': 'goal_status', 'met': met, 'condition': condition}])
            with patch.object(g, 'agent_info', return_value=self.info()), patch.object(g.subprocess, 'run') as prompt:
                self.assertEqual(g.restore(self.run, 'new'), 'fallback')
                prompt.assert_not_called()

    def test_ambiguous_submission_not_retried(self):
        self.native()
        self.transcript([])
        with patch.object(g, 'agent_info', return_value=self.info()), patch.object(g.subprocess, 'run') as prompt, patch.object(g.time, 'sleep'):
            prompt.side_effect = subprocess.TimeoutExpired('herdr', 10)
            self.assertEqual(g.restore(self.run, 'new'), 'fallback')
            self.assertEqual(g.restore(self.run, 'new'), 'fallback')
            self.assertEqual(prompt.call_count, 1)
        self.assertEqual(g.read_json(self.run / 'goal-transfer.json')['status'], 'unconfirmed')

    def test_unsupported_command_falls_back_and_busy_defers(self):
        self.native()
        self.transcript([])
        with patch.object(g, 'agent_info', return_value=self.info(status='working')), patch.object(g.subprocess, 'run') as prompt:
            self.assertEqual(g.restore(self.run, 'new'), 'defer')
            prompt.assert_not_called()
        with patch.object(g, 'agent_info', return_value=self.info()), patch.object(g.subprocess, 'run') as prompt, patch.object(g.time, 'sleep'):
            self.assertEqual(g.restore(self.run, 'new'), 'fallback')
            self.assertEqual(prompt.call_count, 1)


class DeliveryTests(GoalFixture, unittest.TestCase):
    def fake_herdr(self, blocked=False, budget=False):
        self.native(**({'token_budget': 100, 'tokens_used': 25, 'remaining_tokens': 75} if budget else {}))
        self.transcript([])
        g.atomic_json(self.run / 'state.json', {'repo': str(self.root)})
        g.atomic_json(self.run / 'lead.json', {'pane': 'new', 'name': 'lead2',
                                             'status': 'awaiting_approval', 'pending_prompt': 'Resume inherited run'})
        executable = self.root / 'herdr'
        executable.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:];root=Path(os.environ['SYNTHETIC_ROOT'])
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(args)+'\\n')
if args[:2]==['pane','read']:
 print('Do you trust this folder?' if os.environ.get('SYNTHETIC_BLOCKED')=='1' else '')
elif args[:2]==['pane','split']:
 print(json.dumps({'result':{'pane':{'pane_id':'new'}}}))
elif args[:2]==['agent','get']:
 old=args[2]=='old';provider='codex' if old else 'claude'
 sid='old-session' if old else 'session-1'
 print(json.dumps({'result':{'agent':{'agent':provider,'agent_status':'idle','agent_session':{'kind':'id','value':sid}}}}))
elif args[:2]==['agent','prompt'] and args[-1].startswith('/goal '):
 p=Path(os.environ['CLAUDE_CONFIG_DIR'])/'projects'/'-synthetic-repo'/'session-1.jsonl'
 p.write_text(json.dumps({'type':'attachment','attachment':{'type':'goal_status','met':False,'condition':args[-1][6:]}})+'\\n')
''')
        executable.chmod(0o755)
        return os.environ | {'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
                             'SYNTHETIC_ROOT': str(self.root), 'SYNTHETIC_BLOCKED': '1' if blocked else '0'}

    def deliver(self, env):
        result = subprocess.run(['bash', str(SCRIPTS / 'handoff.sh'), '--run', str(self.run), '--deliver'],
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def prompts(self):
        return [c for c in map(json.loads, (self.root / 'calls.jsonl').read_text().splitlines())
                if c[:2] == ['agent', 'prompt']]

    def test_shell_deliver_native_and_idempotent(self):
        env = self.fake_herdr()
        self.deliver(env)
        self.deliver(env)
        prompts = self.prompts()
        self.assertEqual(len(prompts), 1)
        self.assertTrue(prompts[0][-1].startswith('/goal '))
        self.assertEqual(g.read_json(self.run / 'lead.json')['status'], 'active')
        self.assertEqual(g.read_json(self.run / 'goal-transfer.json')['status'], 'verified')
        self.assertFalse((self.run / 'deliver.lock').exists())

    def test_shell_never_answers_dialog(self):
        self.deliver(self.fake_herdr(blocked=True))
        self.assertEqual(self.prompts(), [])
        self.assertEqual(g.read_json(self.run / 'lead.json')['status'], 'awaiting_approval')
        self.assertFalse((self.run / 'deliver.lock').exists())

    def test_shell_fallback_delivers_resume(self):
        env = self.fake_herdr()
        g.atomic_json(self.run / 'goal-native.json', {'status': 'unknown'})
        self.deliver(env)
        self.assertEqual(self.prompts()[0][-1], 'Resume inherited run')
        self.assertEqual(g.read_json(self.run / 'lead.json')['status'], 'active')

    def test_full_handoff_captures_and_restores_without_old_pane_input(self):
        env = self.fake_herdr()
        env['HERDR_DUO_LEAD_FALLBACK'] = 'claude'
        env['HERDR_PANE_ID'] = 'old'
        # Isolate configuration discovery from the real machine.
        env['XDG_CONFIG_HOME'] = str(self.root / 'config')
        g.atomic_json(self.run / 'lead.json', {'pane': 'old', 'name': 'lead1',
                      'kind': 'codex', 'generation': 1, 'status': 'active'})
        with closing(sqlite3.connect(self.codex / 'goals_1.sqlite')) as db:
            db.execute('CREATE TABLE thread_goals(thread_id, objective, status, token_budget, '
                       'tokens_used, time_used_seconds, updated_at_ms)')
            db.execute('INSERT INTO thread_goals VALUES(?,?,?,?,?,?,?)',
                       ('old-session', 'Full synthetic objective', 'usage_limited', None, 42, 2, 1))
            db.commit()
        result = subprocess.run(['bash', str(SCRIPTS / 'handoff.sh'), '--run', str(self.run),
                                 '--reason', 'synthetic quota test'], env=env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lead = g.read_json(self.run / 'lead.json')
        self.assertEqual((lead['pane'], lead['kind'], lead['status']), ('new', 'claude', 'active'))
        self.assertEqual(g.read_json(self.run / 'goal-native.json')['objective'], 'Full synthetic objective')
        self.assertEqual(g.read_json(self.run / 'goal-transfer.json')['status'], 'verified')
        self.assertEqual(len(self.prompts()), 1)
        self.assertEqual(self.prompts()[0][2], 'new')
        self.assertIn('Full synthetic objective', self.prompts()[0][-1])
        self.assertTrue((self.run / 'lead-resume.md').is_file())
        self.assertFalse((self.run / 'handoff.lock').exists())
        self.assertFalse((self.run / 'deliver.lock').exists())

    def test_shell_concurrent_delivery_lock(self):
        env = self.fake_herdr()
        (self.run / 'deliver.lock').mkdir()
        self.deliver(env)
        self.assertFalse((self.root / 'calls.jsonl').exists())
        self.assertEqual(g.read_json(self.run / 'lead.json')['status'], 'awaiting_approval')


class ProgressTests(GoalFixture, unittest.TestCase):
    def test_goal_checkpoint_rejects_invalid_input_without_replacing_snapshot(self):
        g.atomic_json(self.run / 'state.json', {})
        env = os.environ | {'XDG_CONFIG_HOME': str(self.root / 'config')}
        def record(text):
            return subprocess.run(['bash', str(SCRIPTS / 'progress.sh'), '--run', str(self.run),
                                   'goal', text], env=env, capture_output=True, text=True)
        good = record(json.dumps({'objective': 'Continue', 'status': 'active',
                                  'remaining': ['CI', 'cleanup'], 'budget': {'remaining_tokens': 123}}))
        self.assertEqual(good.returncode, 0, good.stderr)
        snapshot = (self.run / 'goal.json').read_bytes()
        self.assertEqual(g.read_json(self.run / 'goal.json')['budget']['remaining_tokens'], 123)
        self.assertIn('updated_at', g.read_json(self.run / 'goal.json'))
        for invalid in ('[]', '{}', '{', '{"objective":"x","status":"invalid"}'):
            self.assertNotEqual(record(invalid).returncode, 0)
            self.assertEqual((self.run / 'goal.json').read_bytes(), snapshot)


if __name__ == '__main__':
    unittest.main()
