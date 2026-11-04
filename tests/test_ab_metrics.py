"""T1-6 ab_metrics tests: hook.log parsing, query-log batch parsing, A/B math, CLI smoke.

Everything runs offline: replay functions are faked, fixtures are inline.
"""
import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ab_metrics', ROOT / 'scripts' / 'ab_metrics.py')
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)

INJECTED = (
    "【respire · auto-recall】matched 2 item(s) (rsrs direct, title tier; "
    "read bodies on demand with rsrs show <short-id>; scores are relevance, not confidence):\n"
    "- [3.49] 12:36 9-9上午：继续LMCC备课（78aab969）\n"
    "- [2.30] 用户偏好：止盈后推保本损（e32edc80） →superseded"
)


class HookLogTest(unittest.TestCase):
    def test_load_hook_events_skips_malformed_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'hook.log'
            path.write_text(
                '{"ts":"2026-11-04T10:00:00","ev":"recall","out":"hit","ms":900,"d":"n=5 max=3.2 q=deploy"}\n'
                'not json\n'
                '{"ts":"2026-11-04T10:00:01","ev":"show","out":"ok","d":"src=shell 78aab969"}\n'
                '{"no":"ev"}\n',
                encoding='utf-8',
            )
            events, skipped = ab.load_hook_events(str(path))
        self.assertEqual(len(events), 2)
        self.assertEqual(skipped, 2)

    def test_missing_file_reports_minus_one(self):
        events, skipped = ab.load_hook_events('/nonexistent/hook.log')
        self.assertEqual((events, skipped), ([], -1))

    def test_detail_fields_extracts_numeric_keys(self):
        self.assertEqual(ab.detail_fields('n=5 max=5.209 chars=1412 q=deploy failed'),
                         {'n': 5, 'max': 5, 'chars': 1412})
        self.assertEqual(ab.detail_fields(None), {})

    def test_aggregate_counts_and_show_attribution(self):
        events = [
            {"ts": "2026-11-04T10:00:00", "ev": "recall", "out": "hit", "ms": 800,
             "d": "n=5 max=3.2 chars=610 q=alpha"},
            {"ts": "2026-11-04T10:00:30", "ev": "show", "out": "ok", "d": "src=shell 78aab969"},
            {"ts": "2026-11-04T10:01:00", "ev": "recall", "out": "defer_sentence", "d": "beta"},
            {"ts": "2026-11-04T10:02:00", "ev": "show", "out": "ok", "d": "src=mcp e32edc80"},
            {"ts": "2026-11-04T10:03:00", "ev": "due", "out": "hit", "ms": 2200, "d": "n=100+"},
            {"ts": "2026-11-04T10:04:00", "ev": "stop", "out": "nudge"},
        ]
        agg = ab.aggregate_log(events)
        self.assertEqual(agg['by_out'][('recall', 'hit')], 1)
        self.assertEqual(len(agg['recall_hit']), 1)
        self.assertEqual(agg['recall_hit'][0]['chars'], 610)
        self.assertEqual(len(agg['due_hit']), 1)
        self.assertEqual(agg['store'], {})
        self.assertEqual(agg['stop'], {'nudge': 1})
        # show at 10:00:30 belongs to turn 1; show at 10:02 belongs to turn 2
        per_turn = ab.shows_per_turn(agg)
        self.assertEqual(per_turn['turns'], 2)
        self.assertEqual(per_turn['shows'], 2)
        self.assertEqual(per_turn['avg'], 1.0)
        self.assertEqual(per_turn['max'], 1)

    def test_log_report_mentions_metrics_and_kou_jing(self):
        events = [
            {"ts": "2026-11-04T10:00:00", "ev": "recall", "out": "hit", "ms": 800,
             "d": "n=5 max=3.2 chars=610 q=alpha"},
        ]
        agg = ab.aggregate_log(events)
        report = ab.format_log_report(agg, 0, 'fixture')
        self.assertIn('recall hits', report)
        self.assertIn('chars avg=610', report)
        self.assertIn('口径', report)

    def test_log_report_without_chars_field_says_use_ab(self):
        agg = ab.aggregate_log([{"ts": "t", "ev": "recall", "out": "hit", "ms": 10,
                                 "d": "n=5 max=1.0 q=x"}])
        report = ab.format_log_report(agg, 0, 'fixture')
        self.assertIn('n/a', report)
        self.assertIn('`ab` mode', report)


