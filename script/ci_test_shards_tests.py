#!/usr/bin/env python3
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'script' / 'ci_test_shards.py'
sys.path.insert(0, str(SCRIPT.parent))
import ci_test_shards  # noqa: E402


def selected(arguments, test_id):
    """What swift test does with one test id: --filter keeps a match, --skip drops it."""
    flag, pattern = arguments
    matches = re.search(pattern, test_id) is not None
    return matches if flag == '--filter' else not matches


class TestShardPlanTests(unittest.TestCase):
    def write_plan(self, plan):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / 'plan.json'
        path.write_text(plan if isinstance(plan, str) else json.dumps(plan))
        return str(path)

    def test_checked_in_plan_gives_every_listed_shard_a_filter_and_the_last_a_skip(self):
        shards = ci_test_shards.load_plan()
        count = ci_test_shards.shard_count(shards)
        self.assertEqual(count, len(shards) + 1)
        listed = [name for shard in shards for name in shard]
        self.assertEqual(len(listed), len(set(listed)))
        for number, shard in enumerate(shards, start=1):
            self.assertEqual(ci_test_shards.arguments(shards, number), ['--filter', '|'.join(shard)])
        self.assertEqual(ci_test_shards.arguments(shards, count), ['--skip', '|'.join(listed)])

    def test_every_test_runs_in_some_shard_whatever_the_plan_lists(self):
        shards = [['AlphaTests', 'BetaTests'], ['GammaTests']]
        test_ids = [
            'ASTRATests.AlphaTests/first()',
            'ASTRATests.BetaTests/Nested/second()',
            'ASTRATests.GammaTests/third(value:)',
            'ASTRATests.NewSuiteNobodyListed/fourth()',
            'ASTRATests.MoreAlphaTests/fifth()',
            'ASTRATests.topLevelTest()',
            'GammaTests.OtherSuite/sixth()',
        ]
        runs = {
            test_id: [number for number in range(1, 4)
                      if selected(ci_test_shards.arguments(shards, number), test_id)]
            for test_id in test_ids
        }
        self.assertEqual(runs['ASTRATests.AlphaTests/first()'], [1])
        self.assertEqual(runs['ASTRATests.BetaTests/Nested/second()'], [1])
        self.assertEqual(runs['ASTRATests.GammaTests/third(value:)'], [2])
        self.assertEqual(runs['ASTRATests.NewSuiteNobodyListed/fourth()'], [3])
        self.assertEqual(runs['ASTRATests.topLevelTest()'], [3])
        # A name matches as a search, so it also takes suites and modules that contain it.
        self.assertEqual(runs['ASTRATests.MoreAlphaTests/fifth()'], [1])
        self.assertEqual(runs['GammaTests.OtherSuite/sixth()'], [2])
        self.assertTrue(all(len(shard_numbers) == 1 for shard_numbers in runs.values()))

    def test_a_test_two_listed_shards_would_both_run_is_reported(self):
        test_ids = [
            'ArchitectureFitnessTests.ValidationTests/pinsTheWorkflow()',
            'ArchitectureFitnessTests.OtherFitnessTests/second()',
            'ASTRATests.OuterTests/InnerTests/nested()',
            'ASTRATests.OuterTests/plain()',
            'ASTRATests.UnlistedTests/third()',
        ]
        # A module name in one shard and one of its suites in another.
        counts, shared = ci_test_shards.tests_per_shard(
            [['ValidationTests'], ['ArchitectureFitnessTests']], test_ids)
        self.assertEqual(shared, [('ArchitectureFitnessTests.ValidationTests/pinsTheWorkflow()', [1, 2])])
        self.assertEqual(counts, [1, 2, 3])
        # A suite in one shard and a suite nested in it in another.
        counts, shared = ci_test_shards.tests_per_shard([['OuterTests'], ['InnerTests']], test_ids)
        self.assertEqual(shared, [('ASTRATests.OuterTests/InnerTests/nested()', [1, 2])])
        self.assertEqual(counts, [2, 1, 3])
        # The same names in one shard run every test once.
        for shards in ([['ValidationTests', 'ArchitectureFitnessTests'], ['OuterTests', 'InnerTests']],
                       [['OuterTests'], ['ValidationTests']]):
            counts, shared = ci_test_shards.tests_per_shard(shards, test_ids)
            self.assertEqual(shared, [])
            self.assertEqual(sum(counts), len(test_ids))

    def test_check_command_refuses_a_shared_test_and_an_empty_list(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        listing = Path(folder.name) / 'tests.txt'
        shards = ci_test_shards.load_plan()

        def run_check(test_ids):
            listing.write_text(''.join(test_id + '\n' for test_id in test_ids))
            return subprocess.run(
                [sys.executable, str(SCRIPT), 'check', str(listing)],
                check=False, capture_output=True, text=True,
            )

        once = [f'ASTRATests.{name}/first()' for shard in shards for name in shard]
        once.append('ASTRATests.SuiteNobodyListed/second()')
        passed = run_check(once)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        listed = ', '.join(str(len(shard)) for shard in shards)
        self.assertEqual(passed.stdout, f'{len(once)} tests, each in exactly one shard: {listed}, 1\n')

        if len(shards) > 1:
            twice = f'{shards[1][0]}.{shards[0][0]}/third()'
            refused = run_check(once + [twice])
            self.assertEqual(refused.returncode, 1)
            self.assertIn(f'shards 1 and 2 would both run {twice}', refused.stderr)
        self.assertEqual(run_check([]).returncode, 1)
        self.assertEqual(subprocess.run(
            [sys.executable, str(SCRIPT), 'check', str(listing.with_name('missing.txt'))],
            check=False, capture_output=True, text=True,
        ).returncode, 1)

    def test_shard_numbers_outside_the_plan_are_refused(self):
        shards = [['AlphaTests'], ['BetaTests']]
        for number in (0, 4):
            with self.assertRaises(ci_test_shards.PlanError):
                ci_test_shards.arguments(shards, number)

    def test_plans_that_could_break_the_command_line_or_run_a_suite_twice_are_refused(self):
        refused = [
            'not json',
            {'version': 2, 'shards': [['AlphaTests']]},
            {'version': 1, 'shards': []},
            {'version': 1, 'shards': [['AlphaTests'], []]},
            {'version': 1, 'shards': [['Alpha Tests']]},
            {'version': 1, 'shards': [['AlphaTests|BetaTests']]},
            {'version': 1, 'shards': [['.*']]},
            {'version': 1, 'shards': [['AlphaTests\n']]},
            {'version': 1, 'shards': [['AlphaTests'], ['AlphaTests']]},
            {'version': 1, 'shards': [['WorktreeTests'], ['DraftWorktreeTests']]},
            {'version': 1, 'shards': ['AlphaTests']},
        ]
        for plan in refused:
            with self.subTest(plan=plan), self.assertRaises((ci_test_shards.PlanError, ValueError)):
                ci_test_shards.load_plan(self.write_plan(plan))

    def test_proposed_plan_balances_measured_suites_and_leaves_unknown_ones_to_the_last_shard(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / 'Tests' / 'Nested').mkdir(parents=True)
        (root / 'Package.swift').write_text(
            'let package = Package(targets: [\n'
            '    .testTarget(\n        name: "FixtureTargetTests",\n        path: "Tests"\n    )\n])\n'
        )
        (root / 'Tests' / 'Heavy.swift').write_text(
            '@Suite("Heavy suite", .serialized)\n@MainActor\nstruct HeavyTests {\n'
            '    @Suite("Inner suite")\n    struct InnerTests {}\n}\n'
            '@Suite("Twin suite")\nstruct TwinOneTests {}\n'
            '@Suite("Target suite")\nstruct TargetTests {}\n'
        )
        (root / 'Tests' / 'Nested' / 'Medium.swift').write_text(
            '@Suite("Medium suite")\nfinal class MediumTests {}\n'
            '@Suite("Twin suite")\nstruct TwinTwoTests {}\n'
            '@Suite("Small suite")\nstruct SmallTests {}\n'
        )
        log = root / 'job.log'
        stamp = '2026-01-01T00:00:00.0000000Z '
        log.write_text(''.join(stamp + line + '\n' for line in [
            '◇ Suite "Heavy suite" started.',
            '◇ Suite "Inner suite" started.',
            '✔ Suite "Inner suite" passed after 5.000 seconds.',
            '✔ Suite "Heavy suite" passed after 40.000 seconds.',
            '◇ Suite "Medium suite" started.',
            '✔ Suite "Medium suite" passed after 30.000 seconds.',
            '◇ Suite "Twin suite" started.',
            '✘ Suite "Twin suite" failed after 20.000 seconds with 1 issue.',
            '◇ Suite "Undeclared suite" started.',
            '✔ Suite "Undeclared suite" passed after 20.000 seconds.',
            '◇ Suite "Small suite" started.',
            '✔ Suite "Small suite" passed after 10.000 seconds.',
            '◇ Suite "Target suite" started.',
            '✔ Suite "Target suite" passed after 35.000 seconds.',
            '✔ Test run with 9 tests in 7 suites passed after 155.000 seconds.',
            # The strict one-worker step of the same job runs a suite again.
            '◇ Suite "Heavy suite" started.',
            '✔ Suite "Heavy suite" passed after 7.000 seconds.',
            '✔ Test run with 1 test in 1 suite passed after 7.000 seconds.',
        ]))
        # Only the first test run of the log counts.
        self.assertEqual(ci_test_shards.suite_seconds(str(log)), {
            'Heavy suite': 40.0, 'Medium suite': 30.0, 'Twin suite': 20.0,
            'Undeclared suite': 20.0, 'Small suite': 10.0, 'Target suite': 35.0,
        })
        listed, loads = ci_test_shards.propose([str(log)], shards=3, root=str(root))
        # The ambiguous and the undeclared suite cannot be named, and TargetTests is part of
        # a test target's name, so a filter on it would select that whole target: all three
        # stay in the last shard.
        self.assertEqual(listed, [['HeavyTests'], ['MediumTests', 'SmallTests']])
        self.assertEqual(loads, [40.0, 40.0, 75.0])

    def test_proposed_plan_always_passes_the_plan_validator(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / 'Tests').mkdir()
        (root / 'Package.swift').write_text('let package = Package(targets: [])\n')
        (root / 'Tests' / 'Suites.swift').write_text(
            '@Suite("A suite")\nstruct ATests {}\n'
            '@Suite("B suite")\nstruct BTests {}\n'
            '@Suite("C suite")\nstruct CTests {}\n'
        )

        def log_of(seconds):
            log = root / f'job-{len(seconds)}.log'
            log.write_text(''.join(
                f'◇ Suite "{name} suite" started.\n✔ Suite "{name} suite" passed after {value}.000 seconds.\n'
                for name, value in seconds.items()))
            return str(log)

        # The second suite alone already passes the listed share, and still fills its shard.
        listed, loads = ci_test_shards.propose(
            [log_of({'A': 60, 'B': 50, 'C': 40})], shards=3, root=str(root))
        self.assertEqual(listed, [['ATests'], ['BTests']])
        self.assertEqual(loads, [60.0, 50.0, 40.0])
        self.assertEqual(
            ci_test_shards.load_plan(self.write_plan({'version': 1, 'shards': listed})), listed)
        # One measured suite cannot fill two listed shards, so nothing is proposed.
        with self.assertRaises(ci_test_shards.PlanError):
            ci_test_shards.propose([log_of({'A': 60})], shards=3, root=str(root))

    def test_command_line_prints_one_line_of_arguments_and_fails_loudly(self):
        def run(*arguments):
            return subprocess.run(
                [sys.executable, str(SCRIPT), *arguments],
                check=False, capture_output=True, text=True,
            )

        count = int(run('count').stdout)
        self.assertEqual(count, ci_test_shards.shard_count(ci_test_shards.load_plan()))
        for number in range(1, count + 1):
            result = run('arguments', str(number))
            self.assertEqual(result.returncode, 0)
            self.assertRegex(result.stdout, r'\A--(filter|skip) [A-Za-z0-9_|]+\n\Z')
        self.assertEqual(run('arguments', str(count + 1)).returncode, 1)
        self.assertEqual(run('arguments', '0').returncode, 1)
        self.assertEqual(run('arguments', 'one').returncode, 2)
        self.assertEqual(run().returncode, 2)

    def test_workflow_runs_one_job_per_shard_of_the_plan(self):
        workflow = (ROOT / '.github' / 'workflows' / 'ci.yml').read_text()
        count = ci_test_shards.shard_count(ci_test_shards.load_plan())
        numbers = ', '.join(str(number) for number in range(1, count + 1))
        self.assertIn(f'        shard: [{numbers}]\n', workflow)
        self.assertIn(f'(shard ${{{{ matrix.shard }}}} of {count})', workflow)
        self.assertEqual(workflow.count('script/ci_test_shards.py arguments "$SHARD"'), 1)
        # The build job checks the plan against the tests it just built.
        self.assertIn(
            '          swift test list --skip-build > "$RUNNER_TEMP/test-identifiers.txt"\n'
            '          python3 script/ci_test_shards.py check "$RUNNER_TEMP/test-identifiers.txt"\n',
            workflow.split('  swift-test-shards:\n')[0])


if __name__ == '__main__':
    unittest.main()
