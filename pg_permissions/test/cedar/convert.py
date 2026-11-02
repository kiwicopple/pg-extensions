#!/usr/bin/env python3
"""Convert cedar-integration-tests into test/cedar/cases/ (run by vendor.sh).

    python3 -I convert.py manifest SRC              > manifest.tsv
    python3 -I convert.py build SRC TRANS OUT_DIR

SRC is the upstream tree with `corpus-tests/` (from corpus-tests.tar.gz),
`tests/` and `sample-data/`. `manifest` lists every Cedar-text policy file and
Cedar-text schema file in it, with the name of the JSON translation that
vendor.sh asks the pinned Cedar CLI for (in TRANS):

    policy  cedar translate-policy --direction cedar-to-json
    schema  cedar translate-schema --direction cedar-to-json-with-resolved-types

`build` writes one normalized test per line (sorted by name) into
OUT_DIR/handwritten.jsonl and OUT_DIR/corpus-NN.jsonl.gz. Each line holds:

    name            corpus/<sha1> or tests/<dir>/<file> (without .json)
    policyFormat    "cedar" or "json", as upstream
    shouldValidate  as upstream (we do not validate; kept for the counts)
    policies        [{id, kind: static|template, text, est}], in policy-id
                    order. `est` is Cedar's JSON policy format (from the CLI for
                    text files, verbatim for JSON files). `text` is the source
                    text of that one policy (null for JSON-format files): the
                    file split at top-level `;`, checked against the CLI's count.
    templateLinks   as upstream JSON policy sets (none in this release)
    entities        upstream entity JSON, normalized as Cedar parses it with
                    the test's schema (see below)
    requests        [{description, principal, action, resource, context,
                      decision, reason, errors}]; context normalized too
    schemaDependent sorted list of what the normalization changed:
                      actions  action entities taken from the schema
                      extn     an extension value without __extn
                      entity   an entity reference without __entity
                    Empty when the test needs no schema to evaluate.

Why normalize. Cedar's harness parses entities and context with the schema
(cedar-testing/src/integration_testing.rs: Entities::from_json_file(json,
Some(schema)) and Context::from_json_value(json, Some((schema, action)))).
That adds the schema's action entities and accepts implicit forms. The
extension never reads a schema, so the vendored data carries what Cedar sees,
written in the schema-free (escaped) form. Expectations are never changed.
"""
import gzip
import json
import os
import sys

SHARDS = 8
EXT_FN = {'__cedar::decimal': 'decimal', '__cedar::ipaddr': 'ip',
          '__cedar::datetime': 'datetime', '__cedar::duration': 'duration'}


def die(msg):
    sys.exit('convert.py: ' + msg)


def trans_name(path):
    return path.replace('/', '__') + '.json'


def manifest(src):
    out = []
    for d, _, files in os.walk(src):
        for f in files:
            p = os.path.relpath(os.path.join(d, f), src)
            if p.endswith('.cedar'):
                out.append(('policy', p))
            elif p.endswith('.cedarschema'):
                out.append(('schema', p))
    for kind, p in sorted(out):
        print(kind, p, trans_name(p), sep='\t')


def split_policies(text):
    """Split Cedar policy text at top-level `;` (outside strings and // comments)."""
    out, start, i, n = [], 0, 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif c == '/' and text.startswith('//', i):
            while i < n and text[i] != '\n':
                i += 1
        elif c == ';':
            out.append(text[start:i + 1].strip())
            start = i + 1
        i += 1
    rest = text[start:]
    # Only whitespace and comments may follow the last policy.
    for line in rest.splitlines():
        if line.strip() and not line.strip().startswith('//'):
            die('text after the last policy: %r' % rest[:80])
    return out


# ---- schema-based normalization -------------------------------------------

def qualify(ns, name):
    return name if '::' in name or not ns else ns + '::' + name


def action_type(ns):
    return qualify(ns, 'Action')


def schema_index(schema):
    """(entity attribute types, entity tag types, action entities, context types)."""
    attrs, tags, actions, contexts = {}, {}, {}, {}
    for ns, body in schema.items():
        for name, et in (body.get('entityTypes') or {}).items():
            full = qualify(ns, name)
            shape = et.get('shape')
            if shape:
                attrs[full] = shape
            if et.get('tags'):
                tags[full] = et['tags']
        for name, a in (body.get('actions') or {}).items():
            uid = (action_type(ns), name)
            parents = []
            for m in a.get('memberOf') or []:
                parents.append({'type': qualify(ns, m['type']) if m.get('type') else action_type(ns),
                                'id': m['id']})
            actions[uid] = parents
            ctx = (a.get('appliesTo') or {}).get('context')
            if ctx:
                contexts[uid] = ctx
    return attrs, tags, actions, contexts


def norm_value(v, ty, changed):
    """Rewrite the implicit forms that schema-based parsing accepts for type `ty`."""
    if not isinstance(ty, dict):
        return v
    t = ty.get('type')
    if t in EXT_FN:
        if isinstance(v, str):
            changed.add('extn')
            return {'__extn': {'fn': EXT_FN[t], 'arg': v}}
        if isinstance(v, dict) and set(v) == {'fn', 'arg'}:
            changed.add('extn')
            return {'__extn': v}
        return v
    if t == 'Entity':
        if isinstance(v, dict) and set(v) == {'type', 'id'}:
            changed.add('entity')
            return {'__entity': v}
        return v
    if t == 'Set' and isinstance(v, list):
        return [norm_value(x, ty.get('element'), changed) for x in v]
    if t == 'Record' and isinstance(v, dict) and '__extn' not in v and '__entity' not in v:
        at = ty.get('attributes') or {}
        return {k: norm_value(x, at.get(k), changed) for k, x in v.items()}
    return v


