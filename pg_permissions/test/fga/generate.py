#!/usr/bin/env python3
"""Generate TAP spec files from OpenFGA's consolidated test suite, and report results.

    python3 -I test/fga/generate.py                 # write test/spec/d/6x_fga_oracle_*.sql, print counts
    test/run.sh --impl prototypes/d-per-model.sql -v fga_oracle > /tmp/fga.out
    python3 -I test/fga/generate.py report /tmp/fga.out   # counts: run, passed, failed, skipped by reason

Input: test/fga/cases.json (written by vendor.sh: one upstream test case per
line, every stage with its model converted to JSON) and test/fga/skip.tsv.

Two runs, like OpenFGA's own harness (tests/check, tests/listobjects,
tests/listusers):
  stored      every stage writes its model, then its tuples, then runs its
              assertions; stages of a case share one store.
  contextual  single-stage cases only, with at most 100 tuples: the model is
              written, no tuple is, and every assertion gets the stage's tuples
              appended to its own contextual tuples.
Upstream also checks every object or user a list call returns with Check; the
helpers in test/fixtures/fga_suite.sql do the same inside the one assertion.

Each assertion is one TAP test named <mode>:<case>:s<stage>:<kind><index>,
kind being check, lo (ListObjects) or lu (ListUsers). Skipped cases (skip.tsv)
are not emitted; the file lists them as comments. Expectations are never edited.
"""
import json
import os
import re
import sys
from collections import Counter, OrderedDict, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # pg_permissions/
SPEC_DIR = os.path.join(ROOT, 'test', 'spec', 'd')
CASES_PER_FILE = 12
MODES = ('stored', 'contextual')
FILE_PREFIX = {'stored': '60_fga_oracle', 'contextual': '61_fga_oracle_ctx'}


def load_cases():
    """Upstream repeats one case name; the second one is tested as <name>~2."""
    with open(os.path.join(HERE, 'cases.json')) as f:
        cases = [json.loads(line) for line in f if line.strip()]
    seen = Counter()
    for c in cases:
        seen[c['name']] += 1
        c['id'] = c['name'] if seen[c['name']] == 1 else f"{c['name']}~{seen[c['name']]}"
    return cases


def load_skips():
    """case -> {mode: (reason, note)}; mode 'both' expands to both modes."""
    skips = defaultdict(dict)
    with open(os.path.join(HERE, 'skip.tsv')) as f:
        for line in f:
            if not line.strip() or line.startswith('#'):
                continue
            case, mode, reason, note = (line.rstrip('\n').split('\t') + ['', ''])[:4]
            for m in (MODES if mode == 'both' else (mode,)):
                if m not in MODES:
                    sys.exit(f'skip.tsv: bad mode {mode!r} for {case}')
                skips[case][m] = (reason, note)
    return skips


def lit(v):
    if v is None:
        return 'null'
    return "'" + str(v).replace("'", "''") + "'"


def jlit(v):
    return 'null' if not v else lit(json.dumps(v, separators=(',', ':'))) + '::jsonb'


def alit(v):
    if v is None:
        return 'null::text[]'
    return 'array[' + ', '.join(lit(x) for x in v) + ']::text[]'


def contextual_eligible(case):
    return len(case['stages']) == 1 and len(case['stages'][0].get('tuples') or []) <= 100


def assertions(case, mode):
    """Yield (stage_index, kind, index, sql_expression) for one case."""
    for s, stage in enumerate(case['stages']):
        tuples = stage.get('tuples') or []
        extra = tuples if mode == 'contextual' else []
        for i, a in enumerate(stage.get('checkAssertions') or []):
            t = a['tuple']
            ctx = (a.get('contextualTuples') or []) + extra
            yield s, 'check', i, 'fga_test.check(%s, %s, %s, %s, %s, %s, :\'model_id\')' % (
                lit(t['user']), lit(t['relation']), lit(t['object']), jlit(ctx),
                'null' if a.get('errorCode') else ('true' if a.get('expectation') else 'false'),
                a.get('errorCode') or 'null')
        for i, a in enumerate(stage.get('listObjectsAssertions') or []):
            r = a['request']
            ctx = (a.get('contextualTuples') or []) + extra
            yield s, 'lo', i, 'fga_test.list_objects(%s, %s, %s, %s, %s, %s, :\'model_id\')' % (
                lit(r['user']), lit(r['type']), lit(r['relation']), jlit(ctx),
                'null' if a.get('errorCode') else alit(a.get('expectation') or []),
                a.get('errorCode') or 'null')
        for i, a in enumerate(stage.get('listUsersAssertions') or []):
            r = a['request']
            ctx = (a.get('contextualTuples') or []) + extra
            yield s, 'lu', i, 'fga_test.list_users(%s, %s, %s, %s, %s, %s, :\'model_id\')' % (
                lit(r['object']), lit(r['relation']), alit(r.get('filters') or []), jlit(ctx),
                'null' if a.get('errorCode') else alit(a.get('expectation') or []),
                a.get('errorCode') or 'null')


def case_sql(case, mode):
    out = []
    n = 0
    asserts = list(assertions(case, mode))
    by_stage = defaultdict(list)
    for s, kind, i, expr in asserts:
        by_stage[s].append((kind, i, expr))
    out.append(f"\n-- {case['id']}")
    out.append('select permissions.fga_delete_store();')
    for s, stage in enumerate(case['stages']):
        out.append(f"-- stage {s}")
        out.append("select permissions.fga_write_authorization_model(%s) as model_id \\gset" % jlit(stage['model_json']))
        tuples = stage.get('tuples') or []
        if tuples and mode == 'stored':
            out.append('select permissions.fga_write(%s);' % jlit(tuples))
        for kind, i, expr in by_stage.get(s, []):
            name = f"{mode}:{case['id']}:s{s}:{kind}{i}"
            out.append(f"select tap.is({expr}, 'ok', {lit(name)});")
            n += 1
    return out, n


