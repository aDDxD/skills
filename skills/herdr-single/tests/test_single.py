"""herdr-single: one subscription per run, the single-window quota guardian, parking and
resuming the lead, and the scripts around them. Temporary run directories, CLI dry runs,
synthetic quota files and a fake Herdr CLI; no live agents."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
NOW = 1_800_000_000


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_quota():
    return load('quota_under_test', 'quota.py')


# A fake Herdr CLI. Panes listed in SYNTHETIC_GONE do not exist; every call is logged.
FAKE_HERDR = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['SYNTHETIC_ROOT'])
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(args) + '\\n')
gone = os.environ.get('SYNTHETIC_GONE', '').split(',')
if args[:2] == ['pane', 'read']:
    print('')
elif args[:2] == ['pane', 'split']:
    print(json.dumps({'result': {'pane': {'pane_id': 'new'}}}))
elif args[:2] == ['agent', 'get']:
    if args[2] in gone:
        sys.exit(1)
    print(json.dumps({'result': {'agent': {'agent': os.environ.get('SYNTHETIC_PROVIDER', 'claude'),
          'agent_status': 'idle', 'agent_session': {'kind': 'id', 'value': 'sess-' + args[2]}}}}))
elif args[:1] == ['agent'] and len(args) == 1:
    print('  kinds: codex|claude', file=sys.stderr)
'''


class RunFixture:
    provider = 'claude'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_root = self.root / 'state'
        self.run = self.state_root / 'runs' / 'repo-1' / '20261014T000000Z'
        self.run.mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        codex = self.bin / 'codex'
        codex.write_text('#!/bin/sh\nprintf "synthetic CLI --no-daemon\\n"\n')
        codex.chmod(0o755)
        self.limits = self.root / 'claude-limits.json'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_SINGLE_')}
        self.env.update(XDG_CONFIG_HOME=str(self.root / 'config'), HERDR_SINGLE_STATE_ROOT=str(self.state_root),
                        HERDR_SINGLE_CLAUDE_LIMITS=str(self.limits), CODEX_HOME=str(self.root / 'codex'),
                        CLAUDE_CONFIG_DIR=str(self.root / 'claude-config'), SYNTHETIC_ROOT=str(self.root),
                        HERDR_PANE_ID='leadpane', PATH=str(self.bin) + os.pathsep + '/usr/bin:/bin')
        self.write_run()

    def write_run(self, workers=(), provider=None, **lead):
        provider = provider or self.provider
        (self.run / 'state.json').write_text(json.dumps({
            'repo': str(self.root), 'wt_root': str(self.root / 'wt'), 'status': 'planning',
            'provider': provider, 'workers': list(workers), 'reviewers': []}))
        (self.run / 'lead.json').write_text(json.dumps({
            'name': 'lead1', 'pane': 'leadpane', 'kind': provider, 'panel_pane': 'panel', 'status': 'active',
            'generation': 1, 'successor': {'model': 'claude-opus-5-5' if provider == 'claude' else 'gpt-6.1-sol'},
            **lead}))

    def lead(self):
        return json.loads((self.run / 'lead.json').read_text())

    def fake_herdr(self):
        herdr = self.bin / 'herdr'
        herdr.write_text(FAKE_HERDR)
        herdr.chmod(0o755)

    def calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def set_limits(self, used, resets_in_s=3600):
        self.limits.write_text(json.dumps({'fiveHour': {'usedPercentage': used, 'resetsAt': time.time() + resets_in_s},
                                           'fetchedAtMs': time.time() * 1000}))

    def script(self, name, *args, pane='leadpane', stdin=None, **env):
        env = dict(self.env, HERDR_PANE_ID=pane, **env)
        return subprocess.run(['bash', str(SCRIPTS / name), *args], env=env, capture_output=True,
                              text=True, timeout=30, input=stdin)

    def spawn(self, name, *extra, pane='leadpane'):
        return self.script('spawn.sh', '--run', str(self.run), '--name', name, '--dry-run', *extra, pane=pane)


class QuotaFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.limits = self.root / 'claude-limits-latest.json'
        self.codex = self.root / 'codex'
        (self.codex / 'sessions' / '2026' / '10' / '14').mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # No herdr on PATH: the pane fallback finds nothing.
        self.env = {'HERDR_SINGLE_STATE_ROOT': str(self.root / 'state'), 'HERDR_SINGLE_CLAUDE_LIMITS': str(self.limits),
                    'CODEX_HOME': str(self.codex), 'HERDR_SINGLE_NOW': str(NOW),
                    'PATH': str(self.bin) + os.pathsep + '/usr/bin:/bin'}
        patcher = patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def claude(self, used, resets_in_min):
        self.limits.write_text(json.dumps({
            'fiveHour': {'usedPercentage': used, 'resetsAt': NOW + resets_in_min * 60, 'windowMinutes': 300},
            'sevenDay': {'usedPercentage': 99, 'resetsAt': NOW + 86400 * 3, 'windowMinutes': 10080},
            'fetchedAtMs': NOW * 1000}))

    def codex_rollout(self, used, resets_in_min, name='rollout-a.jsonl'):
        record = {'type': 'event_msg', 'payload': {'type': 'token_count', 'rate_limits': {
            'limit_id': 'codex', 'primary': {'used_percent': used, 'window_minutes': 300,
                                             'resets_at': NOW + resets_in_min * 60},
            'secondary': {'used_percent': 99.0, 'window_minutes': 10080, 'resets_at': NOW + 86400}}}}
        path = self.codex / 'sessions' / '2026' / '10' / '14' / name
        path.write_text('{"type":"session_meta"}\n' + json.dumps(record, separators=(',', ':')) + '\n')
        return path


class QuotaTests(QuotaFixture, unittest.TestCase):
    def test_reads_only_the_requested_subscription_and_ignores_weekly(self):
        self.claude(21, 120)
        q = load_quota().snapshot(('claude',))
        self.assertEqual(list(q), ['claude'])
        self.assertEqual((q['claude']['used'], q['claude']['left'], q['claude']['mins_to_reset']), (21.0, 79.0, 120))

    def test_expired_window_reads_as_unused(self):
        self.codex_rollout(16.0, -30)
        q = load_quota().snapshot(('codex',))
        self.assertEqual((q['codex']['left'], q['codex']['surplus']), (100.0, 100.0))
        self.assertIn('reset', q['codex']['note'])

    def test_missing_source_is_unknown(self):
        self.assertEqual(load_quota().snapshot(('claude',))['claude'], {'known': False})

    def test_rate_and_projected_surplus_from_history(self):
        m = load_quota()
        self.claude(20, 120)
        m.snapshot(('claude',))
        with patch.dict(os.environ, {'HERDR_SINGLE_NOW': str(NOW + 1800)}):
            self.claude(30, 120)
            q = m.snapshot(('claude',))
        self.assertEqual(q['claude']['rate_per_hour'], 20.0)
        self.assertEqual(q['claude']['surplus'], 40.0)


class SuggestTests(QuotaFixture, unittest.TestCase):
    def x(self, left, mins=200, surplus=None, note=''):
        return {'known': True, 'left': left, 'used': 100 - left, 'mins_to_reset': mins,
                'resets_at': NOW + mins * 60, 'surplus': surplus, 'note': note}

    def test_wasted_quota_is_spent_on_helpers(self):
        m = load_quota()
        n, why = m.suggest(self.x(80, surplus=40))
        self.assertEqual(n, m.MAX_HELPERS)
        self.assertIn('unused', why)
        self.assertEqual(m.suggest(self.x(80, surplus=40), live=4)[0], m.MAX_HELPERS - 4)
        self.assertEqual(m.suggest(self.x(80, surplus=10))[0], m.MAX_HELPERS // 2)

    def test_on_pace_and_reserve(self):
        m = load_quota()
        self.assertEqual(m.suggest(self.x(60, surplus=0))[0], 1)
        self.assertEqual(m.suggest(self.x(60, surplus=0), live=1)[0], 0)
        n, why = m.suggest(self.x(25, surplus=25))
        self.assertEqual(n, 0)
        self.assertIn('reserve', why)

    def test_reset_soon_and_unknown(self):
        m = load_quota()
        self.assertEqual(m.suggest(self.x(50, mins=30, surplus=0))[0], m.MAX_HELPERS)
        self.assertEqual(m.suggest({'known': False})[0], 2)
        self.assertEqual(m.suggest(self.x(90, surplus=None))[0], m.MAX_HELPERS // 2)

    def test_cli(self):
        self.claude(21, 120)
        env = os.environ | self.env
        out = subprocess.run(['python3', str(SCRIPTS / 'quota.py'), 'suggest', '--provider', 'claude', '--live', '1'],
                             capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(out.stdout.splitlines()[0].isdigit())
        line = subprocess.run(['python3', str(SCRIPTS / 'quota.py'), 'line', '--provider', 'claude'],
                              capture_output=True, text=True, env=env, timeout=20).stdout
        self.assertEqual(line.count('left'), 1)
        self.assertIn('claude 79% left', line)
        bad = subprocess.run(['python3', str(SCRIPTS / 'quota.py'), 'suggest'], capture_output=True, text=True, env=env)
        self.assertNotEqual(bad.returncode, 0)


class SpawnTests(RunFixture, unittest.TestCase):
    def test_defaults_to_the_runs_provider_and_role_models(self):
        for provider, helper, reviewer in (('claude', 'claude-haiku-5-5', 'claude-sonnet-5-5'),
                                           ('codex', 'gpt-6-luna', 'gpt-6.1-sol')):
            with self.subTest(provider=provider):
                self.write_run(provider=provider)
                (self.run / 'author').mkdir(exist_ok=True)
                (self.run / 'author' / 'baseline.json').write_text(json.dumps({'worktree': str(self.root)}))
                r = self.spawn('h1')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'({provider}, implementer, level helper, owner lead)', r.stdout)
                self.assertIn(helper, r.stdout)
                r = self.spawn('rev', '--role', 'reviewer', '--review-of', 'author')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(reviewer, r.stdout)
        self.assertFalse((self.root / 'wt').exists())

    def test_reviewer_of_the_leads_own_changes_is_read_only_in_the_checkout(self):
        r = self.spawn('rev-lead', '--role', 'reviewer', '--review-of', 'lead')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'worktree: {self.root} [reviews the lead', r.stdout)
        self.assertIn('--disallowedTools Edit,Write,NotebookEdit', r.stdout)
        self.assertIn(f'--add-dir {self.run} ', r.stdout)
        self.write_run(provider='codex')
        self.assertIn('-s read-only -a never', self.spawn('rev-lead', '--role', 'reviewer', '--review-of', 'lead').stdout)

    def test_the_other_subscription_is_refused(self):
        r = self.spawn('h1', '--provider', 'codex')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('uses only claude', r.stderr)
        r = self.spawn('h1', '--model', 'gpt-6-luna')
        self.assertIn('not a claude model', r.stderr)
        self.write_run(provider='codex')
        r = self.spawn('h1', '--model', 'claude-haiku-5-5')
        self.assertIn('not a codex model', r.stderr)

    def test_any_model_of_the_provider_and_effort(self):
        r = self.spawn('h1', '--model', 'claude-opus-5-5')
        self.assertIn('--model claude-opus-5-5', r.stdout)
        self.assertIn('--effort xhigh', r.stdout)
        r = self.spawn('h2', '--effort', 'bogus')
        self.assertIn('not valid for claude', r.stderr)
        self.write_run(provider='codex')
        self.assertIn('model_reasoning_effort=xhigh', self.spawn('h3').stdout)

    def test_no_sibling_and_outsiders_refused(self):
        r = self.spawn('sib', '--level', 'sibling')
        self.assertIn('no sibling', r.stderr)
        r = self.spawn('h1', pane='stranger')
        self.assertIn('not the lead of this run', r.stderr)

    def test_run_without_provider_is_refused(self):
        state = json.loads((self.run / 'state.json').read_text())
        del state['provider']
        (self.run / 'state.json').write_text(json.dumps(state))
        self.assertIn('records no provider', self.spawn('h1').stderr)


class MembersTests(RunFixture, unittest.TestCase):
    def test_whoami_and_find(self):
        for pane, who in (('leadpane', 'lead'), ('panel', 'panel'), ('x', 'outsider')):
            r = subprocess.run(['python3', str(SCRIPTS / 'members.py'), 'whoami', str(self.run), pane],
                               capture_output=True, text=True, env=self.env)
            self.assertEqual(r.stdout.strip(), who)
        r = subprocess.run(['python3', str(SCRIPTS / 'members.py'), 'find', 'leadpane'],
                           capture_output=True, text=True, env=self.env)
        self.assertEqual(r.stdout.split(), [str(self.run), 'lead'])

    def test_outsider_cannot_act(self):
        self.write_run([{'name': 'h1', 'owner': 'lead', 'pane': 'p1', 'status': 'ready'}])
        for name, args in (('dispatch.sh', ('--name', 'h1')), ('cleanup.sh', ('--name', 'h1')),
                           ('progress.sh', ('note', 'x'))):
            r = self.script(name, '--run', str(self.run), *args, pane='stranger')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('not the lead', r.stderr)


class HookTests(RunFixture, unittest.TestCase):
    def hook(self, event, pane='leadpane'):
        r = subprocess.run(['python3', '-B', str(SCRIPTS / 'hook.py')], input=json.dumps({'hook_event_name': event}),
                           env=dict(self.env, HERDR_PANE_ID=pane), capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        return json.loads(r.stdout)['hookSpecificOutput']['additionalContext'] if r.stdout.strip() else None

    def test_silent_outside_a_run_and_for_finished_runs(self):
        self.assertIsNone(self.hook('UserPromptSubmit', pane='elsewhere'))
        state = json.loads((self.run / 'state.json').read_text())
        state['status'] = 'finished'
        (self.run / 'state.json').write_text(json.dumps(state))
        self.assertIsNone(self.hook('UserPromptSubmit'))

    def test_one_window_capacity_and_low_quota(self):
        self.set_limits(40)
        text = self.hook('UserPromptSubmit')
        self.assertIn('herdr-single (lead', text)
        self.assertIn('claude 60% left', text)
        self.assertNotIn('codex', text)
        self.assertIn('new helpers now', text)
        self.assertIsNone(self.hook('PostToolUse'))
        self.set_limits(95)
        for cache in self.state_root.glob('quota-cache*.json'):
            cache.unlink()
        text = self.hook('PostToolUse')
        self.assertIn('QUOTA LOW', text)
        self.assertIn('parks the run', text)
        self.assertIsNone(self.hook('PostToolUse'))
        with open(self.run / 'alerts.log', 'a') as f:
            f.write('12:00 something happened\n')
        self.assertIn('ALERT: 12:00 something', self.hook('PostToolUse'))

    def test_install_uses_this_skills_path(self):
        claude, codex = self.root / 'claude', self.root / 'codex'
        claude.mkdir()
        codex.mkdir(exist_ok=True)
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(claude), CODEX_HOME=str(codex))
        r = subprocess.run(['bash', str(SCRIPTS / 'install-hooks.sh'), '--codex-only'], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads((codex / 'hooks.json').read_text())
        self.assertIn('herdr-single/scripts/hook.py', data['hooks']['UserPromptSubmit'][0]['hooks'][0]['command'])
        self.assertFalse((claude / 'settings.json').exists())


class LeadModelTests(unittest.TestCase):
    def setUp(self):
        self.m = load('lead_models', 'lead-models.py')

    def test_successor_keeps_the_leads_own_model_and_effort(self):
        p = self.m.profile('claude', 'claude-fable-5-2', 'high')
        self.assertEqual(p['successor'], {'model': 'claude-fable-5-2', 'effort': 'high'})
        p = self.m.profile('codex', 'gpt-6.1-sol', 'ultra')
        self.assertEqual(p['successor'], {'model': 'gpt-6.1-sol', 'effort': 'ultra'})
        self.assertEqual(self.m.profile('claude', None, 'ultra')['successor'], {'model': 'claude-opus-5-5', 'effort': 'max'})

    def test_select_stays_on_the_provider(self):
        self.assertEqual(self.m.select({'successor': {'model': 'gpt-6.1-sol'}}, 'claude')['model'], 'claude-opus-5-5')
        self.assertEqual(self.m.select({'successor': {'model': 'claude-opus-5-5'}}, 'codex'),
                         {'model': 'gpt-6.1-sol', 'effort': 'medium'})
        self.assertEqual(self.m.select({'successor': {'model': 'gpt-6-astra'}}, 'codex')['model'], 'gpt-6.1-sol')
        self.assertEqual(self.m.select({}, 'claude'), {'model': 'claude-opus-5-5'})


class HandoffTests(RunFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.fake_herdr()

    def handoff(self, *args, **env):
        return self.script('handoff.sh', '--run', str(self.run), *args, **env)

    def test_exhausted_window_parks_the_run(self):
        self.set_limits(99.5, 1800)
        r = self.handoff('--reason', 'quota exhausted')
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn('PARKED', r.stdout)
        lead = self.lead()
        self.assertEqual((lead['status'], lead['pane']), ('parked', 'leadpane'))
        self.assertAlmostEqual(lead['parked_until'], time.time() + 1800, delta=60)
        self.assertFalse(any(c[:2] == ['agent', 'start'] for c in self.calls()))

    def test_limit_message_parks_even_when_the_sensor_disagrees(self):
        self.set_limits(40, 7200)
        r = self.handoff('--reason', 'limit message', '--park')
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertAlmostEqual(self.lead()['parked_until'], time.time() + 7200, delta=60)

    def test_resume_in_place_when_the_lead_pane_is_alive(self):
        self.write_run(status='parked', parked_until=int(time.time()) - 10, parked_reason='quota exhausted')
        self.set_limits(0)
        r = self.handoff('--resume', pane='panel')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('RESUME', r.stdout)
        lead = self.lead()
        self.assertEqual((lead['status'], lead['pane'], lead['name']), ('active', 'leadpane', 'lead1'))
        self.assertNotIn('parked_until', lead)
        self.assertNotIn('in_place', lead)
        prompts = [c for c in self.calls() if c[:2] == ['agent', 'prompt']]
        self.assertEqual(len(prompts), 1)
        self.assertEqual(prompts[0][2], 'leadpane')
        self.assertIn('window has reset', prompts[0][-1])
        self.assertFalse(any(c[:2] == ['agent', 'start'] for c in self.calls()))

    def test_resume_starts_a_fresh_lead_of_the_same_provider_when_the_pane_is_gone(self):
        for provider, model in (('claude', 'claude-opus-5-5'), ('codex', 'gpt-6.1-sol')):
            with self.subTest(provider=provider):
                (self.root / 'calls.jsonl').unlink(missing_ok=True)
                self.write_run(provider=provider, status='parked', parked_until=int(time.time()) - 10)
                r = self.handoff('--resume', pane='panel', SYNTHETIC_GONE='leadpane', SYNTHETIC_PROVIDER=provider)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'-> lead2 ({provider}, {model}', r.stdout)
                start = next(c for c in self.calls() if c[:2] == ['agent', 'start'])
                self.assertEqual(start[start.index('--kind') + 1], provider)
                lead = self.lead()
                self.assertEqual((lead['pane'], lead['name'], lead['status']), ('new', 'lead2', 'active'))
                self.assertIn('pane is gone', lead['history'][0]['reason'])

    def test_fresh_mode_never_resumes_in_place(self):
        self.write_run(status='parked', parked_until=int(time.time()) - 10)
        r = self.handoff('--resume', pane='panel', HERDR_SINGLE_LEAD_RESUME='fresh')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lead()['pane'], 'new')

    def test_resume_while_still_out_stays_parked(self):
        self.write_run(status='parked', parked_until=int(time.time()) - 10)
        self.set_limits(99.5, 600)
        self.assertEqual(self.handoff('--resume', pane='panel').returncode, 4)
        self.assertEqual(self.lead()['status'], 'parked')

    def test_context_handoff_with_quota_left_and_fence(self):
        self.set_limits(30)
        r = self.handoff('--reason', 'context full')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lead()['pane'], 'new')
        r = self.spawn('h1')
        self.assertIn('not the lead of this run', r.stderr)

    def test_other_subscription_and_outsiders_refused(self):
        self.assertIn('never hands a run', self.handoff('--reason', 'x', '--to', 'codex').stderr)
        self.assertIn('not the lead', self.handoff('--reason', 'x', pane='stranger').stderr)
        r = self.handoff('--adopt', pane='other', SYNTHETIC_PROVIDER='codex')
        self.assertIn('uses only claude', r.stderr)
        r = self.handoff('--adopt', pane='other')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.lead()['pane'], self.lead()['name']), ('other', 'lead2'))


class PanelTests(RunFixture, unittest.TestCase):
    def panel(self):
        os.environ.update({k: v for k, v in self.env.items() if k.startswith('HERDR_SINGLE_')})
        p = load('panel_under_test', 'panel.py')
        p.RUN = str(self.run)
        return p

    def setUp(self):
        super().setUp()
        saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(saved)))

    def test_parked_waits_then_resumes(self):
        p = self.panel()
        q = {'claude': {'known': True, 'left': 0.0}}
        lead = dict(self.lead(), status='parked', parked_until=time.time() + 600, parked_reason='quota exhausted')
        with patch.object(p, 'handoff') as h:
            self.assertIn('PARKED until', p.watchdog(lead, {}, q, 'claude'))
            h.assert_not_called()
            lead['parked_until'] = time.time() - 5
            self.assertIn('PARKED', p.watchdog(lead, {}, q, 'claude'))  # the sensor still says out
            q['claude']['left'] = 100.0
            self.assertIn('resuming', p.watchdog(lead, {}, q, 'claude'))
            h.assert_called_once_with('--resume')

    def test_idle_lead_out_of_quota_is_parked_after_two_ticks(self):
        p = self.panel()
        agents = {'leadpane': {'agent_status': 'idle'}}
        q = {'claude': {'known': True, 'left': 1.0}}
        with patch.object(p, 'handoff') as h, patch.object(p, 'limit_hit', return_value=None):
            p.watchdog(self.lead(), agents, q, 'claude')
            h.assert_not_called()
            p.watchdog(self.lead(), agents, q, 'claude')
            h.assert_called_once_with('--reason', 'quota exhausted (1% of 5h left)')
        self.assertTrue((self.run / 'lead.warning').exists())

    def test_limit_message_forces_park_and_off_only_alerts(self):
        p = self.panel()
        agents = {'leadpane': {'agent_status': 'idle'}}
        q = {'claude': {'known': True, 'left': 50.0}}
        hit = p.LIMIT_RE.search('You have hit your usage limit')
        with patch.object(p, 'handoff') as h, patch.object(p, 'limit_hit', return_value=hit):
            for _ in range(2):
                p.watchdog(self.lead(), agents, q, 'claude')
            self.assertEqual(h.call_args.args[-1], '--park')
            p.RESUME = 'off'
            h.reset_mock()
            for _ in range(2):
                p.watchdog(self.lead(), agents, q, 'claude')
            h.assert_not_called()
        self.assertIn('out of claude 5h quota', (self.run / 'alerts.log').read_text())

    def test_render_shows_one_window_and_capacity(self):
        p = self.panel()
        q = {'claude': {'known': True, 'left': 70.0, 'surplus': 30.0, 'mins_to_reset': 100,
                        'resets_at': time.time() + 6000}}
        with patch.object(p, 'git_info', return_value=('main', 0)), patch.object(p, 'ci_info', return_value=None), \
                patch.object(p, 'limit_hit', return_value=None):
            text = '\n'.join(p.render(json.loads((self.run / 'state.json').read_text()), {}, self.lead(),
                                      {'leadpane': {'agent_status': 'working'}}, q))
        self.assertIn('herdr-single (claude)', text)
        self.assertIn('new helpers now: 6', text)
        self.assertNotIn('codex', text)
        self.assertNotIn('sibling', text)


class RunInitTests(RunFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.fake_herdr()
        self.repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.email=t@t', '-c', 'user.name=t',
                        'commit', '-q', '--allow-empty', '-m', 'init'], check=True)

    def init(self, *args, pane='leadpane', **env):
        return self.script('run-init.sh', '--repo', str(self.repo), '--no-panel', *args, pane=pane, **env)

    def state(self, out):
        run = next(l.split('=', 1)[1] for l in out.splitlines() if l.startswith('RUN='))
        return Path(run), json.loads((Path(run) / 'state.json').read_text())

    def test_provider_from_the_lead_pane(self):
        r = self.init(SYNTHETIC_PROVIDER='codex')
        self.assertEqual(r.returncode, 0, r.stderr)
        run, state = self.state(r.stdout)
        self.assertEqual(state['provider'], 'codex')
        self.assertIn('provider: codex (fixed for this run', r.stdout)
        self.assertIn('helper=gpt-6-luna', r.stdout)
        lead = json.loads((run / 'lead.json').read_text())
        self.assertEqual((lead['kind'], lead['successor']['model']), ('codex', 'gpt-6.1-sol'))
        self.assertFalse((self.state_root / 'balance.json').exists())

    def test_explicit_provider_and_unknown_pane(self):
        r = self.init('--provider', 'claude', pane='')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state(r.stdout)[1]['provider'], 'claude')
        r = self.init(pane='')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('--provider codex|claude', r.stderr)


class CleanupTests(RunFixture, unittest.TestCase):
    def test_finish_refuses_live_sessions_then_deletes_the_run(self):
        self.fake_herdr()
        self.write_run([{'name': 'h1', 'owner': 'lead', 'role': 'implementer', 'status': 'settled'}])
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish')
        self.assertEqual(r.returncode, 8)
        self.assertIn('still open: h1', r.stderr)
        self.write_run([{'name': 'h1', 'owner': 'lead', 'role': 'implementer', 'status': 'cleaned'}])
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('provider: claude', r.stdout)
        self.assertFalse(self.run.exists())


if __name__ == '__main__':
    unittest.main()