def uid_of(u):
    u = u.get('__entity', u)
    return (u['type'], u['id'])


def action_closure(actions, uid):
    out, todo = set(), [uid]
    while todo:
        for p in actions.get(todo.pop(), []):
            p = uid_of(p)
            if p not in out:
                out.add(p)
                todo.append(p)
    return out


def norm_entities(entities, idx, changed):
    attrs, tags, actions, _ = idx
    out, seen = [], {}
    for e in entities:
        e = dict(e)
        ty, _id = uid_of(e['uid'])
        if 'attrs' in e and ty in attrs:
            e['attrs'] = norm_value(e['attrs'], attrs[ty], changed)
        if e.get('tags') and ty in tags:
            e['tags'] = {k: norm_value(v, tags[ty], changed) for k, v in e['tags'].items()}
        seen[(ty, _id)] = e
        out.append(e)
    for uid, parents in sorted(actions.items()):
        if uid in seen:
            # Cedar writes entity JSON with transitively closed parents.
            got = set(uid_of(p) for p in seen[uid].get('parents') or [])
            if got != action_closure(actions, uid):
                die('action %r: entity JSON parents %r differ from the schema %r' % (uid, got, parents))
            continue
        changed.add('actions')
        out.append({'uid': {'type': uid[0], 'id': uid[1]}, 'attrs': {}, 'parents': parents})
    return out


# ---- build -----------------------------------------------------------------

def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def load_test(src, trans, rel):
    t = load_json(os.path.join(src, rel))
    fmt = t.get('policyFormat', 'cedar')
    if fmt == 'cedar':
        with open(os.path.join(src, t['policies']), encoding='utf-8') as f:
            text = f.read()
        pset = load_json(os.path.join(trans, trans_name(t['policies'])))
        texts = split_policies(text)
    else:
        pset = load_json(os.path.join(src, t['policies']))
        texts = None
    ests = {}
    for kind, key in (('static', 'staticPolicies'), ('template', 'templates')):
        for pid, est in (pset.get(key) or {}).items():
            ests[pid] = (kind, est)
    # Text policy sets get ids policy0, policy1, ... in source order.
    ids = sorted(ests, key=lambda p: (len(p), p)) if texts is None else ['policy%d' % i for i in range(len(texts))]
    if set(ids) != set(ests):
        die('%s: policy ids %r do not match the translation %r' % (rel, ids, sorted(ests)))
    policies = [{'id': pid, 'kind': ests[pid][0], 'text': texts[i] if texts else None, 'est': ests[pid][1]}
                for i, pid in enumerate(ids)]

    if t.get('schemaFormat', 'cedar') == 'cedar':
        schema = load_json(os.path.join(trans, trans_name(t['schema'])))
    else:
        schema = load_json(os.path.join(src, t['schema']))
    idx = schema_index(schema)
    changed = set()
    entities = norm_entities(load_json(os.path.join(src, t['entities'])), idx, changed)
    requests = []
    for r in t['requests']:
        ctx_ty = idx[3].get(uid_of(r['action']))
        requests.append({
            'description': r.get('description'),
            'principal': r.get('principal'),
            'action': r.get('action'),
            'resource': r.get('resource'),
            'context': norm_value(r.get('context', {}), ctx_ty, changed) if ctx_ty else r.get('context', {}),
            'decision': r['decision'],
            'reason': r.get('reason') or [],
            'errors': r.get('errors') or [],
        })
    name = rel[:-len('.json')]
    if name.startswith('corpus-tests/'):
        name = 'corpus/' + name[len('corpus-tests/'):]
    return {
        'name': name,
        'policyFormat': fmt,
        'shouldValidate': t.get('shouldValidate'),
        'policies': policies,
        'templateLinks': pset.get('templateLinks') or [],
        'entities': entities,
        'requests': requests,
        'schemaDependent': sorted(changed),
    }


def line(case):
    return json.dumps(case, ensure_ascii=False, separators=(',', ':')) + '\n'


def write_gz(path, lines):
    with open(path, 'wb') as raw:
        # mtime=0 and no file name: the same input gives the same bytes.
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0, compresslevel=9) as gz:
            for l in lines:
                gz.write(l.encode('utf-8'))


def build(src, trans, out):
    tests = []
    for d, _, files in os.walk(src):
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), src)
            if not f.endswith('.json') or f.endswith('.entities.json'):
                continue
            if rel.startswith('corpus-tests/') or (rel.startswith('tests/') and 'requests' in load_json(os.path.join(src, rel))):
                tests.append(rel)
    tests.sort()
    hand = [load_test(src, trans, r) for r in tests if r.startswith('tests/')]
    corpus = [load_test(src, trans, r) for r in tests if r.startswith('corpus-tests/')]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'handwritten.jsonl'), 'w', encoding='utf-8') as f:
        f.writelines(line(c) for c in hand)
    # Shard by the first hex digit of the corpus hash: stable across releases.
    per = 16 // SHARDS
    for s in range(SHARDS):
        digits = '0123456789abcdef'[s * per:(s + 1) * per]
        write_gz(os.path.join(out, 'corpus-%02d.jsonl.gz' % (s + 1)),
                 (line(c) for c in corpus if c['name'][len('corpus/')] in digits))
    print('converted %d handwritten and %d corpus tests (%d requests)' % (
        len(hand), len(corpus), sum(len(c['requests']) for c in hand + corpus)), file=sys.stderr)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'manifest':
        manifest(sys.argv[2])
    elif len(sys.argv) == 5 and sys.argv[1] == 'build':
        build(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
