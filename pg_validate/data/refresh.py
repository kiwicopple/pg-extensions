#!/usr/bin/env python3
"""Compare the code lists embedded in pg_validate--0.0.1.sql with their sources.

    data/refresh.py                          fetch the sources, print a diff
    data/refresh.py --iban-registry FILE     use a downloaded SWIFT IBAN Registry (TXT)
    data/refresh.py --sql                    also print the regenerated SQL literals
    data/refresh.py --examples               also print the IBAN registry examples
                                             as rows for test/spec/15_financial.sql

Sources (data/README.md records the snapshot in the extension):

    ISO 4217 List One   SIX Financial Information, list-one.xml
    ISO 3166-1          Debian iso-codes, data/iso_3166-1.json
    ISO 639-1           Debian iso-codes, data/iso_639-2.json (the alpha_2 fields)
    IBAN registry       SWIFT IBAN Registry (TXT). swift.com rejects automated
                        downloads: download "IBAN Registry (TXT)" from
                        https://www.swift.com/standards/data-standards/iban-international-bank-account-number
                        and pass it with --iban-registry. Without it, the script
                        uses the latest Wayback Machine capture of that file.

Prints, for each list, the source version, the counts and the codes to add and
remove (and IBAN length changes), with the SHA-256 of each fetched file. Exits
1 when a list differs from its source, 0 when all match. Nothing here is
needed to install the extension; the SQL file stays the only artifact.

Python 3.9+, standard library only.
"""
import argparse
import gzip
import hashlib
import json
import pathlib
import re
import sys
import textwrap
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = pathlib.Path(__file__).resolve().parent
SQL = HERE.parent / 'pg_validate--0.0.1.sql'

SIX_LIST_ONE = ('https://www.six-group.com/dam/download/financial-information/'
                'data-center/iso-currrency/lists/list-one.xml')
ISO_CODES = 'https://salsa.debian.org/iso-codes-team/iso-codes/-/raw/{ref}/data/{file}'
ISO_CODES_API = ('https://salsa.debian.org/api/v4/projects/iso-codes-team%2Fiso-codes/'
                 'repository/commits?ref_name={ref}&path=data/{file}&per_page=1')
SWIFT_TXT = 'https://www.swift.com/swift-resource/11971/download'
WAYBACK_CDX = ('https://web.archive.org/cdx/search/cdx?url=swift.com/swift-resource/11971/download'
               '&matchType=prefix&filter=statuscode:200&filter=mimetype:text/plain&output=json')
WAYBACK_RAW = 'https://web.archive.org/web/{ts}id_/{url}'

USER_AGENT = 'pg_validate-refresh (https://github.com/kiwicopple/pg-extensions)'


def fetch(url, attempts=4):
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
            break
        except urllib.error.URLError as exc:  # the Wayback Machine often answers 503
            if attempt == attempts:
                raise SystemExit(f'error: {url}: {exc}')
            time.sleep(5 * attempt)
    # The Wayback Machine returns some captures as the original gzip body.
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    return data


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# The lists embedded in the extension
# ---------------------------------------------------------------------------

def function_body(sql, name):
    start = sql.index(f'create function validate.{name}(')
    return sql[start:sql.index('$$;', start)]


def embedded_codes(sql, name, pattern):
    body = function_body(sql, name)
    literal = ''.join(re.findall(r"^\s*'([^']*)'", body, re.M))
    return sorted(c for c in literal.split() if re.fullmatch(pattern, c))


def embedded_iban(sql):
    body = function_body(sql, 'iban')
    return {cc: int(n) for cc, n in re.findall(r"when '([A-Z]{2})' then (\d+)", body)}


# ---------------------------------------------------------------------------
# The sources
# ---------------------------------------------------------------------------

def iso_4217():
    data = fetch(SIX_LIST_ONE)
    root = ET.fromstring(data)
    codes = sorted({e.text for e in root.iter('Ccy') if e.text})
    return codes, f'List One published {root.get("Pblshd")}', SIX_LIST_ONE, data


def iso_codes(file, ref):
    url = ISO_CODES.format(ref=ref, file=file)
    data = fetch(url)
    try:
        commit = json.loads(fetch(ISO_CODES_API.format(ref=ref, file=file)))[0]
        version = f'iso-codes {ref}, last change {commit["id"][:12]} ({commit["committed_date"][:10]})'
    except Exception as exc:  # the version is informative; the data is what counts
        version = f'iso-codes {ref} (commit lookup failed: {exc})'
    return json.loads(data), version, url, data


def iso_3166(ref):
    doc, version, url, data = iso_codes('iso_3166-1.json', ref)
    rows = doc['3166-1']
    return (sorted(r['alpha_2'] for r in rows), sorted(r['alpha_3'] for r in rows),
            version, url, data)


def iso_639_1(ref):
    doc, version, url, data = iso_codes('iso_639-2.json', ref)
    return sorted(r['alpha_2'] for r in doc['639-2'] if 'alpha_2' in r), version, url, data


