#!/usr/bin/env python3
"""Compare the IDNA tables embedded in pg_validate--0.0.1.sql with their sources.

    data/refresh_idna.py                 fetch the sources, print a summary and a diff
    data/refresh_idna.py --sql           also print the regenerated SQL literals
    data/refresh_idna.py --cache DIR     keep the downloaded files in DIR

validate.hostname, validate.idn_hostname and validate.idn_email check labels
against IDNA2008 (RFC 5890-5893). They embed one table of code point ranges,
built from these sources (data/README.md records the snapshot):

    IANA "IDNA Parameters" derived properties (RFC 5892), version 12.0.0, the
        latest the registry publishes:
        https://www.iana.org/assignments/idna-tables-12.0.0/idna-tables-properties.csv
    Unicode Character Database 12.0.0, the same Unicode version:
        extracted/DerivedBidiClass.txt        Bidi_Class (RFC 5893, the Bidi rule)
        extracted/DerivedJoiningType.txt      Joining_Type (RFC 5892 A.1, ZERO WIDTH NON-JOINER)
        extracted/DerivedCombiningClass.txt   Canonical_Combining_Class = Virama (A.1, A.2)
        extracted/DerivedGeneralCategory.txt  General_Category M (RFC 5891 5.4, no leading mark)
        Scripts.txt                           Greek, Hebrew, Hiragana, Katakana, Han (A.4-A.7)
    UTS #46 IdnaMappingTable 12.0.0: the code points that the mapping ignores
        (status "ignored"), which idn_hostname removes before checking.

Only code points that IANA lists as PVALID, CONTEXTJ or CONTEXTO are in the
table; every other code point (DISALLOWED, UNASSIGNED) is a gap, which the
validators reject. Each range has one class character; the legend gives the
attributes of each class, one string per attribute, so that translate() turns
a label's class string into, for example, its Bidi classes. The SQL holds two
generated blocks, "IDNA TABLE" (in validate._idna_label) and "UTS46 IGNORED"
(in validate._idna_hostname); --sql prints both.

Exits 1 when the SQL differs from what the sources produce, 0 when it matches.
Python 3.9+, standard library only.
"""
import argparse
import csv
import hashlib
import io
import pathlib
import re
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SQL = HERE.parent / 'pg_validate--0.0.1.sql'

IANA = 'https://www.iana.org/assignments/idna-tables-12.0.0/idna-tables-properties.csv'
UCD = 'https://www.unicode.org/Public/12.0.0/ucd/{}'
UTS46 = 'https://www.unicode.org/Public/idna/12.0.0/IdnaMappingTable.txt'
USER_AGENT = 'pg_validate-refresh (https://github.com/kiwicopple/pg-extensions)'

# Class characters, in order of first use. '.' marks a gap (not valid).
ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
BIDI_CODE = {'L': 'L', 'R': 'R', 'AL': 'A', 'AN': 'N', 'EN': 'E', 'ES': 'S', 'CS': 'C',
             'ET': 'T', 'ON': 'O', 'BN': 'B', 'NSM': 'M'}
SCRIPT_CODE = {'Greek': 'G', 'Hebrew': 'H', 'Hiragana': 'I', 'Katakana': 'K', 'Han': 'C'}


def fetch(url, cache):
    name = url.rsplit('/', 1)[-1]
    if cache and (cache / name).exists():
        data = (cache / name).read_bytes()
    else:
        req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
        if cache:
            cache.mkdir(parents=True, exist_ok=True)
            (cache / name).write_bytes(data)
    print(f'  {url}\n    sha256 {hashlib.sha256(data).hexdigest()}')
    return data.decode('utf-8')


def ucd_ranges(text, field=1):
    """Code point -> value of the field, from a UCD file of ranges."""
    out = {}
    for line in text.split('\n'):
        line = line.split('#')[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(';')]
        lo, _, hi = parts[0].partition('..')
        for cp in range(int(lo, 16), int(hi or lo, 16) + 1):
            out[cp] = parts[field]
    return out


def build(cache):
    print('Sources:')
    props = {}
    for row in csv.DictReader(io.StringIO(fetch(IANA, cache))):
        lo, _, hi = row['Codepoint'].partition('-')
        for cp in range(int(lo, 16), int(hi or lo, 16) + 1):
            props[cp] = row['Property']
    bidi = ucd_ranges(fetch(UCD.format('extracted/DerivedBidiClass.txt'), cache))
    joining = ucd_ranges(fetch(UCD.format('extracted/DerivedJoiningType.txt'), cache))
    ccc = ucd_ranges(fetch(UCD.format('extracted/DerivedCombiningClass.txt'), cache))
    gc = ucd_ranges(fetch(UCD.format('extracted/DerivedGeneralCategory.txt'), cache))
    script = ucd_ranges(fetch(UCD.format('Scripts.txt'), cache))
    ignored = sorted(cp for cp, status in ucd_ranges(fetch(UTS46, cache)).items() if status == 'ignored')

    def attrs(cp):
        prop = props.get(cp)
        if prop not in ('PVALID', 'CONTEXTJ', 'CONTEXTO'):
            return None
        b = bidi.get(cp, 'L')
        if b not in BIDI_CODE:
            sys.exit(f'U+{cp:04X}: Bidi class {b} has no code')
        j = joining.get(cp, 'U')
        return (
            {'PVALID': 'P', 'CONTEXTJ': 'J', 'CONTEXTO': 'O'}[prop],
            BIDI_CODE[b],
            'M' if gc.get(cp, 'Cn') in ('Mn', 'Mc', 'Me') else '-',
            'V' if ccc.get(cp, '0') == '9' else '-',
            j if j in ('L', 'D', 'R', 'T') else 'U',
            SCRIPT_CODE.get(script.get(cp, 'Zzzz'), '-'),
        )

    classes = {}
    bounds, chars = [], []
    prev = object()
    for cp in range(0x110000):
        a = attrs(cp)
        if a != prev:
            if a is not None and a not in classes:
                classes[a] = ALPHABET[len(classes)]
            bounds.append(cp)
            chars.append('.' if a is None else classes[a])
            prev = a
    legend = {name: ''.join(a[i] for a in classes) for i, name in
              enumerate(('prop', 'bidi', 'mark', 'virama', 'joining', 'script'))}
    alphabet = ''.join(classes.values())
    # ignored code points as ranges
    ign = []
    for cp in ignored:
        if ign and ign[-1][1] == cp - 1:
            ign[-1][1] = cp
        else:
            ign.append([cp, cp])
    return {
        'bounds': bounds, 'classes': ''.join(chars), 'alphabet': alphabet, 'legend': legend,
        'ignored': ign,
        'counts': {p: sum(1 for v in props.values() if v == p) for p in ('PVALID', 'CONTEXTJ', 'CONTEXTO')},
    }


