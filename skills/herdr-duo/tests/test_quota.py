"""5h quota sensor with synthetic usage-bar and Codex rollout files; no live providers."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
NOW = 1_800_000_000


def load_quota():
    spec = importlib.util.spec_from_file_location('quota_under_test', SCRIPTS / 'quota.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


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
        self.env = {'HERDR_DUO_STATE_ROOT': str(self.root / 'state'), 'HERDR_DUO_CLAUDE_LIMITS': str(self.limits),
                    'CODEX_HOME': str(self.codex), 'HERDR_DUO_NOW': str(NOW),
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


class ReadingTests(QuotaFixture, unittest.TestCase):
    def test_both_sources_and_weekly_ignored(self):
        self.claude(21, 120)
        self.codex_rollout(16.0, 200)
        q = load_quota().snapshot()
        self.assertEqual((q['claude']['used'], q['claude']['left'], q['claude']['mins_to_reset']), (21.0, 79.0, 120))
        self.assertEqual((q['codex']['used'], q['codex']['source']), (16.0, 'codex-rollout'))
        self.assertNotIn('99', json.dumps({p: q[p]['used'] for p in q}))

    def test_expired_window_reads_as_unused(self):
        # The Codex rollout keeps the last value it saw; a reset since then means 0% used.
        self.claude(10, 60)
        self.codex_rollout(16.0, -30)
        q = load_quota().snapshot()
        self.assertEqual((q['codex']['used'], q['codex']['left'], q['codex']['resets_at']), (0.0, 100.0, None))
        self.assertEqual(q['codex']['surplus'], 100.0)
        self.assertIn('reset', q['codex']['note'])

    def test_newest_rollout_wins_and_missing_sources_are_unknown(self):
        old = self.codex_rollout(50.0, 100, 'rollout-old.jsonl')
        os.utime(old, (NOW - 3600, NOW - 3600))
        new = self.codex_rollout(5.0, 100, 'rollout-new.jsonl')
        os.utime(new, (NOW, NOW))
        q = load_quota().snapshot()
        self.assertEqual(q['codex']['used'], 5.0)
        self.assertEqual(q['claude'], {'known': False})

    def test_rate_and_projected_surplus_from_history(self):
        m = load_quota()
        self.claude(20, 120)
        self.codex_rollout(0.0, 290)
        m.snapshot()
        # 30 minutes later Claude went from 20% to 30%: 20%/h, 2h to reset at that pace
        # (90 min left now) uses 30% of the 70% left, so ~40% would go unused.
        with patch.dict(os.environ, {'HERDR_DUO_NOW': str(NOW + 1800)}):
            self.claude(30, 120)  # same window: it still resets at NOW + 120 min
            q = m.snapshot()
        self.assertEqual(q['claude']['rate_per_hour'], 20.0)
        self.assertEqual(q['claude']['surplus'], 40.0)


class SuggestTests(QuotaFixture, unittest.TestCase):
    def q(self, claude, codex):
        def entry(left, mins, surplus=None):
            return {'known': True, 'left': left, 'used': 100 - left, 'mins_to_reset': mins,
                    'resets_at': NOW + mins * 60, 'surplus': surplus}
        return {'claude': entry(*claude), 'codex': entry(*codex)}

    def test_more_headroom_wins(self):
        p, why = load_quota().suggest(self.q((73, 214), (100, 296)))
        self.assertEqual(p, 'codex')
        self.assertIn('headroom', why)

    def test_projected_surplus_beats_raw_left(self):
        # Claude has less left but would waste more of it before its reset.
        p, _ = load_quota().suggest(self.q((60, 30, 55), (90, 280, 10)))
        self.assertEqual(p, 'claude')

    def test_tie_prefers_sooner_reset_then_alternates(self):
        m = load_quota()
        self.assertEqual(m.suggest(self.q((80, 40), (82, 250)))[0], 'claude')
        state = Path(os.environ['HERDR_DUO_STATE_ROOT'])
        state.mkdir(parents=True, exist_ok=True)
        (state / 'balance.json').write_text(json.dumps({'last_principal': 'codex'}))
        self.assertEqual(m.suggest(self.q((80, 200), (82, 210)), 'start')[0], 'claude')
        (state / 'balance.json').write_text(json.dumps({'last_principal': 'claude'}))
        self.assertEqual(m.suggest(self.q((82, 200), (80, 210)), 'start')[0], 'codex')

    def test_helper_reserve_protects_the_callers_own_window(self):
        m = load_quota()
        q = self.q((25, 100), (20, 100))
        self.assertEqual(m.suggest(q, 'helper', 'claude')[0], 'codex')
        self.assertEqual(m.suggest(q, 'helper', 'codex')[0], 'claude')

    def test_cli(self):
        self.claude(21, 120)
        self.codex_rollout(0.0, -5)
        out = subprocess.run(['python3', str(SCRIPTS / 'quota.py'), 'suggest'], capture_output=True,
                             text=True, env=os.environ | self.env, timeout=20)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines()[0], 'codex')
        line = subprocess.run(['python3', str(SCRIPTS / 'quota.py'), 'line'], capture_output=True,
                              text=True, env=os.environ | self.env, timeout=20).stdout
        self.assertIn('claude 79% left', line)
        self.assertIn('codex 100% left (fresh window)', line)


if __name__ == '__main__':
    unittest.main()
