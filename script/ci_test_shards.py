#!/usr/bin/env python3
"""Split CI's serial full-suite run into parallel jobs without dropping a test.

`ci_test_shards.json` names the heaviest suites for every shard but the last.
Each of those shards runs `swift test --filter` with its own names. The last
shard runs `--skip` with every name the other shards filter on, so it skips a
test exactly when another shard runs it. A suite nobody listed (a new one, a
renamed one) therefore still runs, in the last shard, and no edit of the plan
can drop a test: the plan only moves suites between shards.

A name is a suite's Swift type name, the same thing `swift test --filter`
matches, and it matches as a regular-expression search over the whole test
identifier (`Module.Suite/Nested/function()`). A name therefore also selects a
module of that name and every suite nested in a suite of that name, so two
listed shards can both select one test. Only the built test list can tell:
`check` reads it and refuses a plan that would run a test in two shards.

Usage:
  ci_test_shards.py arguments <shard>   swift test arguments for one shard (1-based)
  ci_test_shards.py count               how many shards the plan has
  ci_test_shards.py check <list>        fail if two shards would run the same test
  ci_test_shards.py plan <log>...       propose a balanced plan from test job logs

`check` reads the output of `swift test list`, one test identifier per line.

`plan` needs the logs of every test job of each run it reads: one log when a
single job ran the whole suite, all the shards' logs otherwise. A suite it
finds in no log counts as zero seconds. It reads only the first test run of a
log, because the strict one-worker step that follows in shard 1 runs suites a
second time. It never proposes a name that is part of a test target's name,
which would select that whole target. Its estimate knows suite type names
only: `check` and the measured shard times judge a plan.
"""
import json
import os
import re
import sys

PLAN_VERSION = 1
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAN_PATH = os.path.join(ROOT, 'script', 'ci_test_shards.json')
TEST_SOURCE_ROOTS = ('Tests', 'ASTRAGitContracts/Tests')

TEST_TARGET = re.compile(r'\.testTarget\(\s*name:\s*"([^"]+)"')
RUN_ENDED = re.compile(r'[✔✘] Test run with [0-9]+ tests? in [0-9]+ suites? (?:passed|failed) after')
SUITE_STARTED = re.compile(r'◇ Suite (.+) started\.$')
SUITE_ENDED = re.compile(r'[✔✘] Suite (.+) (?:passed|failed) after ([0-9.]+) seconds')
SUITE_ATTRIBUTE = re.compile(r'@Suite\(\s*"((?:[^"\\]|\\.)*)"')
TYPE_DECLARATION = re.compile(
    r'\s*(?:(?:public|internal|private|fileprivate|final|nonisolated|@\w+)\s+)*'
    r'(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)')


class PlanError(ValueError):
    pass


def load_plan(path=PLAN_PATH):
    """Return the listed shards: one list of suite names for every shard but the last."""
    with open(path, encoding='utf-8') as handle:
        plan = json.load(handle)
    if not isinstance(plan, dict) or plan.get('version') != PLAN_VERSION:
        raise PlanError(f'{path}: expected a plan with "version": {PLAN_VERSION}')
    return validated(plan.get('shards'), path)


def validated(shards, path):
    """The listed shards of a plan, or a PlanError saying what `swift test` could not run."""
    if not isinstance(shards, list) or not shards:
        raise PlanError(f'{path}: "shards" must list at least one shard')
    names = []
    for shard in shards:
        if not isinstance(shard, list) or not shard:
            raise PlanError(f'{path}: every listed shard needs at least one suite name')
        for name in shard:
            if not isinstance(name, str) or not NAME.match(name):
                raise PlanError(f'{path}: {name!r} is not a Swift type name')
            names.append(name)
    for index, name in enumerate(names):
        for other in names[index + 1:]:
            # A name matches as a search, so one inside another would run
            # the longer suite in two shards.
            if name in other or other in name:
                raise PlanError(f'{path}: {name!r} and {other!r} overlap')
    return shards


def shard_count(shards):
    return len(shards) + 1


def arguments(shards, shard):
    """swift test arguments for a 1-based shard number."""
    if not 1 <= shard <= shard_count(shards):
        raise PlanError(f'shard {shard} is outside 1...{shard_count(shards)}')
    if shard <= len(shards):
        return ['--filter', '|'.join(shards[shard - 1])]
    return ['--skip', '|'.join(name for listed in shards for name in listed)]


def tests_per_shard(shards, test_ids):
    """How many tests each shard runs, and the tests two or more listed shards both run."""
    patterns = [re.compile('|'.join(shard)) for shard in shards]
    counts = [0] * shard_count(shards)
    shared = []
    for test_id in test_ids:
        numbers = [number for number, pattern in enumerate(patterns, start=1)
                   if pattern.search(test_id)]
        for number in numbers or [shard_count(shards)]:
            counts[number - 1] += 1
        if len(numbers) > 1:
            shared.append((test_id, numbers))
    return counts, shared