class QueryBatchTest(unittest.TestCase):
    def test_parse_query_log_value(self):
        value = ('2026-11-04T06:13:23.704785027+00:00 respire 判级 提示词 '
                 'cand=12db9c9a,0724579e adopted=- good=12db9c9a bad=-')
        parsed = ab.parse_query_log_value(value)
        self.assertEqual(parsed['ts'], '2026-11-04T06:13:23.704785027+00:00')
        self.assertEqual(parsed['query'], 'respire 判级 提示词')
        self.assertEqual(parsed['candidates'], ['12db9c9a', '0724579e'])
        self.assertEqual(parsed['adopted'], [])
        self.assertEqual(parsed['good'], ['12db9c9a'])
        self.assertEqual(parsed['bad'], [])

    def test_parse_query_log_value_rejects_garbage(self):
        self.assertIsNone(ab.parse_query_log_value('no envelope here'))

    def test_parse_query_log_doc(self):
        doc = {'details': [
            {'value': '2026-11-04T00:00:00+00:00 deploy failed cand=aaaaaaaa adopted=- good=- bad=-'},
            {'value': 'broken'},
            'not a dict',
        ]}
        batch = ab.parse_query_log_doc(doc)
        self.assertEqual(len(batch), 1)
        self.assertEqual(batch[0]['query'], 'deploy failed')

    def test_parse_query_log_doc_prefers_items_rows(self):
        # Real envelope: query text lives in items[] (name="query"), details[]
        # only carries structured candidate uuids.
        doc = {
            'items': [
                {'name': 'query', 'status': 'ok',
                 'value': '2026-11-04T06:13:23+00:00 respire 判级 cand=12db9c9a '
                          'adopted=- good=- bad=-'},
                {'name': 'other', 'value': 'ignored'},
            ],
            'details': [{'candidates': ['12db9c9a-ac4e-4973-b939-c8a5ee3ae1df']}],
        }
        batch = ab.parse_query_log_doc(doc)
        self.assertEqual(len(batch), 1)
        self.assertEqual(batch[0]['query'], 'respire 判级')
        self.assertEqual(batch[0]['candidates'], ['12db9c9a'])

    def test_queries_from_hook_log_dedupes_fragments(self):
        events = [
            {"ev": "recall", "out": "hit", "d": "n=5 max=3.0 q=why did it crash"},
            {"ev": "recall", "out": "hit", "d": "n=5 max=3.0 q=why did it crash"},
            {"ev": "recall", "out": "defer_sentence", "d": "ignored"},
        ]
        batch = ab.queries_from_hook_log(events)
        self.assertEqual(len(batch), 1)
        self.assertEqual(batch[0]['query'], 'why did it crash')


class RenderTest(unittest.TestCase):
    def test_render_ids_and_items(self):
        ids = ab.render_ids(INJECTED)
        self.assertEqual(ids, ['78aab969', 'e32edc80'])
        self.assertEqual(ab.count_items(INJECTED), 2)

    def test_render_ids_empty_text(self):
        self.assertEqual(ab.render_ids(''), [])
        self.assertEqual(ab.count_items(None), 0)


