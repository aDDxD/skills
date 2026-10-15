"""Sibling leads, helpers, ownership and the quota hook, with temporary run directories,
CLI dry runs and synthetic quota files; no live agents."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class RunFixture:
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
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('HERDR_DUO_')}
        self.env.update(XDG_CONFIG_HOME=str(self.root / 'config'), HERDR_DUO_STATE_ROOT=str(self.state_root),
                        HERDR_DUO_CLAUDE_LIMITS=str(self.limits), CODEX_HOME=str(self.root / 'codex'),
                        HERDR_PANE_ID='principal', PATH=str(self.bin) + os.pathsep + '/usr/bin:/bin')
        self.write_run()

    def write_run(self, workers=(), kind='claude'):
        (self.run / 'state.json').write_text(json.dumps({
            'repo': str(self.root), 'wt_root': str(self.root / 'wt'), 'status': 'planning',
            'workers': list(workers), 'reviewers': []}))
        (self.run / 'lead.json').write_text(json.dumps({
            'name': 'lead1', 'pane': 'principal', 'kind': kind, 'panel_pane': 'panel', 'status': 'active',
            'destinations': {'codex': {'model': 'gpt-6.1-sol', 'effort': 'medium'},
                             'claude': {'model': 'claude-opus-5-5'}}}))

    def script(self, name, *args, pane='principal', stdin=None):
        env = dict(self.env, HERDR_PANE_ID=pane)
        return subprocess.run(['bash', str(SCRIPTS / name), *args], env=env, capture_output=True,
                              text=True, timeout=30, input=stdin)

    def spawn(self, name, provider, *extra, pane='principal'):
        return self.script('spawn.sh', '--run', str(self.run), '--name', name, '--provider', provider,
                           '--dry-run', *extra, pane=pane)


SIBLING = {'name': 'sol', 'provider': 'codex', 'level': 'sibling', 'model': 'gpt-6.1-sol', 'owner': 'lead',
           'pane': 'sibpane', 'status': 'dispatched', 'role': 'implementer'}


class SpawnTests(RunFixture, unittest.TestCase):
    def test_helper_defaults_and_free_model_choice(self):
        for provider, model in (('codex', 'gpt-6-luna'), ('claude', 'claude-haiku-5-5')):
            with self.subTest(provider=provider):
                r = self.spawn('h1', provider)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(model, r.stdout)
                self.assertIn('level helper, owner lead', r.stdout)
                self.assertFalse((self.root / 'wt').exists())
        r = self.spawn('h2', 'claude', '--model', 'claude-opus-5-5')
        self.assertIn('--model claude-opus-5-5', r.stdout)

    def test_sibling_is_the_other_subscriptions_pair_model(self):
        r = self.spawn('sol', 'codex', '--level', 'sibling')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('-m gpt-6.1-sol', r.stdout)
        same = self.spawn('opus', 'claude', '--level', 'sibling')
        self.assertNotEqual(same.returncode, 0)
        self.assertIn('other subscription', same.stderr)

    def test_one_live_sibling_and_only_the_principal_opens_it(self):
        self.write_run([SIBLING])
        r = self.spawn('sol2', 'codex', '--level', 'sibling')
        self.assertIn("sibling 'sol' is still live", r.stderr)
        r = self.spawn('x', 'codex', '--level', 'sibling', pane='sibpane')
        self.assertIn('only the principal', r.stderr)

    def test_sibling_owns_its_helpers_from_either_subscription(self):
        self.write_run([SIBLING])
        for provider in ('claude', 'codex'):
            r = self.spawn('sh-' + provider, provider, pane='sibpane')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('owner sol', r.stdout)

    def test_outsiders_and_removed_tier_are_refused(self):
        r = self.spawn('h1', 'codex', pane='stranger')
        self.assertIn('not a lead of this run', r.stderr)
        r = self.spawn('h1', 'codex', '--tier', 'strong')
        self.assertIn('--tier was removed', r.stderr)

    def test_base_from_builds_on_the_owners_worktree(self):
        wt = self.root / 'wt' / 'sol'
        wt.mkdir(parents=True)
        self.write_run([dict(SIBLING, worktree=str(wt))])
        r = self.spawn('sh1', 'claude', '--base-from', 'sol', pane='sibpane')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('would create from sol', r.stdout)
        # The principal may also build on the sibling's slice; a sibling may not build on others.
        self.write_run([dict(SIBLING, worktree=str(wt)),
                        {'name': 'ph', 'provider': 'claude', 'owner': 'lead', 'worktree': str(wt), 'status': 'ready'}])
        r = self.spawn('sh2', 'claude', '--base-from', 'ph', pane='sibpane')
        self.assertIn("belongs to 'lead'", r.stderr)


class OwnershipTests(RunFixture, unittest.TestCase):
    def test_sibling_cannot_dispatch_or_clean_the_principals_sessions(self):
        self.write_run([SIBLING, {'name': 'ph', 'provider': 'claude', 'owner': 'lead', 'pane': 'p1', 'status': 'ready'}])
        for name, args in (('dispatch.sh', ('--name', 'ph')), ('cleanup.sh', ('--name', 'ph'))):
            r = self.script(name, '--run', str(self.run), *args, pane='sibpane')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("belongs to 'lead'", r.stderr)
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish', pane='sibpane')
        self.assertIn('only the principal', r.stderr)

    def test_members(self):
        self.write_run([SIBLING])
        for pane, who in (('principal', 'lead'), ('sibpane', 'sol'), ('panel', 'panel'), ('x', 'outsider')):
            r = subprocess.run(['python3', str(SCRIPTS / 'members.py'), 'whoami', str(self.run), pane],
                               capture_output=True, text=True, env=self.env)
            self.assertEqual(r.stdout.strip(), who)
        r = subprocess.run(['python3', str(SCRIPTS / 'members.py'), 'find', 'sibpane'],
                           capture_output=True, text=True, env=self.env)
        self.assertEqual(r.stdout.split(), [str(self.run), 'sol'])

    def test_sibling_integrates_only_into_its_own_worktree(self):
        repo = self.root / 'checkout'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        sdir = self.run / 'ph'
        sdir.mkdir()
        (sdir / 'baseline.json').write_text(json.dumps({'repo': str(repo), 'baseline_tree': '0' * 40}))
        patch = sdir / 'delta.patch'
        patch.write_text('diff --git a/x b/x\n')
        self.write_run([dict(SIBLING, worktree=str(self.root / 'wt' / 'sol')),
                        {'name': 'ph', 'owner': 'lead', 'status': 'settled', 'state_dir': str(sdir)}])
        r = self.script('integrate.sh', '--state', str(sdir), '--patch', str(patch), pane='sibpane')
        self.assertIn('only into its own worktree', r.stderr)


class HookTests(RunFixture, unittest.TestCase):
    def hook(self, event, pane='principal'):
        env = dict(self.env, HERDR_PANE_ID=pane)
        r = subprocess.run(['python3', str(SCRIPTS / 'hook.py')], input=json.dumps({'hook_event_name': event}),
                           env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        return json.loads(r.stdout)['hookSpecificOutput']['additionalContext'] if r.stdout.strip() else None

    def set_limits(self, used):
        self.limits.write_text(json.dumps({'fiveHour': {'usedPercentage': used, 'resetsAt': time.time() + 3600},
                                           'fetchedAtMs': time.time() * 1000}))

    def test_silent_outside_a_run_and_for_finished_runs(self):
        self.assertIsNone(self.hook('UserPromptSubmit', pane='elsewhere'))
        state = json.loads((self.run / 'state.json').read_text())
        state['status'] = 'finished'
        (self.run / 'state.json').write_text(json.dumps(state))
        self.assertIsNone(self.hook('UserPromptSubmit'))

    def test_prompt_gets_quota_and_tool_use_only_news(self):
        self.set_limits(40)
        text = self.hook('UserPromptSubmit')
        self.assertIn('herdr-duo (principal', text)
        self.assertIn('claude 60% left', text)
        self.assertIsNone(self.hook('PostToolUse'))
        self.set_limits(95)
        (self.root / 'state' / 'quota-cache.json').unlink()
        text = self.hook('PostToolUse')
        self.assertIn('QUOTA LOW', text)
        self.assertIn('handoff.sh', text)
        self.assertIsNone(self.hook('PostToolUse'))
        with open(self.run / 'alerts.log', 'a') as f:
            f.write('12:00 sibling sol ran out of 5h quota\n')
        self.assertIn('ALERT: 12:00 sibling sol', self.hook('PostToolUse'))

    def test_sibling_is_told_to_report_partial(self):
        self.write_run([SIBLING], kind='claude')
        codex = self.root / 'codex' / 'sessions' / '2026'
        codex.mkdir(parents=True)
        reset = int(time.time() + 3600)
        (codex / 'rollout-x.jsonl').write_text(
            '{"rate_limits":{"limit_id":"codex","primary":{"used_percent":96.0,"window_minutes":300,"resets_at":%d}}}\n' % reset)
        text = self.hook('UserPromptSubmit', pane='sibpane')
        self.assertIn("sibling 'sol'", text)
        self.assertIn('STATUS: partial', text)


class InstallHookTests(RunFixture, unittest.TestCase):
    def test_install_is_idempotent_keeps_other_hooks_and_uninstalls(self):
        claude, codex = self.root / 'claude', self.root / 'codex'
        claude.mkdir()
        codex.mkdir(exist_ok=True)
        other = {'hooks': {'SessionStart': [{'hooks': [{'type': 'command', 'command': 'herdr-agent-state.sh'}]}]}}
        (claude / 'settings.json').write_text(json.dumps(dict(other, model='opus')))
        (codex / 'hooks.json').write_text(json.dumps(other))
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(claude), CODEX_HOME=str(codex))
        for _ in range(2):
            r = subprocess.run(['bash', str(SCRIPTS / 'install-hooks.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        for path in (claude / 'settings.json', codex / 'hooks.json'):
            data = json.loads(path.read_text())
            self.assertEqual(data['hooks']['SessionStart'], other['hooks']['SessionStart'])
            for event in ('UserPromptSubmit', 'PostToolUse'):
                self.assertEqual(len(data['hooks'][event]), 1)
                self.assertIn('herdr-duo/scripts/hook.py', data['hooks'][event][0]['hooks'][0]['command'])
        self.assertEqual(json.loads((claude / 'settings.json').read_text())['model'], 'opus')
        subprocess.run(['bash', str(SCRIPTS / 'install-hooks.sh'), '--uninstall'], env=env, check=True, capture_output=True)
        self.assertEqual(json.loads((codex / 'hooks.json').read_text()), other)



class EffortTests(RunFixture, unittest.TestCase):
    def lead_effort(self, effort):
        lead = json.loads((self.run / 'lead.json').read_text())
        lead['effort'] = effort
        (self.run / 'lead.json').write_text(json.dumps(lead))

    def test_sibling_inherits_the_principals_effort(self):
        for effort, codex in (('low', 'low'), ('medium', 'medium'), ('max', 'max')):
            with self.subTest(effort=effort):
                self.lead_effort(effort)
                r = self.spawn('sol', 'codex', '--level', 'sibling')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'model_reasoning_effort={codex}', r.stdout)
        self.write_run(kind='codex')
        self.lead_effort('ultra')
        r = self.spawn('opus', 'claude', '--level', 'sibling')
        self.assertIn('--effort max', r.stdout)

    def test_helpers_always_xhigh_on_both_subscriptions(self):
        self.lead_effort('low')
        self.assertIn('model_reasoning_effort=xhigh', self.spawn('h1', 'codex').stdout)
        self.assertIn('--effort xhigh', self.spawn('h2', 'claude').stdout)
        r = self.spawn('h3', 'claude', '--effort', 'bogus')
        self.assertIn('not valid for claude', r.stderr)


class CleanupTests(RunFixture, unittest.TestCase):
    def test_finish_refuses_live_sessions_then_deletes_the_run(self):
        self.write_run([dict(SIBLING, status='settled')])
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish')
        self.assertEqual(r.returncode, 8)
        self.assertIn('still open: sol', r.stderr)
        self.write_run([dict(SIBLING, status='cleaned')])
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('final status', r.stdout)
        self.assertFalse(self.run.exists())
        self.assertFalse((self.state_root / 'runs' / 'repo-1').exists())

    def test_prune_keeps_runs_with_worktrees(self):
        old = self.state_root / 'runs' / 'repo-1' / '20261001T000000Z'
        old.mkdir(parents=True)
        (old / 'state.json').write_text(json.dumps({'status': 'planning', 'workers': []}))
        (old / 'lead.json').write_text(json.dumps({'pane': 'gone'}))
        wt = self.root / 'wt' / 'x'
        wt.mkdir(parents=True)
        self.write_run([{'name': 'x', 'role': 'implementer', 'worktree': str(wt), 'status': 'ready'}])
        herdr = self.bin / 'herdr'
        herdr.write_text('#!/bin/sh\necho \'{"result":{"agents":[]}}\'\n')
        herdr.chmod(0o755)
        r = self.script('cleanup.sh', '--prune')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(old.exists())
        self.assertTrue(self.run.exists())
        self.assertIn('worktrees still exist', r.stdout)



class RoundTwoRegressionTests(RunFixture, unittest.TestCase):
    """Findings of the Opus/Sol cross-review, round 2."""

    def fake_herdr(self, script):
        herdr = self.bin / 'herdr'
        herdr.write_text('#!/bin/sh\n' + script)
        herdr.chmod(0o755)

    def test_prune_aborts_when_panes_cannot_be_listed(self):
        self.fake_herdr('exit 1\n')
        r = self.script('cleanup.sh', '--prune')
        self.assertEqual(r.returncode, 2)
        self.assertIn('nothing deleted', r.stderr)
        self.assertTrue(self.run.exists())
        self.fake_herdr('echo not-json\n')
        self.assertIn('unreadable', self.script('cleanup.sh', '--prune').stderr)

    def test_finish_refuses_a_promoted_worktree(self):
        wt = self.root / 'wt' / 'sol'
        wt.mkdir(parents=True)
        self.write_run([dict(SIBLING, status='promoted', worktree=str(wt))])
        r = self.script('cleanup.sh', '--run', str(self.run), '--finish')
        self.assertEqual(r.returncode, 8)
        self.assertIn('worktrees still open: sol', r.stderr)
        self.assertTrue(self.run.exists())

    def test_sibling_cannot_reuse_a_principal_helpers_name(self):
        self.write_run([SIBLING, {'name': 'ph', 'provider': 'codex', 'owner': 'lead', 'status': 'ready'}])
        r = self.spawn('ph', 'codex', pane='sibpane')
        self.assertIn("belongs to 'lead'", r.stderr)

    def test_invalid_explicit_effort_is_rejected(self):
        r = subprocess.run(['python3', str(SCRIPTS / 'lead-models.py'), 'init', '--pane', 'p',
                            '--model', 'gpt-6.1-sol', '--effort', 'bogus'], capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 2)
        self.assertIn('invalid effort', r.stderr)

    def test_failed_sibling_launch_releases_its_reservation(self):
        self.fake_herdr('exit 1\n')  # placement and start fail
        repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                        '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x'], check=True)
        state = json.loads((self.run / 'state.json').read_text())
        state['repo'] = str(repo)
        (self.run / 'state.json').write_text(json.dumps(state))
        r = self.script('spawn.sh', '--run', str(self.run), '--name', 'sol', '--provider', 'codex', '--level', 'sibling')
        self.assertNotEqual(r.returncode, 0)
        workers = json.loads((self.run / 'state.json').read_text())['workers']
        self.assertFalse([w for w in workers if w.get('status') == 'starting'], workers)

    def test_report_extractor_keeps_multi_paragraph_findings(self):
        transcript = ('• STATUS: findings\n  CHANGED: none\n  FINDINGS:\n\n  1. BLOCKING — a.sh:1: x\n'
                      '     more\n\n  2. NON-BLOCKING — b.sh:2: y\n\n  Worked for 1m\n\n› Ask Codex\n')
        out = subprocess.run(['python3', str(SCRIPTS / 'extract-report.py')], input=transcript,
                             capture_output=True, text=True).stdout
        self.assertIn('1. BLOCKING', out)
        self.assertIn('2. NON-BLOCKING', out)
        self.assertNotIn('Worked for', out)
        plain = subprocess.run(['python3', str(SCRIPTS / 'extract-report.py')],
                               input='STATUS: done\nCHANGED: a\nFINDINGS: none\n\n> prompt\n',
                               capture_output=True, text=True).stdout
        self.assertEqual(plain.strip().splitlines()[-1], 'FINDINGS: none')


class RoundThreeRegressionTests(RunFixture, unittest.TestCase):
    """Findings of the Opus/Sol cross-review, round 3."""

    def failing_repo(self):
        herdr = self.bin / 'herdr'
        herdr.write_text('#!/bin/sh\nexit 1\n')
        herdr.chmod(0o755)
        repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                        '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x'], check=True)
        return repo

    def test_a_starting_launch_blocks_every_other_sibling_launch(self):
        self.write_run([dict(SIBLING, status='starting', pane=None)])
        for name in ('sol', 'sol2'):
            r = self.script('spawn.sh', '--run', str(self.run), '--name', name, '--provider', 'codex', '--level', 'sibling')
            self.assertIn("sibling 'sol' is still live", r.stderr)

    def test_failed_relaunch_of_a_cleaned_name_restores_it(self):
        repo = self.failing_repo()
        self.write_run([dict(SIBLING, status='cleaned', pane=None)])
        state = json.loads((self.run / 'state.json').read_text())
        state['repo'] = str(repo)
        (self.run / 'state.json').write_text(json.dumps(state))
        r = self.script('spawn.sh', '--run', str(self.run), '--name', 'sol', '--provider', 'codex', '--level', 'sibling')
        self.assertNotEqual(r.returncode, 0)
        sol = json.loads((self.run / 'state.json').read_text())['workers'][0]
        self.assertEqual(sol['status'], 'cleaned')
        self.assertNotIn('reserved_from', sol)

    def test_a_former_helper_name_cannot_become_the_sibling(self):
        self.write_run([{'name': 'sol', 'provider': 'codex', 'level': 'helper', 'owner': 'lead',
                         'status': 'cleaned', 'role': 'implementer'}])
        r = self.script('spawn.sh', '--run', str(self.run), '--name', 'sol', '--provider', 'codex', '--level', 'sibling')
        self.assertIn('was a helper in this run', r.stderr)
        self.assertEqual(json.loads((self.run / 'state.json').read_text())['workers'][0]['status'], 'cleaned')

    def test_inline_findings_keep_later_paragraphs(self):
        transcript = 'STATUS: findings\nFINDINGS: 1. first\n\n2. second\n\nWorked for 1m\n'
        out = subprocess.run(['python3', str(SCRIPTS / 'extract-report.py')], input=transcript,
                             capture_output=True, text=True).stdout
        self.assertIn('2. second', out)
        self.assertNotIn('Worked', out)


if __name__ == '__main__':
    unittest.main()
