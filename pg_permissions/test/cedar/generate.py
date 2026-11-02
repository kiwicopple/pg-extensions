#!/usr/bin/env python3
"""Generate TAP spec files from the Cedar integration tests, print corpus stats, tally results.

    python3 -I test/cedar/generate.py --stats                       # counts by format, feature, ...; writes nothing
    python3 -I test/cedar/generate.py --dry-run [SELECT]            # the files a run would write; writes nothing
    python3 -I test/cedar/generate.py [SELECT]                      # write test/cedar/spec/*.sql (not run by test/run.sh)
    python3 -I test/cedar/generate.py --suite [SELECT]              # write test/spec/d/7[0-7]_cedar_oracle*.sql
    python3 -I test/cedar/generate.py suite                         # the SUITE runs below; test/run.sh calls this
    test/run.sh -v cedar > /tmp/cedar.out
    python3 -I test/cedar/generate.py report /tmp/cedar.out [SELECT]  # run, passed, failed, skipped by reason

SELECT chooses the cases and how they reach the database:
    --phase P       a preset from PHASES below (2, 3, 4a, 4b, 4c, all); sets the next three
    --format F      json: put each policy as its EST (policy_json); text: as Cedar text (policy)
    --mode M        stored: put the entities once per case; overlay: pass them in every
                    request (`entities` argument), nothing stored (cases up to OVERLAY_MAX bytes)
    --features L    comma list of gated features a case may use (GATED); `all` for every one
    --templatize    json format only: put every policy whose principal or resource scope
                    names an entity as a template with a slot there, linked under the
                    original id (the corpus has no templates; phase 4c); runs only the
                    cases that get a link
    --check-est     text format only: also assert, per policy, that the EST stored from
                    the text equals the CLI's translation (the parser oracle, phase 3)
    --parse-est     text format only: no requests; assert, per text policy of every case
                    (any feature), that the parser gives the CLI's EST, and per case with
                    several policies, that the policy-set parse gives the CLI's ids
    --reduce-parents  stored mode only: keep only each entity's direct parents (the
                    transitive reduction; Cedar's JSON lists every ancestor), so `in` must
                    follow the hierarchy itself; runs only the cases that lose a link

`suite` writes the files that test/run.sh runs: the runs in SUITE, each with
--suite. The files are generated, not committed (test/spec/d/.gitignore). A
phase that adds features extends SUITE.

Input: test/cedar/cases/*.jsonl[.gz] (convert.py, via vendor.sh) and
test/cedar/skip.tsv. Each case: the stored state is reset, the policies are put
(templates and links too), the entities are put (stored mode), then one
assertion per request:

    select tap.is(cedar_test.authz(principal, action, resource, context, entities),
                  '{"decision":..,"reasons":[..],"errors":[..]}'::jsonb, '<mode>:<format>:<case>:r<i>');

cedar_test.authz (test/cedar/fixture.sql) calls permissions.cedar_is_authorized
and keeps the decision, the reasons as a sorted set, and the errors as the sorted
set of policy ids. Error messages are not compared: Cedar's harness compares
policy ids only (cedar-testing ErrorComparisonMode::PolicyIds), and our message
text differs. Expectations are never edited.

U+0000. Postgres text and jsonb cannot hold it, and half the corpus uses it in
ids and strings. The generator replaces it with U+E000 in every string of a
case (data, EST and the escapes in Cedar text). Cedar has no string length or
ordering, so equality, `like` and `has` give the same answers. A case that
already contains U+E000 would be skipped (none in this release).
"""
import glob
import gzip
import json
import os
import re
import sys
from collections import Counter, OrderedDict, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # pg_permissions/
OUT_DIR = os.path.join(HERE, 'spec')                   # default: outside test/run.sh's path
SUITE_DIR = os.path.join(ROOT, 'test', 'spec', 'd')
CASES_DIR = os.path.join(HERE, 'cases')
FILE_PREFIX = {('json', 'stored'): '70_cedar_oracle', ('text', 'stored'): '71_cedar_oracle_text',
               ('json', 'overlay'): '72_cedar_oracle_overlay', ('text', 'overlay'): '73_cedar_oracle_text_overlay',
               ('json', 'reduced'): '74_cedar_oracle_reduced', ('text', 'reduced'): '75_cedar_oracle_text_reduced',
               ('json', 'templates'): '76_cedar_oracle_templates', ('text', 'parse'): '77_cedar_oracle_parse'}