class RunAbTest(unittest.TestCase):
    BATCH = [
        {'query': 'alpha', 'good': ['aaaa1111']},
        {'query': 'beta', 'good': []},
    ]
    REF = {'alpha': ['aaaa1111', 'bbbb2222', 'cccc3333', 'dddd4444'],
           'beta': ['eeee5555']}

    def render(self, query, limit):
        # alpha@5: 1 of 4 reference ids kept, 100 chars, 700ms
        # alpha@20: all 4 kept, 1600 chars (over budget), 900ms
        # beta@5: empty (skip gate), beta@20: 1 kept, 200 chars
        if query == 'alpha' and limit == 5:
            text = '- [3.00] one（aaaa1111）'
            return text, 700
        if query == 'alpha':
            text = '\n'.join([
                '- [3.00] one（aaaa1111）',
                '- [2.00] two（bbbb2222）',
                '- [1.00] three（cccc3333）',
                '- [0.90] four（dddd4444）',
            ])
            return text + 'x' * (1600 - len(text)), 900
        if limit == 5:
            return '', 500
        return '- [1.00] five（eeee5555）', 600

    def run_ab(self, budget=1500):
        return ab.run_ab(self.BATCH, [5, 20], self.render,
                         lambda q: self.REF[q], budget)

    def test_per_limit_math(self):
        result = self.run_ab()
        five = result['per_limit'][5]
        self.assertEqual(five['queries'], 2)
        alpha5 = len(self.render('alpha', 5)[0])
        beta5 = len(self.render('beta', 5)[0])
        self.assertEqual(five['chars_avg'], round((alpha5 + beta5) / 2))
        self.assertEqual(five['chars_max'], max(alpha5, beta5))
        self.assertEqual(five['over_budget'], 0)
        # alpha keeps 1/4, beta renders nothing -> 0/1
        self.assertEqual(five['coverage_avg'], 0.125)
        self.assertEqual(five['ms_avg'], 600)
        twenty = result['per_limit'][20]
        self.assertEqual(twenty['over_budget'], 1)  # alpha 1600 > 1500
        self.assertEqual(twenty['coverage_avg'], 1.0)
        self.assertEqual(twenty['items_avg'], 2.5)

    def test_good_mark_hit(self):
        result = self.run_ab()
        five = result['per_limit'][5]
        self.assertEqual(five['good_marked'], 1)
        self.assertEqual(five['good_hits'], 1)  # aaaa1111 is rendered at limit 5

    def test_verdict_fails_on_over_budget(self):
        verdict = '\n'.join(ab.acceptance_verdict(self.run_ab()['per_limit'], 1500))
        self.assertIn('over-budget=0/2 -> PASS', verdict)   # limit 5 within budget
        self.assertIn('over-budget=1/2 -> FAIL', verdict)   # limit 20 has a 1600-char render
        self.assertIn('fix rendering/budget before raising the default', verdict)
        self.assertIn('口径', verdict)

    def test_verdict_passes_when_within_budget(self):
        result = self.run_ab(budget=100000)
        verdict = '\n'.join(ab.acceptance_verdict(result['per_limit'], 100000))
        self.assertIn('PASS', verdict)
        self.assertNotIn('FAIL', verdict)

    def test_format_ab_report_has_columns_and_rows(self):
        report = ab.format_ab_report(self.run_ab(), [5, 20], 1500, 'fixture batch')
        self.assertIn('limit 5', report)
        self.assertIn('limit 20', report)
        self.assertIn('injected chars avg', report)
        self.assertIn('coverage vs wide recall', report)
        self.assertIn('good-hit (adoption)', report)
        self.assertIn('not fact confidence', report)


class CliSmokeTest(unittest.TestCase):
    def test_log_mode_reads_fixture_and_prints(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'hook.log'
            path.write_text(
                '{"ts":"2026-11-04T10:00:00","ev":"recall","out":"hit","ms":900,'
                '"d":"n=5 max=3.2 chars=610 q=deploy"}\n',
                encoding='utf-8',
            )
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                code = ab.main(['log', '--path', str(path)])
        self.assertEqual(code, 0)
        out = buffer.getvalue()
        self.assertIn('recall/hit: 1', out)
        self.assertIn('chars avg=610', out)

    def test_log_mode_missing_file_is_diagnostic(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = ab.main(['log', '--path', '/nonexistent/hook.log'])
        self.assertEqual(code, 0)
        self.assertIn('cannot read', buffer.getvalue())

    def test_no_mode_prints_help(self):
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = ab.main([])
        self.assertEqual(code, 0)
        self.assertIn('usage', buffer.getvalue())


class HookModuleTest(unittest.TestCase):
    def test_hook_module_loads_and_exposes_replay_api(self):
        hook = ab.load_hook_module()
        self.assertTrue(hasattr(hook, 'do_recall'))
        self.assertTrue(hook.VERSION)          # release.py pins VERSION to the tag
        self.assertEqual(hook.DEFAULTS['budget_chars'], 1500)


if __name__ == '__main__':
    unittest.main()