def iban_registry(path):
    if path:
        data = pathlib.Path(path).read_bytes()
        origin = str(path)
    else:
        # A prefix query groups rows by URL, so sort by timestamp.
        rows = sorted(json.loads(fetch(WAYBACK_CDX))[1:], key=lambda row: row[1])
        if not rows:
            raise SystemExit('error: no Wayback Machine capture of the IBAN Registry; use --iban-registry')
        ts, original = rows[-1][1], rows[-1][2]
        origin = WAYBACK_RAW.format(ts=ts, url=original)
        data = fetch(origin)
    text = data.decode('latin1')
    table = {}
    for line in re.split(r'\r?\n', text):
        cells = line.split('\t')
        if cells[0] and cells[0] not in table:
            table[cells[0]] = [c.strip().strip('"').strip() for c in cells[1:]]
    try:
        prefixes = table['IBAN prefix country code (ISO 3166)']
        lengths = table['IBAN length']
        examples = table['IBAN electronic format example']
        names = table['Name of country']
        others = table['Country code includes other countries/territories']
        updated = table['Last update date']
    except KeyError as exc:
        raise SystemExit(f'error: {origin} is not the IBAN Registry (TXT): no row {exc}')
    registry = {}
    for cc, n, ex, name, oth in zip(prefixes, lengths, examples, names, others):
        cc = re.search(r'[A-Z]{2}', cc).group()
        registry[cc] = {'length': int(re.search(r'\d+', n).group()), 'example': ex.replace(' ', ''),
                        'name': name, 'others': oth}
    latest = max(updated, key=month_year)
    return registry, f'IBAN Registry (TXT), latest entry update {latest}', origin, data


MONTHS = 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split()


def month_year(value):
    m = re.fullmatch(r'([A-Z][a-z]{2})-(\d{2})', value or '')
    return (int(m.group(2)), MONTHS.index(m.group(1)) + 1) if m and m.group(1) in MONTHS else (0, 0)


def mod97(iban):
    s = iban[4:] + iban[:4]
    return int(''.join(str(int(c, 36)) for c in s)) % 97 == 1


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def report(title, version, url, data, embedded, source):
    print(f'== {title}')
    print(f'   source:   {url}')
    print(f'   version:  {version}')
    print(f'   sha256:   {sha256(data)}')
    added = sorted(set(source) - set(embedded))
    removed = sorted(set(embedded) - set(source))
    print(f'   codes:    {len(embedded)} embedded, {len(source)} in the source')
    print(f'   add:      {" ".join(added) or "-"}')
    print(f'   remove:   {" ".join(removed) or "-"}')
    return bool(added or removed)


def sql_literal(codes, width=96):
    lines = textwrap.wrap(' '.join(codes), width)
    out = [f"             ' {line}'" for line in lines]
    out[-1] = out[-1][:-1] + " ',"
    return '\n'.join(out)


def sql_iban(registry):
    items = [f"when '{cc}' then {registry[cc]['length']}" for cc in sorted(registry)]
    return '\n'.join('        ' + ' '.join(items[i:i + 4]) for i in range(0, len(items), 4))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--iban-registry', metavar='FILE',
                        help='a downloaded SWIFT "IBAN Registry (TXT)" file')
    parser.add_argument('--iso-codes-ref', default='main',
                        help='iso-codes branch, tag or commit (default: main)')
    parser.add_argument('--sql', action='store_true', help='print the regenerated SQL literals')
    parser.add_argument('--examples', action='store_true',
                        help='print the IBAN registry examples as test cases')
    args = parser.parse_args()

    sql = SQL.read_text()
    differs = False

    currencies, version, url, data = iso_4217()
    differs |= report('ISO 4217 List One (currency_code)', version, url, data,
                      embedded_codes(sql, 'currency_code', r'[A-Z]{3}'), currencies)

    alpha2, alpha3, version, url, data = iso_3166(args.iso_codes_ref)
    differs |= report('ISO 3166-1 alpha-2 (country_code)', version, url, data,
                      embedded_codes(sql, 'country_code', r'[A-Z]{2}'), alpha2)
    differs |= report('ISO 3166-1 alpha-3 (country_code_alpha3)', version, url, data,
                      embedded_codes(sql, 'country_code_alpha3', r'[A-Z]{3}'), alpha3)

    languages, version, url, data = iso_639_1(args.iso_codes_ref)
    differs |= report('ISO 639-1 (language_code)', version, url, data,
                      embedded_codes(sql, 'language_code', r'[a-z]{2}'), languages)

    registry, version, url, data = iban_registry(args.iban_registry)
    embedded = embedded_iban(sql)
    differs |= report('SWIFT IBAN Registry (iban)', version, url, data,
                      sorted(embedded), sorted(registry))
    lengths = [f'{cc} {embedded[cc]} -> {registry[cc]["length"]}'
               for cc in sorted(set(embedded) & set(registry))
               if embedded[cc] != registry[cc]['length']]
    print(f'   lengths:  {", ".join(lengths) or "-"}')
    territories = [f'{cc}: {r["others"]}' for cc, r in sorted(registry.items())
                   if r['others'] and r['others'].upper() not in ('N/A', 'NA', 'NO')]
    print(f'   territories under another prefix (not separate prefixes): {"; ".join(territories) or "-"}')
    bad = [cc for cc, r in sorted(registry.items())
           if len(r['example']) != r['length'] or not r['example'].startswith(cc) or not mod97(r['example'])]
    print(f'   examples failing length or MOD 97: {" ".join(bad) or "-"}')
    differs |= bool(lengths)

    if args.sql:
        print('\n-- currency_code\n' + sql_literal(currencies))
        print('\n-- country_code\n' + sql_literal(alpha2))
        print('\n-- country_code_alpha3\n' + sql_literal(alpha3))
        print('\n-- language_code\n' + sql_literal(languages))
        print('\n-- iban\n' + sql_iban(registry))

    if args.examples:
        print('\n    -- SWIFT IBAN Registry: the electronic format example of every country')
        for cc in sorted(registry):
            r = registry[cc]
            print(f"    ('iban', '{r['example']}', true, 'registry example: {cc}, {r['length']}'),")

    print('\nall lists match their sources' if not differs else '\nlists differ from their sources')
    return 1 if differs else 0


if __name__ == '__main__':
    sys.exit(main())
