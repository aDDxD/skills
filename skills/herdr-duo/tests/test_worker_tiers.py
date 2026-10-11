"""Worker selection with temporary repositories and CLI dry runs; no live agents."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class WorkerTierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / 'run'
        self.run.mkdir()
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.root / 'config'),
                        HERDR_DUO_STATE_ROOT=str(self.root / 'state'), HERDR_PANE_ID='')
        for key in list(self.env):
            if key.startswith('HERDR_DUO_') and key not in ('HERDR_DUO_STATE_ROOT',):
                self.env.pop(key)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        codex = self.bin / 'codex'
        codex.write_text('#!/bin/sh\nprintf "synthetic CLI --no-daemon\\n"\n')
        codex.chmod(0o755)
        self.env['PATH'] = str(self.bin) + os.pathsep + self.env['PATH']

    def script(self, name, *args):
        return subprocess.run(['bash', str(SCRIPTS / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def state(self, tier=None, busy=False):
        state = {'repo': str(self.root), 'wt_root': str(self.root / 'wt'),
                 'workers': [], 'reviewers': []}
        if tier is not None:
            state['worker_tier'] = tier
        if busy:
            state['workers'].append({'name': 'busy', 'tier': 'strong', 'status': 'dispatched'})
        (self.run / 'state.json').write_text(json.dumps(state))

    def spawn(self, provider='codex', role='implementer', *extra):
        return self.script('spawn.sh', '--run', str(self.run), '--name', 'candidate',
                           '--provider', provider, '--role', role, '--dry-run', *extra)

    def test_defaults_both_providers_and_legacy(self):
        for tier, codex, claude in ((None, 'gpt-6-luna', 'claude-haiku-5-5'),
                                    ('base', 'gpt-6-luna', 'claude-haiku-5-5'),
                                    ('strong', 'gpt-6.1-sol', 'claude-sonnet-5-5')):
            self.state(tier)
            for provider, model in (('codex', codex), ('claude', claude)):
                with self.subTest(tier=tier, provider=provider):
                    result = self.spawn(provider)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(model, result.stdout)
                    self.assertFalse((self.root / 'wt').exists())

    def test_strong_parallelism_and_base_slot(self):
        self.state('strong', busy=True)
        result = self.spawn()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('gpt-6.1-sol', result.stdout)
        for tier in (None, 'base'):
            self.state(tier, busy=True)
            result = self.spawn('codex', 'implementer', '--tier', 'strong')
            self.assertEqual(result.returncode, 2)
            self.assertIn('still live', result.stderr)
            result = self.spawn()
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_reviewers_inherit_level_and_override_remains_available(self):
        self.state('strong', busy=True)
        author = self.run / 'author'
        author.mkdir()
        (author / 'baseline.json').write_text(json.dumps({'worktree': str(self.root)}))
        result = self.spawn('claude', 'reviewer', '--review-of', 'author')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('claude-sonnet-5-5', result.stdout)
        self.assertIn('dontAsk', result.stdout)
        result = self.spawn('codex', 'implementer', '--tier', 'base')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('gpt-6-luna', result.stdout)

    def test_strong_worker_cannot_escalate(self):
        self.state('strong')
        path = self.run / 'state.json'
        state = json.loads(path.read_text())
        state['workers'] = [{'name': 'candidate', 'role': 'implementer', 'tier': 'strong'}]
        path.write_text(json.dumps(state))
        before = path.read_bytes()
        result = self.script('escalate.sh', '--run', str(self.run), '--name', 'candidate',
                             '--reason', 'failed twice')
        self.assertEqual(result.returncode, 2)
        self.assertIn('do not escalate further', result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_init_persists_choice_and_rejects_invalid_level(self):
        repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(repo)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Synthetic',
                        '-c', 'user.email=synthetic@example.invalid', '-c', 'commit.gpgsign=false',
                        'commit', '-q', '--allow-empty', '-m', 'Baseline'], check=True, capture_output=True)
        for tier in ('base', 'strong'):
            result = self.script('run-init.sh', '--repo', str(repo), '--no-panel', '--worker-tier', tier)
            self.assertEqual(result.returncode, 0, result.stderr)
            run = Path(next(line[4:] for line in result.stdout.splitlines() if line.startswith('RUN=')))
            self.assertEqual(json.loads((run / 'state.json').read_text())['worker_tier'], tier)
            status = self.script('status.sh', '--run', str(run))
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertIn(f'worker tier: {tier}', status.stdout)
        result = self.script('run-init.sh', '--repo', str(repo), '--worker-tier', 'astra')
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