def split_literal(text, width, breaks=None):
    """A SQL string literal split over lines (adjacent literals separated by
    a newline are one literal), so it stays a single constant."""
    lines, cur = [], ''
    parts = text.split(breaks) if breaks else [text[i:i + width] for i in range(0, len(text), width)]
    for n, part in enumerate(parts):
        piece = part + (breaks if breaks and n < len(parts) - 1 else '')
        if cur and len(cur) + len(piece) > width:
            lines.append(cur)
            cur = ''
        cur += piece
    lines.append(cur)
    return [l.rstrip() for l in lines]


def block_table(t):
    bounds = split_literal('{' + ','.join(str(b) for b in t['bounds']) + '}', 72, ',')
    classes = split_literal(t['classes'], 72)
    lg = t['legend']
    out = ['-- BEGIN GENERATED IDNA TABLE by data/refresh_idna.py --sql',
           '    -- IANA IDNA Parameters 12.0.0 and UCD 12.0.0. Code point ranges start at',
           '    -- bounds[i] and have class classes[i]; "." is DISALLOWED or UNASSIGNED.',
           f"    bounds   constant int[] := '{bounds[0]}'"]
    out += [f"        '{l}'" for l in bounds[1:]]
    out[-1] += '::int[];'
    out.append(f"    classes  constant text := '{classes[0]}'")
    out += [f"        '{l}'" for l in classes[1:]]
    out[-1] += ';'
    out += [
        '    -- One character per class, in the order of alphabet.',
        f"    alphabet constant text := '{t['alphabet']}';",
        f"    l_prop   constant text := '{lg['prop']}'; -- P PVALID, J CONTEXTJ, O CONTEXTO",
        f"    l_bidi   constant text := '{lg['bidi']}'; -- Bidi_Class, see below",
        f"    l_mark   constant text := '{lg['mark']}'; -- M General_Category Mn, Mc, Me",
        f"    l_virama constant text := '{lg['virama']}'; -- V Canonical_Combining_Class Virama",
        f"    l_join   constant text := '{lg['joining']}'; -- Joining_Type L, D, R, T, else U",
        f"    l_script constant text := '{lg['script']}'; -- G Greek, H Hebrew, I Hiragana, K Katakana, C Han",
        '-- END GENERATED IDNA TABLE',
    ]
    return '\n'.join(out)


def block_ignored(t):
    parts = []
    for a, b in t['ignored']:
        parts.append(f'chr({a})' if a == b else f"chr({a}) || '-' || chr({b})")
    lines = split_literal(' || '.join(parts), 64, ' || ')
    out = ['-- BEGIN GENERATED UTS46 IGNORED by data/refresh_idna.py --sql',
           '    -- UTS #46 12.0.0 IdnaMappingTable, status "ignored"',
           f"    ignored constant text := '[' || {lines[0]}"]
    out += [f'        {l}' for l in lines[1:]]
    out[-1] += " || ']';"
    out.append('-- END GENERATED UTS46 IGNORED')
    return '\n'.join(out)


def embedded(tag):
    text = SQL.read_text()
    m = re.search(rf'-- BEGIN GENERATED {tag} by data/refresh_idna.py --sql\n.*?-- END GENERATED {tag}', text, re.S)
    return m.group(0) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--sql', action='store_true', help='print the regenerated SQL block')
    ap.add_argument('--cache', type=pathlib.Path, help='directory for the downloaded files')
    args = ap.parse_args()
    t = build(args.cache)
    print(f"\nIANA 12.0.0: {t['counts']['PVALID']} PVALID, {t['counts']['CONTEXTJ']} CONTEXTJ, "
          f"{t['counts']['CONTEXTO']} CONTEXTO code points")
    print(f"Table: {len(t['bounds'])} ranges, {len(t['alphabet'])} classes; "
          f"{sum(b - a + 1 for a, b in t['ignored'])} ignored code points in {len(t['ignored'])} ranges")
    blocks = {'IDNA TABLE': block_table(t), 'UTS46 IGNORED': block_ignored(t)}
    if args.sql:
        for block in blocks.values():
            print('\n' + block)
    differ = False
    for tag, block in blocks.items():
        current = embedded(tag)
        if current is None:
            print(f'\nThe SQL file has no {tag} block.')
            differ = True
        elif current.strip() != block.strip():
            print(f'\nThe {tag} block in the SQL file differs from the sources. Run with --sql and replace it.')
            differ = True
        else:
            print(f'\nThe {tag} block in the SQL file matches the sources.')
    sys.exit(1 if differ else 0)


main()