def check(list_path, shards):
    """Print how the listed tests split; raise if two shards would run the same test."""
    with open(list_path, encoding='utf-8', errors='replace') as handle:
        test_ids = [line.strip() for line in handle if line.strip()]
    if not test_ids:
        raise PlanError(f'{list_path}: no test identifiers to check')
    counts, shared = tests_per_shard(shards, test_ids)
    for test_id, numbers in shared[:20]:
        print(f'ci_test_shards: shards {" and ".join(map(str, numbers))} would both run {test_id}',
              file=sys.stderr)
    if shared:
        raise PlanError(
            f'{len(shared)} of {len(test_ids)} tests would run in more than one shard: '
            'a name also matches a module or an enclosing suite of that name')
    print(f'{len(test_ids)} tests, each in exactly one shard: ' + ', '.join(map(str, counts)))


def suite_seconds(log_path):
    """Seconds per top-level suite, by display name, from the first test run in a job log."""
    open_suites = []
    seconds = {}
    with open(log_path, encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if RUN_ENDED.search(line):
                break  # A later run in the same job repeats suites that already ran.
            started = SUITE_STARTED.search(line)
            if started:
                open_suites.append(started.group(1))
                continue
            ended = SUITE_ENDED.search(line)
            if not ended or ended.group(1) not in open_suites:
                continue
            while open_suites.pop() != ended.group(1):
                pass
            if not open_suites:
                name = ended.group(1).strip('"')
                seconds[name] = seconds.get(name, 0.0) + float(ended.group(2))
    return seconds


def suite_type_names(root=ROOT):
    """Display name -> type names of the top-level suites declared with that name."""
    types = {}
    for source_root in TEST_SOURCE_ROOTS:
        for folder, _, files in os.walk(os.path.join(root, source_root)):
            for file_name in sorted(files):
                if not file_name.endswith('.swift'):
                    continue
                with open(os.path.join(folder, file_name), encoding='utf-8', errors='replace') as handle:
                    lines = handle.read().split('\n')
                pending = None
                for number, line in enumerate(lines):
                    attribute = SUITE_ATTRIBUTE.search(line)
                    if attribute:
                        pending = (attribute.group(1), number)
                    declaration = TYPE_DECLARATION.match(line)
                    if declaration and pending and number - pending[1] <= 6:
                        if not line[:1].isspace():
                            types.setdefault(pending[0], set()).add(declaration.group(1))
                        pending = None
    return types


def test_target_names(root=ROOT):
    """Names of the package's test targets, each the first part of its tests' identifiers."""
    with open(os.path.join(root, 'Package.swift'), encoding='utf-8') as handle:
        return set(TEST_TARGET.findall(handle.read()))


def propose(log_paths, shards=3, root=ROOT):
    """Heaviest suites first into the lighter listed shard, until the rest is one share.

    A name weighs what its filter selects among the measured suites: its own
    suite and every suite whose type name contains it. Suites go in by their
    own time, so the name of a heavy suite is preferred to a shorter name that
    happens to select it.
    """
    totals = {}
    for log_path in log_paths:
        for name, value in suite_seconds(log_path).items():
            totals.setdefault(name, []).append(value)
    mean = {name: sum(values) / len(values) for name, values in totals.items()}
    total = sum(mean.values())
    targets = test_target_names(root)
    # A suite can be named when exactly one top-level type declares its display
    # name. Any other suite stays in the last shard.
    type_of = {name: next(iter(found)) for name, found in suite_type_names(root).items()
               if len(found) == 1 and name in mean}
    selects = {type_name: {name for name, other in type_of.items() if type_name in other}
               for type_name in type_of.values()}
    weight = {type_name: sum(mean[name] for name in names) for type_name, names in selects.items()}
    own = {type_name: sum(mean[name] for name, other in type_of.items() if other == type_name)
           for type_name in selects}
    listed = [[] for _ in range(shards - 1)]
    loads = [0.0] * (shards - 1)
    taken = set()
    for type_name in sorted(own, key=lambda item: (-own[item], item)):
        if any(type_name in target for target in targets):
            continue  # It would select every test of that target, not one suite.
        if selects[type_name] & taken:
            continue  # A listed name already runs a suite this one would select.
        # Only a name that could be listed ends the list, and every listed
        # shard gets one before the listed share can end it.
        if sum(loads) + weight[type_name] > total * (shards - 1) / shards and all(listed):
            break
        lighter = loads.index(min(loads))
        listed[lighter].append(type_name)
        loads[lighter] += weight[type_name]
        taken |= selects[type_name]
    return validated(listed, 'proposed plan'), loads + [total - sum(loads)]


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == 'arguments' and argv[2].isdigit():
            print(' '.join(arguments(load_plan(), int(argv[2]))))
            return 0
        if len(argv) == 2 and argv[1] == 'count':
            print(shard_count(load_plan()))
            return 0
        if len(argv) == 3 and argv[1] == 'check':
            check(argv[2], load_plan())
            return 0
        if len(argv) >= 3 and argv[1] == 'plan':
            listed, loads = propose(argv[2:], shard_count(load_plan()))
            print(json.dumps({'version': PLAN_VERSION, 'shards': listed}, indent=2))
            print('Estimated seconds per shard: ' + ', '.join(f'{load:.0f}' for load in loads),
                  file=sys.stderr)
            return 0
    except (PlanError, OSError, ValueError) as error:
        print(f'ci_test_shards: {error}', file=sys.stderr)
        return 1
    print(__doc__.strip().split('Usage:\n', 1)[1], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