MAX_ASSERTIONS = 1000        # per file
MAX_BYTES = 1_500_000        # per file (a case is never split)
OVERLAY_MAX = 1024           # overlay mode: compact entity JSON bytes per case
NUL_SUB = '\ue000'

# Features a case may need that a phase may not have built yet.
GATED = ('decimal', 'ipaddr', 'datetime', 'duration', 'template')
PHASES = {
    '2':   dict(format='json', mode='stored', features=()),
    '3':   dict(format='text', mode='stored', features=(), check_est=True),
    '4a':  dict(format='json', mode='stored', features=('decimal', 'ipaddr')),
    '4b':  dict(format='json', mode='stored', features=('datetime', 'duration')),
    '4c':  dict(format='json', mode='stored', features=('template',), templatize=True),
    'all': dict(format='json', mode='stored', features=GATED),
}

# What `suite` (and so test/run.sh) generates into test/spec/d/: every case,
# with the extension types (phases 4a and 4b), with entities stored, in the
# request overlay, and stored with only direct parents (so `in` must follow the
# hierarchy); the same as Cedar text, with the stored EST checked; the parser
# on every text policy of the corpus; and template links (phase 4c).
EXTENSIONS = 'decimal,ipaddr,datetime,duration'
SUITE = (
    ['--phase', '2', '--features', EXTENSIONS],
    ['--phase', '2', '--features', EXTENSIONS, '--mode', 'overlay'],
    ['--phase', '2', '--features', EXTENSIONS, '--reduce-parents'],
    ['--phase', '3', '--features', EXTENSIONS],
    ['--format', 'text', '--parse-est'],
    ['--phase', '4c', '--features', 'all'],
)

EXT_FEATURE = {
    'decimal': 'decimal', 'lessThan': 'decimal', 'lessThanOrEqual': 'decimal',
    'greaterThan': 'decimal', 'greaterThanOrEqual': 'decimal',
    'ip': 'ipaddr', 'isIpv4': 'ipaddr', 'isIpv6': 'ipaddr', 'isLoopback': 'ipaddr',
    'isMulticast': 'ipaddr', 'isInRange': 'ipaddr',
    'datetime': 'datetime', 'offset': 'datetime', 'durationSince': 'datetime',
    'toDate': 'datetime', 'toTime': 'datetime',
    'duration': 'duration', 'toDays': 'duration', 'toHours': 'duration', 'toMinutes': 'duration',
    'toSeconds': 'duration', 'toMilliseconds': 'duration',
}
EXTN_FEATURE = {'decimal': 'decimal', 'ip': 'ipaddr', 'ipaddr': 'ipaddr',
                'datetime': 'datetime', 'duration': 'duration'}
UNARY = {'!', 'neg', 'isEmpty'}
BINARY = {'==', '!=', 'in', '<', '<=', '>', '>=', '&&', '||', '+', '-', '*',
          'contains', 'containsAll', 'containsAny', 'hasTag', 'getTag'}
OP_FEATURE = {'like': 'like', 'has': 'has', 'is': 'is', 'in': 'in', 'if-then-else': 'if',
              'hasTag': 'tags', 'getTag': 'tags', 'Set': 'set', 'Record': 'record',
              'contains': 'set', 'containsAll': 'set', 'containsAny': 'set', 'isEmpty': 'set',
              '+': 'arith', '-': 'arith', '*': 'arith', 'neg': 'arith',
              '&&': 'logic', '||': 'logic', '!': 'logic',
              '<': 'compare', '<=': 'compare', '>': 'compare', '>=': 'compare'}


# ---- loading ----------------------------------------------------------------

def load_cases():
    cases = []
    for path in sorted(glob.glob(os.path.join(CASES_DIR, '*.jsonl*'))):
        opener = gzip.open if path.endswith('.gz') else open
        with opener(path, 'rt', encoding='utf-8') as f:
            cases.extend(json.loads(l) for l in f if l.strip())
    cases.sort(key=lambda c: (not c['name'].startswith('tests/'), c['name']))
    for c in cases:
        c['features'], c['metrics'] = analyze(c)
    return cases


def load_skips():
    """name -> list of (scope, request index or None, reason, note).

    Columns: case[:rN]  scope (all|json|text|stored|overlay)  reason  note."""
    skips = defaultdict(list)
    path = os.path.join(HERE, 'skip.tsv')
    with open(path, encoding='utf-8') as f:
        for n, l in enumerate(f, 1):
            if not l.strip() or l.startswith('#'):
                continue
            case, scope, reason, note = (l.rstrip('\n').split('\t') + ['', '', ''])[:4]
            if scope not in ('all', 'json', 'text', 'stored', 'overlay') or not reason:
                sys.exit(f'skip.tsv:{n}: need case, scope (all|json|text|stored|overlay), reason')
            m = re.fullmatch(r'(.*):r(\d+)', case)
            name, req = (m.group(1), int(m.group(2))) if m else (case, None)
            skips[name].append((scope, req, reason, note))
    return skips