def generate():
    cases = load_cases()
    skips = load_skips()
    names = [c['name'] for c in cases]
    unknown = set(skips) - set(names)
    if unknown:
        sys.exit(f'skip.tsv names unknown cases: {sorted(unknown)}')

    for f in os.listdir(SPEC_DIR):
        if re.match(r'6[01]_fga_oracle.*\.sql$', f):
            os.remove(os.path.join(SPEC_DIR, f))

    counts = {}
    for mode in MODES:
        eligible = [c for c in cases if mode == 'stored' or contextual_eligible(c)]
        stats = Counter()
        by_reason = Counter()
        by_reason_assertions = Counter()
        chunks = [eligible[i:i + CASES_PER_FILE] for i in range(0, len(eligible), CASES_PER_FILE)]
        for k, chunk in enumerate(chunks, 1):
            body, skipped_lines, total = [], [], 0
            for case in chunk:
                na = len(list(assertions(case, mode)))
                if mode in skips.get(case['name'], {}):
                    reason, note = skips[case['name']][mode]
                    by_reason[reason] += 1
                    by_reason_assertions[reason] += na
                    skipped_lines.append(f"\\echo '# SKIP {case['id']}: {reason}'")
                    continue
                lines, n = case_sql(case, mode)
                body += lines
                total += n
                stats['cases_run'] += 1
                stats['assertions_run'] += n
            path = os.path.join(SPEC_DIR, f'{FILE_PREFIX[mode]}_{k:02d}.sql')
            with open(path, 'w') as f:
                f.write(f"-- Generated by test/fga/generate.py from test/fga/cases.json ({mode} run). Do not edit.\n")
                f.write("-- OpenFGA consolidated_1_1_tests.yaml, Apache-2.0: see test/fga/upstream/SOURCE.\n")
                f.write("\\set ON_ERROR_STOP off\n\\ir ../../fixtures/fga_suite.sql\n")
                f.write('\n'.join(skipped_lines) + ('\n' if skipped_lines else ''))
                f.write(f"select tap.plan({max(total, 1)});\n")
                if total == 0:
                    f.write("select tap.pass('every case in this file is skipped');\n")
                f.write('\n'.join(body) + '\n')
                f.write("\nselect * from tap.finish();\n")
        counts[mode] = (len(eligible), sum(len(list(assertions(c, mode))) for c in eligible),
                        stats, by_reason, by_reason_assertions)

    total_assertions = sum(len(list(assertions(c, 'stored'))) for c in cases)
    print(f'upstream: {len(cases)} cases, {total_assertions} assertions '
          f'({sum(len(c["stages"]) > 1 for c in cases)} multi-stage)')
    for mode, (ncases, nassert, stats, by_reason, by_reason_a) in counts.items():
        print(f'{mode}: {ncases} cases / {nassert} assertions eligible; '
              f'run {stats["cases_run"]} cases / {stats["assertions_run"]} assertions; '
              f'skipped {sum(by_reason.values())} cases / {sum(by_reason_a.values())} assertions')
        for r in sorted(by_reason):
            print(f'    skipped {r}: {by_reason[r]} cases, {by_reason_a[r]} assertions')
    if 'contextual' in counts:
        print(f'contextual: not eligible (multi-stage or >100 tuples): '
              f'{len(cases) - counts["contextual"][0]} cases')


def report(path):
    """Tally a `test/run.sh -v fga_oracle` log: per mode, assertions and cases."""
    cases = load_cases()
    skips = load_skips()
    res = {m: OrderedDict() for m in MODES}
    pat = re.compile(r'^\s*(ok|not ok) \d+ - (stored|contextual):([^:]+):s(\d+):(check|lo|lu)(\d+)')
    with open(path) as f:
        for line in f:
            line = re.sub(r'\x1b\[[0-9;]*m', '', line)
            m = pat.match(line)
            if m:
                res[m.group(2)].setdefault(m.group(3), []).append(m.group(1) == 'ok')
    for mode in MODES:
        eligible = [c for c in cases if mode == 'stored' or contextual_eligible(c)]
        expected = {c['id']: len(list(assertions(c, mode))) for c in eligible
                    if mode not in skips.get(c['name'], {})}
        got = res[mode]
        a_pass = sum(sum(v) for v in got.values())
        a_fail = sum(len(v) - sum(v) for v in got.values())
        a_missing = sum(max(expected[n] - len(got.get(n, [])), 0) for n in expected)
        c_pass = sum(1 for n in expected if len(got.get(n, [])) == expected[n] and all(got[n]))
        failed_cases = [n for n in expected if not (len(got.get(n, [])) == expected[n] and all(got.get(n, [])))]
        by_reason = Counter(skips[c['name']][mode][0] for c in eligible if mode in skips.get(c['name'], {}))
        by_reason_a = Counter()
        for c in eligible:
            if mode in skips.get(c['name'], {}):
                by_reason_a[skips[c['name']][mode][0]] += len(list(assertions(c, mode)))
        print(f'{mode}: assertions run {a_pass + a_fail + a_missing}, passed {a_pass}, failed {a_fail}, '
              f'not run {a_missing}; cases run {len(expected)}, passed {c_pass}, failed {len(failed_cases)}; '
              f'skipped {sum(by_reason.values())} cases / {sum(by_reason_a.values())} assertions '
              + ', '.join(f'{r}: {by_reason[r]}/{by_reason_a[r]}' for r in sorted(by_reason)))
        for n in failed_cases:
            print(f'    failed: {n}')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'report':
        report(sys.argv[2])
    else:
        generate()
