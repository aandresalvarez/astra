#!/usr/bin/env python3
"""Split CI's serial full-suite run into parallel jobs without dropping a test.

`ci_test_shards.json` names the heaviest suites for every shard but the last.
Each of those shards runs `swift test --filter` with its own names. The last
shard runs `--skip` with every name the other shards filter on, so it skips a
test exactly when another shard runs it. A suite nobody listed (a new one, a
renamed one) therefore still runs, in the last shard, and no edit of the plan
can drop a test: the plan only moves suites between shards.

A name is a suite's Swift type name, the same thing `swift test --filter`
matches, and it matches as a regular-expression search.

Usage:
  ci_test_shards.py arguments <shard>   swift test arguments for one shard (1-based)
  ci_test_shards.py count               how many shards the plan has
  ci_test_shards.py plan <log>...       propose a balanced plan from test job logs

`plan` needs the logs of every test job of each run it reads: one log when a
single job ran the whole suite, all the shards' logs otherwise. A suite it
finds in no log counts as zero seconds.
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
    shards = plan.get('shards')
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


def suite_seconds(log_path):
    """Seconds per top-level suite, by display name, from the log of a serial test job."""
    open_suites = []
    seconds = {}
    with open(log_path, encoding='utf-8', errors='replace') as handle:
        for line in handle:
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


def propose(log_paths, shards=3, root=ROOT):
    """Heaviest suites first into the lighter listed shard, until the rest is one share."""
    totals = {}
    for log_path in log_paths:
        for name, value in suite_seconds(log_path).items():
            totals.setdefault(name, []).append(value)
    mean = {name: sum(values) / len(values) for name, values in totals.items()}
    total = sum(mean.values())
    types = suite_type_names(root)
    listed = [[] for _ in range(shards - 1)]
    loads = [0.0] * (shards - 1)
    chosen = []
    for name, value in sorted(mean.items(), key=lambda item: (-item[1], item[0])):
        if sum(loads) + value > total * (shards - 1) / shards:
            break
        candidates = types.get(name, set())
        if len(candidates) != 1:
            continue  # Not found or ambiguous: it stays in the last shard.
        type_name = next(iter(candidates))
        if any(type_name in other or other in type_name for other in chosen):
            continue
        lighter = loads.index(min(loads))
        listed[lighter].append(type_name)
        loads[lighter] += value
        chosen.append(type_name)
    return listed, loads + [total - sum(loads)]


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == 'arguments' and argv[2].isdigit():
            print(' '.join(arguments(load_plan(), int(argv[2]))))
            return 0
        if len(argv) == 2 and argv[1] == 'count':
            print(shard_count(load_plan()))
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