def skip_reason(skips, case, fmt, mode, req=None):
    for scope, r, reason, _ in skips.get(case['name'], ()):
        if scope in ('all', fmt, mode) and (r is None or r == req):
            return reason
    return None


# ---- analysis ---------------------------------------------------------------

def walk_value(v, feats, m):
    """A Cedar JSON value (entity attrs, tags, context, EST `Value`)."""
    if isinstance(v, dict):
        if '__extn' in v:
            feats.add(EXTN_FEATURE.get(v['__extn'].get('fn'), 'extn:' + str(v['__extn'].get('fn'))))
            return
        if '__entity' in v:
            return
        for x in v.values():
            walk_value(x, feats, m)
    elif isinstance(v, list):
        for x in v:
            walk_value(x, feats, m)
    elif isinstance(v, bool):
        pass
    elif isinstance(v, int):
        m['max_abs_long'] = max(m['max_abs_long'], abs(v))
    elif isinstance(v, str) and '\x00' in v:
        feats.add('nul')


def walk_expr(e, feats, m, depth=1):
    """One EST expression (Cedar JSON policy format); returns (depth, nodes)."""
    m['max_depth'] = max(m['max_depth'], depth)
    (op, a), = e.items()
    if op in OP_FEATURE:
        feats.add(OP_FEATURE[op])
    if op in EXT_FEATURE:
        feats.add(EXT_FEATURE[op])
    if op == 'Value':
        walk_value(a, feats, m)
        if isinstance(a, list):
            feats.add('set')
        elif isinstance(a, dict) and '__entity' not in a and '__extn' not in a:
            feats.add('record')
        return 1
    if op in ('Var', 'Unknown'):
        return 1
    if op == 'Slot':
        feats.add('template')
        return 1
    kids = []
    if op in UNARY:
        kids = [a['arg']]
    elif op in BINARY:
        kids = [a['left'], a['right']]
    elif op in ('.', 'has'):
        kids = [a['left']]
    elif op == 'is':
        kids = [a['left']] + ([a['in']] if 'in' in a else [])
    elif op == 'like':
        kids = [a['left']]
        for p in a['pattern']:
            if isinstance(p, dict) and '\x00' in p.get('Literal', ''):
                feats.add('nul')
    elif op == 'if-then-else':
        kids = [a['if'], a['then'], a['else']]
    elif op == 'Set':
        kids = a
    elif op == 'Record':
        kids = list(a.values())
        if any('\x00' in k for k in a):
            feats.add('nul')
    elif isinstance(a, list):                 # extension function or method call
        if op not in EXT_FEATURE:
            feats.add('extn:' + op)
        kids = a
    else:
        sys.exit(f'unknown EST node {op!r}')
    if op in ('.', 'has'):
        attrs = a['attr'] if isinstance(a['attr'], list) else [a['attr']]
        if any('\x00' in x for x in attrs):
            feats.add('nul')
    return 1 + sum(walk_expr(k, feats, m, depth + 1) for k in kids)


def walk_scope(s, feats):
    if s.get('slot'):
        feats.add('template')
    if s.get('op') == 'is':
        feats.add('is')
        if isinstance(s.get('in'), dict) and s['in'].get('slot'):
            feats.add('template')


