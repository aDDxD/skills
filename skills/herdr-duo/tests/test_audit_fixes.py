"""Audit regressions: synthetic files and fake CLIs, never live panes or providers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
from unittest.mock import patch

from test_leads import RunFixture
from test_quota import QuotaFixture, load_quota, NOW

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class AuditQuotaTests(QuotaFixture, unittest.TestCase):
    def test_rollout_json_whitespace_key_order_and_partial_lines(self):
        path = self.codex_rollout(30, 100)
        record = {'payload': {'rate_limits': {'primary': {
            'resets_at': NOW + 3600, 'window_minutes': 300, 'used_percent': 17}}}}
        path.write_text('partial previous line\n' + json.dumps(record) + '\n{"unfinished":')
        self.assertEqual(load_quota().codex_reading()['used'], 17)

    def test_reading_survives_removed_file_and_five_new_empty_sessions(self):
        path = self.codex_rollout(33, 100)
        os.utime(path, (NOW - 100, NOW - 100))
        for i in range(6):
            other = path.parent / f'new-{i}.jsonl'
            other.write_text('{"type":"session_meta"}\n')
            os.utime(other, (NOW + i, NOW + i))
        m = load_quota()
        real = os.path.getmtime
        with patch.object(m.glob, 'glob', return_value=[str(path.parent / 'gone')] + [str(p) for p in path.parent.iterdir()]), \
                patch.object(m.os.path, 'getmtime', side_effect=real):
            self.assertEqual(m.codex_reading()['used'], 33)

    def test_invalid_quota_records_are_skipped(self):
        path = self.codex_rollout(33, 100)
        with path.open('a') as f:
            for used in ('NaN', 101, -1, None):
                f.write(json.dumps({'rate_limits': {'primary': {'used_percent': used,
                    'window_minutes': 300, 'resets_at': NOW + 100}}}) + '\n')
        self.assertEqual(load_quota().codex_reading()['used'], 33)

    def test_reset_surplus_remains_full_with_previous_history(self):
        self.claude(80, 10)
        m = load_quota()
        m.snapshot()
        with patch.dict(os.environ, {'HERDR_DUO_NOW': str(NOW + 1200)}):
            q = m.snapshot()
        self.assertEqual(q['claude']['surplus'], 100)

    def test_concurrent_cache_writers_leave_valid_json_without_temp_files(self):
        self.claude(20, 100)
        self.codex_rollout(30, 100)
        procs = [subprocess.Popen(['python3', '-B', str(SCRIPTS / 'quota.py'), 'json'],
                    env=os.environ.copy(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                 for _ in range(8)]
        for proc in procs:
            stdout, stderr = proc.communicate(timeout=20)
            self.assertEqual(proc.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)['claude']['left'], 80)
        state = Path(self.env['HERDR_DUO_STATE_ROOT'])
        self.assertEqual(json.loads((state / 'quota-cache.json').read_text())['quota']['codex']['left'], 70)
        self.assertEqual(list(state.glob('*.tmp')), [])
        history = [json.loads(line) for line in (state / 'quota-history.jsonl').read_text().splitlines()]
        self.assertEqual({row['p'] for row in history}, {'claude', 'codex'})

    def test_history_writer_merges_samples_from_another_snapshot(self):
        m = load_quota()
        m.record([], 'claude', 20, NOW + 3600)
        history = m.record([], 'codex', 30, NOW + 3600)
        self.assertEqual([row['p'] for row in history], ['claude', 'codex'])

    def test_invalid_claude_reading_is_unknown(self):
        for used in (float('nan'), 101, -1):
            self.claude(used, 100)
            self.assertIsNone(load_quota().claude_reading())


class AuditHookTests(RunFixture, unittest.TestCase):
    def test_install_preserves_other_commands_and_group_metadata(self):
        config = self.root / 'claude'
        config.mkdir()
        path = config / 'settings.json'
        other = {'type': 'command', 'command': 'my-existing-hook'}
        group = {'matcher': '*', 'hooks': [other, {'type': 'command',
            'command': "python3 '/old/herdr-duo/scripts/hook.py'"}]}
        path.write_text(json.dumps({'hooks': {'PostToolUse': [group]}}))
        env = self.env | {'CLAUDE_CONFIG_DIR': str(config)}
        for options in ([], ['--uninstall']):
            result = subprocess.run(['bash', str(SCRIPTS / 'install-hooks.sh'), '--claude-only', *options],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            groups = json.loads(path.read_text())['hooks']['PostToolUse']
            self.assertEqual(groups[0], {'matcher': '*', 'hooks': [other]})
        self.assertEqual(len(groups), 1)

    def test_installed_hook_command_quotes_apostrophes_in_skill_path(self):
        import shlex
        scripts = self.root / "it's a skill" / 'herdr-duo' / 'scripts'
        scripts.mkdir(parents=True)
        shutil.copyfile(SCRIPTS / 'install-hooks.sh', scripts / 'install-hooks.sh')
        config = self.root / 'claude'
        config.mkdir()
        result = subprocess.run(['bash', str(scripts / 'install-hooks.sh'), '--claude-only'],
            env=self.env | {'CLAUDE_CONFIG_DIR': str(config)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads((config / 'settings.json').read_text())['hooks']['UserPromptSubmit'][0]['hooks'][0]['command']
        self.assertEqual(shlex.split(command), ['python3', str(scripts / 'hook.py')])

    def test_invalid_threshold_never_fails_hook_caller(self):
        result = subprocess.run(['python3', '-B', str(SCRIPTS / 'hook.py')], input='{}',
            env=self.env | {'HERDR_DUO_LEAD_WARN_PCT': 'invalid'}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')


class AuditDispatchTests(RunFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.write_run([{'name': 'h1', 'owner': 'lead', 'pane': 'p1', 'status': 'ready', 'model': 'fake'}])
        (self.run / 'h1').mkdir()
        (self.run / 'h1' / 'assignment.md').write_text('test')
        herdr = self.bin / 'herdr'
        herdr.write_text('''#!/bin/bash
case "$1 $2" in
  'pane read') exit 0 ;;
  'agent get') echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  'agent prompt') exit "${FAKE_PROMPT_RC:-0}" ;;
  'agent read') exit 1 ;;
esac
''')
        herdr.chmod(0o755)

    def test_missing_report_and_timeout_keep_documented_exit_codes(self):
        for prompt_rc, expected in (('0', 5), ('1', 7)):
            self.env['FAKE_PROMPT_RC'] = prompt_rc
            result = self.script('dispatch.sh', '--run', str(self.run), '--name', 'h1')
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertIn(f'exit={expected}', result.stdout)

    def test_invalid_timeout_and_conflicting_collect_options_fail_before_dispatch(self):
        for args in (('--timeout-min', '0'), ('--timeout-min', 'oops'), ('--collect', '--message', 'x')):
            result = self.script('dispatch.sh', '--run', str(self.run), '--name', 'h1', *args)
            self.assertEqual(result.returncode, 2, result.stderr)
            worker = json.loads((self.run / 'state.json').read_text())['workers'][0]
            self.assertEqual(worker['status'], 'ready')


class AuditIntegrationTests(RunFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.worker = self.run / 'h1'
        self.worker.mkdir()
        (self.worker / 'baseline.json').write_text(json.dumps({'repo': str(self.repo), 'baseline_tree': 'base'}))
        self.delta = self.worker / 'delta.patch'
        self.delta.write_text('synthetic patch')
        git = self.bin / 'git'
        git.write_text('''#!/bin/bash
if [ "$1" = -C ]; then shift 2; fi
case "$1" in
 rev-parse) if [ "$2" = --git-dir ]; then echo .git; else echo blob; fi ;;
 hash-object) echo blob ;;
 ls-tree) echo 100644 ;;
 apply)
   if [ "$2" = --numstat ]; then
     [ "${FAKE_BAD_PATCH:-0}" = 0 ] || exit 1
     printf '1\\t1\\tx\\0'
   fi ;;
esac
''')
        git.chmod(0o755)

    def integrate(self):
        return self.script('integrate.sh', '--state', str(self.worker), '--patch', str(self.delta))

    def test_executable_bit_change_conflicts_even_when_contents_match(self):
        path = self.repo / 'x'
        path.write_text('contents')
        path.chmod(0o644)
        self.assertEqual(self.integrate().returncode, 0)
        path.chmod(0o755)
        result = self.integrate()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('100755', result.stderr)

    def test_directory_is_not_treated_as_absent_file(self):
        (self.repo / 'x').mkdir()
        result = self.integrate()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('non-file', result.stderr)

    def test_invalid_patch_inspection_is_reported_as_conflict(self):
        self.env['FAKE_BAD_PATCH'] = '1'
        result = self.integrate()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn('cannot inspect patch', result.stderr)


class AuditGuardTests(RunFixture, unittest.TestCase):
    def test_missing_worker_worktree_or_baseline_is_a_violation(self):
        git = self.bin / 'git'
        git.write_text('''#!/bin/bash
if [ "$1" = -C ]; then shift 2; fi
case "$1" in
 rev-parse) if [ "$2" = --git-common-dir ]; then echo .git; else echo fixed-head; fi ;;
 symbolic-ref) echo refs/heads/main ;;
esac
''')
        git.chmod(0o755)
        worker = self.root / 'worker'
        worker.mkdir()
        state_dir = self.run / 'h1'
        state_dir.mkdir()
        baseline = state_dir / 'baseline.json'
        baseline.write_text('{"head":"fixed-head"}')
        self.write_run([{'name': 'h1', 'worktree': str(worker), 'state_dir': str(state_dir), 'status': 'ready'}])
        self.assertEqual(self.script('guard.sh', 'snapshot', '--run', str(self.run)).returncode, 0)
        baseline.unlink()
        result = self.script('guard.sh', 'verify', '--run', str(self.run))
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('worktree or baseline disappeared', result.stdout)
        baseline.write_text('{"head":"fixed-head"}')
        worker.rmdir()
        self.assertEqual(self.script('guard.sh', 'verify', '--run', str(self.run)).returncode, 4)
        self.write_run([{'name': 'h1', 'worktree': str(worker), 'state_dir': str(state_dir), 'status': 'cleaned'}])
        self.assertEqual(self.script('guard.sh', 'verify', '--run', str(self.run)).returncode, 0)


class AuditPanelTests(unittest.TestCase):
    def test_panel_exits_when_finished_run_directory_was_removed(self):
        spec = importlib.util.spec_from_file_location('panel_audit', SCRIPTS / 'panel.py')
        panel = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(panel)
        with tempfile.TemporaryDirectory() as root:
            panel.RUN = str(Path(root) / 'deleted-run')
            with patch.object(panel.time, 'sleep', side_effect=AssertionError('panel must exit')), \
                    patch('builtins.print'):
                panel.main()


class AuditMembersTests(unittest.TestCase):
    def test_run_cleanup_during_discovery_does_not_hide_other_live_runs(self):
        spec = importlib.util.spec_from_file_location('members_audit', SCRIPTS / 'members.py')
        members = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(members)
        with tempfile.TemporaryDirectory() as root:
            lead = Path(root) / 'lead.json'
            lead.write_text('{"pane":"p1"}')
            with patch.object(members.glob, 'glob', return_value=[str(lead), str(lead.parent / 'gone')]):
                self.assertEqual(members.find('p1'), (root, 'lead'))


if __name__ == '__main__':
    unittest.main()