def analyze(case):
    feats = set()
    m = Counter(max_depth=0, max_abs_long=0)
    for p in case['policies']:
        est = p['est']
        if p['kind'] == 'template':
            feats.add('template')
        if est.get('annotations'):
            feats.add('annotations')
        walk_scope(est['principal'], feats)
        walk_scope(est['resource'], feats)
        for c in est['conditions']:
            m['nodes'] = max(m['nodes'], walk_expr(c['body'], feats, m))
        if p['text'] is not None:
            m['policy_bytes'] = max(m['policy_bytes'], len(p['text'].encode('utf-8')))
        m['est_bytes'] = max(m['est_bytes'], len(json.dumps(est, separators=(',', ':')).encode('utf-8')))
    if case['templateLinks']:
        feats.add('template')
    for e in case['entities']:
        walk_value(e.get('attrs'), feats, m)
        if e.get('tags'):
            feats.add('tags')
            walk_value(e['tags'], feats, m)
        for u in [e['uid']] + list(e.get('parents') or []):
            u = u.get('__entity', u)
            if '\x00' in u['id']:
                feats.add('nul')
    for r in case['requests']:
        walk_value(r['context'], feats, m)
        for k in ('principal', 'action', 'resource'):
            if '\x00' in r[k]['id']:
                feats.add('nul')
        if r['errors']:
            feats.add('errors')
    # Any U+0000, also in record keys and attribute names (json.dumps escapes it).
    if any('\\u0000' in json.dumps(x) for x in (case['policies'], case['entities'], case['requests'])):
        feats.add('nul')
    m['policies'] = len(case['policies'])
    m['entities'] = len(case['entities'])
    m['entity_bytes'] = len(json.dumps(case['entities'], ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
    m['ancestor_depth'] = ancestor_depth(case['entities'])
    if case['schemaDependent']:
        feats.add('schema')
    return feats, m


def ancestor_depth(entities):
    """Longest chain of direct parents (entity JSON may already be closed)."""
    par = {}
    for e in entities:
        u = e['uid'].get('__entity', e['uid'])
        par[(u['type'], u['id'])] = [(p.get('__entity', p)['type'], p.get('__entity', p)['id']) for p in e.get('parents') or []]
    memo = {}

    def d(u, seen):
        if u in memo:
            return memo[u]
        if u in seen:
            return 0
        r = 1 + max((d(p, seen | {u}) for p in par.get(u, [])), default=0) if par.get(u) else 0
        memo[u] = r
        return r
    return max((d(u, frozenset()) for u in par), default=0)


def uid_key(u):
    u = u.get('__entity', u)
    return (u['type'], u['id'])


def reduce_parents(entities):
    """The entities with only their direct parents (the transitive reduction:
    a parent that is also an ancestor of another parent goes), and the number
    of parent links removed."""
    par = {uid_key(e['uid']): [uid_key(p) for p in e.get('parents') or []] for e in entities}
    memo = {}

    def anc(u, stack=frozenset()):
        if u in memo:
            return memo[u]
        r = set()
        for p in par.get(u, []):
            if p not in stack:
                r.add(p)
                r |= anc(p, stack | {u})
        memo[u] = r
        return r
    out, removed = [], 0
    for e in entities:
        ps = par[uid_key(e['uid'])]
        keep = [p for p in ps if not any(p in anc(q) for q in ps if q != p)]
        removed += len(ps) - len(keep)
        out.append(dict(e, parents=[{'type': t, 'id': i} for t, i in keep]))
    return out, removed


def label_mode(sel):
    if sel.get('parse_est'):
        return 'parse'
    if sel.get('templatize'):
        return 'templates'
    return 'reduced' if sel.get('reduce_parents') else sel['mode']


def eligible(case, sel):
    """None if the case runs under SELECT, else the reason it is left out (not a skip)."""
    gated = (case['features'] & set(GATED)) - set(sel['features'])
    if gated:
        return 'feature:' + ','.join(sorted(gated))
    if sel['format'] == 'text' and any(p['text'] is None for p in case['policies']):
        return 'no-text'        # a JSON-format upstream policy set
    if sel['mode'] == 'overlay' and case['metrics']['entity_bytes'] > OVERLAY_MAX:
        return 'overlay-size'
    if sel.get('reduce_parents') and not reduce_parents(case['entities'])[1]:
        return 'parents-already-direct'
    if sel.get('templatize') and len(templatize(case)['templateLinks']) == len(case['templateLinks']):
        return 'no-entity-in-scope'
    return None


# ---- SQL --------------------------------------------------------------------

def sub_nul(v):
    if isinstance(v, str):
        return v.replace('\x00', NUL_SUB)
    if isinstance(v, list):
        return [sub_nul(x) for x in v]
    if isinstance(v, dict):
        return {sub_nul(k): sub_nul(x) for k, x in v.items()}
    return v


_ESC = re.compile(r'\\(0|x00|u\{0{1,6}\})')


def sub_nul_text(text):
    """Rewrite the NUL escapes inside the string literals of Cedar policy text."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            lit, k, buf = text[i:j + 1], 0, []
            while k < len(lit):
                if lit[k] == '\\':
                    mm = _ESC.match(lit, k)
                    if mm:
                        buf.append('\\u{e000}')
                        k = mm.end()
                        continue
                    buf.append(lit[k:k + 2])
                    k += 2
                    continue
                buf.append(NUL_SUB if lit[k] == '\x00' else lit[k])
                k += 1
            out.append(''.join(buf))
            i = j + 1
        elif c == '/' and text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def jtext(v):
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))


def lit(s):
    return 'null' if s is None else "'" + s.replace("'", "''") + "'"


def jlit(v):
    return lit(jtext(v)) + '::jsonb'


def uid_text(u):
    """Cedar UID text, Type::"id", with the id escaped as a Cedar string literal."""
    u = u.get('__entity', u)
    s = []
    for ch in u['id']:
        o = ord(ch)
        if ch in '"\\':
            s.append('\\' + ch)
        elif o < 0x20 or o == 0x7f:
            s.append('\\u{%x}' % o)
        else:
            s.append(ch)
    return '%s::"%s"' % (u['type'], ''.join(s))


def expected(r):
    return {'decision': r['decision'].lower(), 'reasons': sorted(set(r['reason'])),
            'errors': sorted(set(r['errors']))}


def templatize(c):
    """Turn each static policy whose principal or resource scope names an entity
    into a template with a slot there, plus a link that fills the slot with that
    entity under the original policy id. Same answers, same reasons and errors."""
    policies, links = [], list(c['templateLinks'])
    for p in c['policies']:
        est = p['est']
        vals = {}
        new = dict(est)
        for var in ('principal', 'resource'):
            s = est[var]
            if s.get('op') in ('==', 'in') and 'entity' in s:
                vals['?' + var] = s['entity']
                new[var] = {'op': s['op'], 'slot': '?' + var}
            elif s.get('op') == 'is' and 'entity' in (s.get('in') or {}):
                vals['?' + var] = s['in']['entity']
                new[var] = dict(s, **{'in': {'slot': '?' + var}})
        if p['kind'] != 'static' or not vals:
            policies.append(p)
            continue
        tid = p['id'] + '_template'
        policies.append(dict(p, id=tid, kind='template', est=new, text=None))
        links.append({'templateId': tid, 'newId': p['id'], 'values': vals})
    return dict(c, policies=policies, templateLinks=links)


def case_sql(case, sel, skips, stats):
    fmt, mode = sel['format'], sel['mode']
    c = case
    if any(NUL_SUB in json.dumps(x, ensure_ascii=False) for x in (c['policies'], c['entities'], c['requests'])):
        stats['skipped']['nul-collision'] += len(c['requests'])
        return None, 0
    if 'nul' in c['features']:
        stats['nul_substituted'] += 1
        c = dict(c, policies=[dict(p, est=sub_nul(p['est']), text=p['text'] and sub_nul_text(p['text']))
                              for p in c['policies']],
                 entities=sub_nul(c['entities']), requests=sub_nul(c['requests']),
                 templateLinks=sub_nul(c['templateLinks']))
    if sel.get('templatize') and fmt == 'json':
        c = templatize(c)
    if sel.get('reduce_parents'):
        c = dict(c, entities=reduce_parents(c['entities'])[0])
    lm = label_mode(sel)
    if sel.get('parse_est'):
        return parse_sql(case['name'], c, lm)
    out = [f"\n-- {c['name']}", 'select cedar_test.reset();']
    for p in c['policies']:
        fn = 'cedar_put_policy' if p['kind'] == 'static' else 'cedar_put_template'
        arg = 'policy' if p['kind'] == 'static' else 'template'
        idarg = 'policy_id' if p['kind'] == 'static' else 'template_id'
        if fmt == 'text':
            out.append(f"select permissions.{fn}({idarg} => {lit(p['id'])}, {arg} => {lit(p['text'])});")
        else:
            out.append(f"select permissions.{fn}({idarg} => {lit(p['id'])}, {arg}_json => {jlit(p['est'])});")
    for link in c['templateLinks']:
        vals = link.get('values') or {}
        out.append('select permissions.cedar_link_template(policy_id => %s, template_id => %s, principal => %s, resource => %s);' % (
            lit(link['newId']), lit(link['templateId']),
            lit(uid_text(vals['?principal'])) if '?principal' in vals else 'null',
            lit(uid_text(vals['?resource'])) if '?resource' in vals else 'null'))
    if mode == 'stored' and c['entities']:
        out.append(f"select permissions.cedar_put_entities(entities => {jlit(c['entities'])});")
    overlay = jlit(c['entities']) if mode == 'overlay' else 'null'
    n = 0
    if sel.get('check_est') and fmt == 'text':
        # The parser oracle: the stored EST of each text policy equals the CLI's.
        for p in c['policies']:
            if p['kind'] != 'static':
                continue
            out.append("select tap.is((select p.est from permissions.cedar_policies() p where p.policy_id = %s), %s, %s);" % (
                lit(p['id']), jlit(p['est']), lit(f"{lm}:{fmt}:{case['name']}:est:{p['id']}")))
            n += 1
    for i, r in enumerate(c['requests']):
        reason = skip_reason(skips, case, fmt, mode, i)
        if reason:
            stats['skipped'][reason] += 1
            continue
        out.append("select tap.is(cedar_test.authz(%s, %s, %s, %s, %s), %s, %s);" % (
            lit(uid_text(r['principal'])), lit(uid_text(r['action'])), lit(uid_text(r['resource'])),
            jlit(r['context']), overlay, jlit(expected(r)), lit(f"{lm}:{fmt}:{case['name']}:r{i}")))
        n += 1
    # reset() clears policies and entities; templates go here, after their links.
    for link in c['templateLinks']:
        out.append('select permissions.cedar_delete_policy(policy_id => %s);' % lit(link['newId']))
    for p in c['policies']:
        if p['kind'] == 'template':
            out.append('select permissions.cedar_delete_template(template_id => %s);' % lit(p['id']))
    return '\n'.join(out) + '\n', n


def parse_sql(name, c, lm):
    """The parser oracle: each text policy alone, and the policies of the case
    joined into one policy set (ids policy0, policy1, ... as the CLI gives them)."""
    out = [f"\n-- {name}"]
    n = 0
    for p in c['policies']:
        out.append("select tap.is(cedar_test.parse(%s), %s, %s);" % (
            lit(p['text']), jlit(p['est']), lit(f"{lm}:text:{name}:est:{p['id']}")))
        n += 1
    if parse_set_cases(c):
        want = {'staticPolicies': {p['id']: p['est'] for p in c['policies']}, 'templates': {}, 'templateLinks': []}
        out.append("select tap.is(cedar_test.parse_set(%s), %s, %s);" % (
            lit('\n'.join(p['text'] for p in c['policies'])), jlit(want), lit(f"{lm}:text:{name}:set")))
        n += 1
    return '\n'.join(out) + '\n', n


def parse_set_cases(c):
    return len(c['policies']) > 1 and [p['id'] for p in c['policies']] == [f'policy{i}' for i in range(len(c['policies']))]


def select_from_args(args):
    sel = dict(PHASES['all'])
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('--check-est', '--templatize', '--reduce-parents', '--parse-est'):
            sel[a[2:].replace('-', '_')] = True
            i += 1
            continue
        if a in ('--phase', '--format', '--mode', '--features') and i + 1 < len(args):
            v = args[i + 1]
            if a == '--phase':
                if v not in PHASES:
                    sys.exit(f'unknown phase {v!r}; one of {", ".join(PHASES)}')
                sel = dict(PHASES[v])
            elif a == '--format':
                if v not in ('json', 'text'):
                    sys.exit('--format json|text')
                sel['format'] = v
            elif a == '--mode':
                if v not in ('stored', 'overlay'):
                    sys.exit('--mode stored|overlay')
                sel['mode'] = v
            else:
                feats = GATED if v == 'all' else tuple(x for x in v.split(',') if x)
                bad = set(feats) - set(GATED)
                if bad:
                    sys.exit(f'unknown features {sorted(bad)}; gated features: {", ".join(GATED)}')
                sel['features'] = feats
            i += 2
        else:
            sys.exit(__doc__)
    if sel.get('reduce_parents') and sel['mode'] != 'stored':
        sys.exit('--reduce-parents needs --mode stored')
    if sel.get('parse_est') and (sel['format'] != 'text' or sel['mode'] != 'stored' or sel.get('reduce_parents')
                                 or sel.get('templatize')):
        sys.exit('--parse-est needs --format text, and no --mode, --reduce-parents or --templatize')
    if sel.get('templatize') and sel['format'] != 'json':
        sys.exit('--templatize needs --format json')
    return sel


def plan_files(cases, sel, skips):
    """[(file name, sql, assertions, case names)], deterministic."""
    stats = {'skipped': Counter(), 'left_out': Counter(), 'nul_substituted': 0}
    prefix = FILE_PREFIX[(sel['format'], label_mode(sel))]
    files, cur, cur_n, cur_bytes, cur_names = [], [], 0, 0, []
    for c in cases:
        why = eligible(c, sel)
        if why:
            stats['left_out'][why] += len(c['requests'])
            continue
        sql, n = case_sql(c, sel, skips, stats)
        if not n:
            continue
        if cur and (cur_n + n > MAX_ASSERTIONS or cur_bytes + len(sql) > MAX_BYTES):
            files.append((cur, cur_n, cur_names))
            cur, cur_n, cur_bytes, cur_names = [], 0, 0, []
        cur.append(sql)
        cur_n += n
        cur_bytes += len(sql.encode('utf-8'))
        cur_names.append(c['name'])
    if cur:
        files.append((cur, cur_n, cur_names))
    out = []
    for k, (parts, n, names) in enumerate(files, 1):
        head = [
            f"-- Generated by test/cedar/generate.py --format {sel['format']} --mode {sel['mode']} "
            f"--features {','.join(sel['features']) or '(none)'}"
            f"{' --reduce-parents' if sel.get('reduce_parents') else ''}"
            f"{' --templatize' if sel.get('templatize') else ''}{' --parse-est' if sel.get('parse_est') else ''}. Do not edit.",
            '-- cedar-integration-tests, Apache-2.0: see test/cedar/upstream/SOURCE.',
            '\\set ON_ERROR_STOP off',
            '\\ir ../../cedar/fixture.sql',
            f'select tap.plan({n});',
        ]
        out.append((f'{prefix}_{k:02d}.sql', '\n'.join(head) + '\n' + ''.join(parts) + '\nselect * from tap.finish();\n', n, names))
    return out, stats


def generate(dest, sel, dry_run, cases=None):
    cases = cases or load_cases()
    skips = load_skips()
    files, stats = plan_files(cases, sel, skips)
    prefix = FILE_PREFIX[(sel['format'], label_mode(sel))]
    total = sum(n for _, _, n, _ in files)
    size = sum(len(sql.encode('utf-8')) for _, sql, _, _ in files)
    if not dry_run:
        os.makedirs(dest, exist_ok=True)
        for old in glob.glob(os.path.join(dest, prefix + '_[0-9][0-9].sql')):
            os.remove(old)
        for name, sql, _, _ in files:
            with open(os.path.join(dest, name), 'w', encoding='utf-8') as f:
                f.write(sql)
    verb = 'would write' if dry_run else 'wrote'
    print(f'{verb} {len(files)} files {os.path.relpath(dest, ROOT)}/{prefix}_NN.sql: '
          f'{total} assertions, {size / 1e6:.1f} MB')
    print(f"  selection: format {sel['format']}, mode {sel['mode']}, features {','.join(sel['features']) or '(none)'}"
          f"{', parents reduced' if sel.get('reduce_parents') else ''}{', templatized' if sel.get('templatize') else ''}"
          f"{', parse only' if sel.get('parse_est') else ''}")
    print(f"  cases with U+0000 substituted: {stats['nul_substituted']}")
    for r, k in sorted(stats['left_out'].items()):
        print(f'  left out ({r}): {k} requests')
    for r, k in sorted(stats['skipped'].items()):
        print(f'  skipped ({r}): {k} requests')
    if dry_run:
        for name, sql, n, names in files:
            print(f'    {name}: {n} assertions, {len(names)} cases, {len(sql.encode("utf-8")) / 1e3:.0f} kB')


# ---- stats ------------------------------------------------------------------

def table(title, rows, cases, reqs):
    print(f'\n{title}')
    print(f'  {"":<22}{"cases":>8}{"requests":>10}')
    for k, (c, r) in rows:
        print(f'  {k:<22}{c:>8}{r:>10}')
    print(f'  {"total":<22}{cases:>8}{reqs:>10}')


def stats():
    cases = load_cases()
    corpus = [c for c in cases if c['name'].startswith('corpus/')]
    hand = [c for c in cases if not c['name'].startswith('corpus/')]
    nreq = lambda cs: sum(len(c['requests']) for c in cs)
    print(f'cases: {len(cases)} ({len(corpus)} corpus, {len(hand)} handwritten); '
          f'requests: {nreq(cases)} ({nreq(corpus)} corpus, {nreq(hand)} handwritten)')
    dec = Counter(r['decision'] for c in cases for r in c['requests'])
    err = sum(1 for c in cases for r in c['requests'] if r['errors'])
    print(f'decisions: allow {dec["allow"]}, deny {dec["deny"]}; requests with expected errors: {err}')

    def group(key):
        acc = OrderedDict()
        for c in cases:
            for k in key(c):
                a = acc.setdefault(k, [0, 0])
                a[0] += 1
                a[1] += len(c['requests'])
        return sorted(acc.items())
    table('by policyFormat', group(lambda c: [c['policyFormat']]), len(cases), nreq(cases))
    table('by shouldValidate', group(lambda c: [str(c['shouldValidate']).lower()]), len(cases), nreq(cases))
    table('by feature (a case counts once per feature it uses)', group(lambda c: sorted(c['features'])),
          len(cases), nreq(cases))
    table('schema-dependent entity/context JSON (what convert.py made explicit)',
          group(lambda c: c['schemaDependent'] or ['(none)']), len(cases), nreq(cases))
    ext = set(GATED) - {'template'}
    table('extension use', group(lambda c: [','.join(sorted(c['features'] & ext)) or '(none)']),
          len(cases), nreq(cases))
    print('\nphase presets (cases / requests that the preset selects)')
    for p, sel in PHASES.items():
        for fmt in ('json', 'text'):
            s = dict(sel, format=fmt)
            sc = [c for c in cases if eligible(c, s) is None]
            print(f'  {p:<4} {fmt:<5} {len(sc):>6} {nreq(sc):>8}')
    print('\nsizes (max over cases; p99 in brackets)')
    for k in ('policies', 'policy_bytes', 'est_bytes', 'max_depth', 'nodes', 'entities', 'entity_bytes',
              'ancestor_depth', 'max_abs_long'):
        vals = sorted(c['metrics'][k] for c in cases)
        print(f'  {k:<16}{vals[-1]:>22} [{vals[int(len(vals) * 0.99)]}]')
    reqs = sorted(len(c['requests']) for c in cases)
    print(f'  {"requests/case":<16}{reqs[-1]:>22} [{reqs[int(len(reqs) * 0.99)]}]')


# ---- report -----------------------------------------------------------------

def report(path, sel):
    cases = load_cases()
    skips = load_skips()
    want = {}
    for c in cases:
        if eligible(c, sel):
            continue
        if sel.get('parse_est'):
            for p in c['policies']:
                want[f"parse:text:{c['name']}:est:{p['id']}"] = c['name']
            if parse_set_cases(c):
                want[f"parse:text:{c['name']}:set"] = c['name']
            continue
        for i in range(len(c['requests'])):
            if not skip_reason(skips, c, sel['format'], sel['mode'], i):
                want[f"{label_mode(sel)}:{sel['format']}:{c['name']}:r{i}"] = c['name']
        if sel.get('check_est') and sel['format'] == 'text':
            for p in c['policies']:
                if p['kind'] == 'static':
                    want[f"{label_mode(sel)}:text:{c['name']}:est:{p['id']}"] = c['name']
    got = {}
    pat = re.compile(r'^\s*(ok|not ok) \d+ - (\S+:(?:r\d+|est:\S+|set))')
    with open(path, encoding='utf-8', errors='replace') as f:
        for l in f:
            m = pat.match(re.sub(r'\x1b\[[0-9;]*m', '', l))
            if m:
                got[m.group(2)] = m.group(1) == 'ok'
    passed = sum(1 for k in want if got.get(k) is True)
    failed = sorted(k for k in want if got.get(k) is False)
    missing = sum(1 for k in want if k not in got)
    bad_cases = sorted({want[k] for k in want if got.get(k) is not True})
    print(f'assertions expected {len(want)}, passed {passed}, failed {len(failed)}, not run {missing}; '
          f'cases failing {len(bad_cases)}')
    for n in bad_cases[:50]:
        print(f'    failed: {n}')
    if len(bad_cases) > 50:
        print(f'    ... and {len(bad_cases) - 50} more')


if __name__ == '__main__':
    argv = sys.argv[1:]
    if argv[:1] == ['report'] and len(argv) >= 2:
        report(argv[1], select_from_args(argv[2:]))
    elif argv[:1] == ['--stats'] and len(argv) == 1:
        stats()
    elif argv[:1] == ['--dry-run']:
        generate(OUT_DIR, select_from_args(argv[1:]), dry_run=True)
    elif argv[:1] == ['--suite']:
        generate(SUITE_DIR, select_from_args(argv[1:]), dry_run=False)
    elif argv == ['suite']:
        all_cases = load_cases()
        for run in SUITE:
            generate(SUITE_DIR, select_from_args(run), dry_run=False, cases=all_cases)
    elif argv[:1] in ([], ['--phase'], ['--format'], ['--mode'], ['--features'], ['--check-est'], ['--templatize'],
                      ['--reduce-parents'], ['--parse-est']):
        generate(OUT_DIR, select_from_args(argv), dry_run=False)
    else:
        sys.exit(__doc__)
