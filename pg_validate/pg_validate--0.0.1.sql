/*
 * pg_validate (installs into schema validate)
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Boolean validators for common string formats, for CHECK constraints:
 *
 *   create table users (
 *       email text check (validate.email(email))
 *   );
 *
 * plus a registry of named formats (validate.format(name, value)) that
 * includes every built-in validator and the custom validators an
 * application registers.
 *
 * Rules that every validator in this file follows:
 *
 *   - It checks structure and encoding only, never existence or
 *     authenticity: an email address can be undeliverable, a card number
 *     unissued, an IBAN unassigned.
 *   - It follows the cited specification (RFC, ISO standard or published
 *     grammar). Where it deliberately accepts less, the comment and
 *     docs/reference say so.
 *   - It is IMMUTABLE STRICT PARALLEL SAFE only because its result depends on
 *     its argument alone: no catalogs, no settings (TimeZone, DateStyle,
 *     lc_ctype), no casts to time types. Patterns use explicit ASCII ranges
 *     and no backslash escapes, so neither the collation nor
 *     standard_conforming_strings changes a result. A null argument returns
 *     null, which a CHECK constraint accepts.
 *   - Embedded code lists (ISO 3166, ISO 4217, ISO 639, the IBAN registry,
 *     the IANA IDNA tables) are snapshots; docs/reference/international.md,
 *     financial.md and internet.md name the snapshot, and data/README.md
 *     records the sources. data/refresh.py and data/refresh_idna.py compare
 *     the lists with their sources. Changing a list is a new extension
 *     version.
 *
 *   ./test/run.sh
 */

-- With CREATE EXTENSION, the control file (schema = validate) has already
-- created the schema. A plain install (psql -f) creates it here. No
-- "if not exists": in an extension script, that form errors on a schema the
-- extension does not own.
do $$
begin
    if pg_catalog.to_regnamespace('validate') is null then
        create schema validate;
    end if;
end;
$$;

comment on schema validate is
    'Validators for common string formats, and a registry of named formats.';

-- ============================================================================
-- Internal helpers
-- ============================================================================

-- Gregorian leap year (proleptic for years before 1582).
create function validate._is_leap(y int)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select (y % 4 = 0 and y % 100 <> 0) or y % 400 = 0
$$;

create function validate._days_in_month(y int, m int)
returns int
language sql immutable strict parallel safe
set search_path = ''
as $$
    select case
        when m in (1, 3, 5, 7, 8, 10, 12) then 31
        when m in (4, 6, 9, 11) then 30
        when m = 2 then case when validate._is_leap(y) then 29 else 28 end
    end
$$;

create function validate._valid_date(y int, m int, d int)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select coalesce(m between 1 and 12 and d between 1 and validate._days_in_month(y, m), false)
$$;

-- ISO weekday of a Gregorian date: 1 = Monday ... 7 = Sunday (Sakamoto's
-- method). 400 years is a whole number of weeks, so y + 400 keeps the
-- arithmetic positive for year 0000.
create function validate._iso_weekday(y int, m int, d int)
returns int
language sql immutable strict parallel safe
set search_path = ''
as $$
    with a as (select case when m < 3 then y + 399 else y + 400 end as yy)
    select ((a.yy + a.yy / 4 - a.yy / 100 + a.yy / 400
             + ('{0,3,2,5,0,3,5,1,4,6,2,4}'::int[])[m] + d) + 6) % 7 + 1
    from a
$$;

-- ISO 8601 week-numbering year: 53 weeks when 1 January is a Thursday, or a
-- Wednesday in a leap year; otherwise 52.
create function validate._iso_weeks_in_year(y int)
returns int
language sql immutable strict parallel safe
set search_path = ''
as $$
    select case
        when validate._iso_weekday(y, 1, 1) = 4 then 53
        when validate._iso_weekday(y, 1, 1) = 3 and validate._is_leap(y) then 53
        else 52
    end
$$;

-- ============================================================================
-- Identifiers
-- ============================================================================

-- RFC 9562 §4: the 8-4-4-4-12 hexadecimal string form, either case. Any
-- version and variant, including the Nil and Max UUIDs (§5.9, §5.10).
-- Unlike the uuid type's input function, braces, missing hyphens and other
-- groupings are rejected.
create function validate.uuid(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
$$;

-- The string form, the RFC 9562 variant (§4.1: 10xx, so 8, 9, a or b) and the
-- given version (§4.2: 1 to 8). The Nil and Max UUIDs have no version.
create function validate.uuid(value text, version int)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
begin
    if version not between 1 and 8 then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('invalid UUID version: %s', version),
            hint = 'RFC 9562 defines versions 1 to 8.';
    end if;
    return validate.uuid(value)
       and substr(value, 15, 1) = version::text
       and substr(value, 20, 1) in ('8', '9', 'a', 'b', 'A', 'B');
end;
$$;

-- ULID (https://github.com/ulid/spec): 26 characters of Crockford's Base32
-- (no I, L, O or U), either case. The first character is at most 7, because
-- 26 characters hold 130 bits and a ULID has 128.
create function validate.ulid(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$'
$$;

-- Nano ID (https://github.com/ai/nanoid) with its defaults: 21 characters of
-- the URL-safe alphabet A-Z a-z 0-9 _ -.
create function validate.nanoid(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[A-Za-z0-9_-]{21}$'
$$;

-- Nano ID with a custom size and alphabet (customAlphabet(alphabet, size)).
create function validate.nanoid(
    value text,
    size int,
    alphabet text default '_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
begin
    if size < 1 or alphabet = '' then
        raise exception using
            errcode = '22023',
            message = 'nanoid size must be at least 1 and the alphabet must not be empty';
    end if;
    -- translate() deletes every alphabet character; nothing may remain.
    return char_length(value) = size and translate(value, alphabet, '') = '';
end;
$$;

-- URL slug: lowercase ASCII letters and digits in groups joined by single
-- hyphens. No leading, trailing or doubled hyphen.
create function validate.slug(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
$$;

-- Semantic Versioning 2.0.0 (https://semver.org), the complete BNF: numeric
-- identifiers without leading zeros, dot-separated pre-release identifiers
-- (numeric ones without leading zeros) and build metadata. This is the
-- regular expression the specification recommends, with \d and \. written as
-- bracket expressions.
create function validate.semver(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ ('^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)'
                    '(-(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)([.](0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*)?'
                    '([+][0-9a-zA-Z-]+([.][0-9a-zA-Z-]+)*)?$')
$$;

-- A full git object name: 40 lowercase hex digits (SHA-1) or 64 (SHA-256,
-- git's object format sha256). Abbreviated names are rejected.
create function validate.git_sha(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
$$;

-- ============================================================================
-- Internet
-- ============================================================================

-- RFC 3986 §3.2.2 IPv4address: four dec-octets, no leading zeros.
create function validate.ipv4(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ ('^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
                    '([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$')
$$;

-- RFC 3986 §3.2.2 IPv6address (the text forms of RFC 4291 §2.2): eight h16
-- groups, at most one "::" for one or more zero groups, optionally ending in
-- an IPv4 address that counts as two groups. No zone identifier (RFC 6874)
-- and no prefix length.
create function validate.ipv6(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    dbl    int;
    pieces text[];
    tail   text[] := '{}';
    v4_ok  boolean;
    groups int := 0;
    n      int;
begin
    if value !~ '^[0-9A-Fa-f:.]+$' or strpos(value, ':::') > 0 then
        return false;
    end if;
    dbl := strpos(value, '::');
    if dbl > 0 then
        if strpos(substr(value, dbl + 2), '::') > 0 then
            return false;
        end if;
        pieces := case when dbl = 1 then '{}' else string_to_array(left(value, dbl - 1), ':') end;
        if dbl + 1 < char_length(value) then
            tail := string_to_array(substr(value, dbl + 2), ':');
        end if;
        -- An IPv4 tail is only allowed after the last group: "::1.2.3.4" but not "1.2.3.4::".
        v4_ok := cardinality(tail) > 0;
        pieces := pieces || tail;
    else
        pieces := string_to_array(value, ':');
        v4_ok := true;
    end if;
    n := cardinality(pieces);
    for i in 1 .. n loop
        if i = n and v4_ok and strpos(pieces[i], '.') > 0 then
            if not validate.ipv4(pieces[i]) then
                return false;
            end if;
            groups := groups + 2;
        elsif pieces[i] ~ '^[0-9A-Fa-f]{1,4}$' then
            groups := groups + 1;
        else
            return false;
        end if;
    end loop;
    return case when dbl > 0 then groups <= 7 else groups = 8 end;
end;
$$;

-- RFC 3492 §6.1 bias adaptation, with the Punycode parameters of §5
-- (base 36, tmin 1, tmax 26, skew 38, damp 700).
create function validate._punycode_adapt(delta bigint, numpoints int, firsttime boolean)
returns int
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    k int := 0;
begin
    delta := case when firsttime then delta / 700 else delta / 2 end;
    delta := delta + delta / numpoints;
    while delta > 455 loop
        delta := delta / 35;
        k := k + 36;
    end loop;
    return k + (36 * delta) / (delta + 38);
end;
$$;

-- RFC 3492 §6.2 Punycode decoding of the part of an A-label after "xn--":
-- the code points, or null when the input is not valid Punycode (a
-- non-basic character before the last delimiter, a character that is not a
-- digit, a truncated number, overflow, or a result that is a basic code
-- point, a surrogate or beyond U+10FFFF). Digits are case-insensitive.
create function validate._punycode_decode(input text)
returns int[]
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    len    int := char_length(input);
    output int[] := '{}';
    n      bigint := 128;
    i      bigint := 0;
    bias   int := 72;
    pos    int := 1;
    b      int := strpos(reverse(input), '-');
    oldi   bigint;
    w      bigint;
    k      int;
    t      int;
    c      int;
    digit  int;
    outlen int;
begin
    -- the basic code points: everything before the last delimiter
    if b > 0 then
        b := len - b + 1;
        for j in 1 .. b - 1 loop
            c := ascii(substr(input, j, 1));
            if c >= 128 then
                return null;
            end if;
            output := output || c;
        end loop;
        pos := b + 1;
    end if;
    while pos <= len loop
        oldi := i;
        w := 1;
        k := 36;
        loop
            if pos > len then
                return null;
            end if;
            c := ascii(substr(input, pos, 1));
            pos := pos + 1;
            digit := case when c between 48 and 57 then c - 22
                          when c between 65 and 90 then c - 65
                          when c between 97 and 122 then c - 97
                          else 36 end;
            if digit = 36 then
                return null;
            end if;
            i := i + digit * w;
            t := case when k <= bias then 1 when k >= bias + 26 then 26 else k - bias end;
            exit when digit < t;
            w := w * (36 - t);
            if i > 2147483647 or w > 2147483647 then
                return null;
            end if;
            k := k + 36;
        end loop;
        if i > 2147483647 then
            return null;
        end if;
        outlen := cardinality(output) + 1;
        bias := validate._punycode_adapt(i - oldi, outlen, oldi = 0);
        n := n + i / outlen;
        i := i % outlen;
        if n > 1114111 or n between 55296 and 57343 then
            return null;
        end if;
        output := output[1:i] || n::int || output[i + 1:];
        i := i + 1;
    end loop;
    return output;
end;
$$;

-- RFC 3492 §6.3 Punycode encoding of code points (lowercase digits), for
-- the round trip of an A-label and the length of a U-label's A-label.
create function validate._punycode_encode(input int[])
returns text
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    len   int := cardinality(input);
    output text := '';
    n     bigint := 128;
    delta bigint := 0;
    bias  int := 72;
    h     int;
    b     int;
    m     bigint;
    q     bigint;
    k     int;
    t     int;
    c     int;
    d     int;
begin
    foreach c in array input loop
        if c < 128 then
            output := output || chr(c);
        end if;
    end loop;
    b := char_length(output);
    h := b;
    if b > 0 then
        output := output || '-';
    end if;
    while h < len loop
        m := null;
        foreach c in array input loop
            if c >= n and (m is null or c < m) then
                m := c;
            end if;
        end loop;
        delta := delta + (m - n) * (h + 1);
        n := m;
        foreach c in array input loop
            if c < n then
                delta := delta + 1;
            end if;
            if c = n then
                q := delta;
                k := 36;
                loop
                    t := case when k <= bias then 1 when k >= bias + 26 then 26 else k - bias end;
                    exit when q < t;
                    d := t + (q - t) % (36 - t);
                    output := output || chr(case when d < 26 then 97 + d else 22 + d end);
                    q := (q - t) / (36 - t);
                    k := k + 36;
                end loop;
                output := output || chr(case when q < 26 then 97 + q::int else 22 + q::int end);
                bias := validate._punycode_adapt(delta, h + 1, h = b);
                delta := 0;
                h := h + 1;
            end if;
        end loop;
        delta := delta + 1;
        n := n + 1;
    end loop;
    return output;
end;
$$;

-- One label as code points against IDNA2008: returns the label's Bidi
-- classes (one character per code point) when the label is valid, or null.
--
--   RFC 5892    every code point PVALID, or CONTEXTJ / CONTEXTO with its
--               rule (Appendix A.1-A.9) satisfied
--   RFC 5891    §4.2.3.1 no hyphen first or last, not "--" in the third and
--               fourth positions; §4.2.3.2 no combining mark first
--
-- The caller lowercases ASCII (uppercase letters are not PVALID), checks
-- NFC and lengths, and applies the Bidi rule (RFC 5893), which depends on
-- the whole domain name. The table is IANA's derived properties for Unicode
-- 12.0.0, the latest IANA publishes: characters added in Unicode 13.0 or
-- later are UNASSIGNED there and rejected. data/README.md has the sources.
--
-- Bidi classes: L, R, A (AL), N (AN), E (EN), S (ES), C (CS), T (ET),
-- O (ON), B (BN), M (NSM).
create function validate._idna_label(cps int[])
returns text
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
-- BEGIN GENERATED IDNA TABLE by data/refresh_idna.py --sql
    -- IANA IDNA Parameters 12.0.0 and UCD 12.0.0. Code point ranges start at
    -- bounds[i] and have class classes[i]; "." is DISALLOWED or UNASSIGNED.
    bounds   constant int[] := '{0,45,46,48,58,97,123,183,184,223,247,248,256,257,258,259,260,261,262,'
        '263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,279,280,'
        '281,282,283,284,285,286,287,288,289,290,291,292,293,294,295,296,297,298,'
        '299,300,301,302,303,304,305,306,309,310,311,313,314,315,316,317,318,319,'
        '322,323,324,325,326,327,328,329,331,332,333,334,335,336,337,338,339,340,'
        '341,342,343,344,345,346,347,348,349,350,351,352,353,354,355,356,357,358,'
        '359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,'
        '378,379,380,381,382,383,384,385,387,388,389,390,392,393,396,398,402,403,'
        '405,406,409,412,414,415,417,418,419,420,421,422,424,425,426,428,429,430,'
        '432,433,436,437,438,439,441,444,445,452,462,463,464,465,466,467,468,469,'
        '470,471,472,473,474,475,476,478,479,480,481,482,483,484,485,486,487,488,'
        '489,490,491,492,493,494,495,497,501,502,505,506,507,508,509,510,511,512,'
        '513,514,515,516,517,518,519,520,521,522,523,524,525,526,527,528,529,530,'
        '531,532,533,534,535,536,537,538,539,540,541,542,543,544,545,546,547,548,'
        '549,550,551,552,553,554,555,556,557,558,559,560,561,562,563,570,572,573,'
        '575,577,578,579,583,584,585,586,587,588,589,590,591,688,697,699,706,710,'
        '720,722,748,749,750,751,768,832,834,835,838,847,848,880,881,882,883,884,'
        '885,886,887,888,891,894,912,913,940,975,983,984,985,986,987,988,989,990,'
        '991,992,993,994,995,996,997,998,999,1000,1001,1002,1003,1004,1005,1006,'
        '1007,1008,1011,1012,1016,1017,1019,1021,1072,1120,1121,1122,1123,1124,'
        '1125,1126,1127,1128,1129,1130,1131,1132,1133,1134,1135,1136,1137,1138,'
        '1139,1140,1141,1142,1143,1144,1145,1146,1147,1148,1149,1150,1151,1152,'
        '1153,1154,1155,1160,1163,1164,1165,1166,1167,1168,1169,1170,1171,1172,'
        '1173,1174,1175,1176,1177,1178,1179,1180,1181,1182,1183,1184,1185,1186,'
        '1187,1188,1189,1190,1191,1192,1193,1194,1195,1196,1197,1198,1199,1200,'
        '1201,1202,1203,1204,1205,1206,1207,1208,1209,1210,1211,1212,1213,1214,'
        '1215,1216,1218,1219,1220,1221,1222,1223,1224,1225,1226,1227,1228,1229,'
        '1230,1232,1233,1234,1235,1236,1237,1238,1239,1240,1241,1242,1243,1244,'
        '1245,1246,1247,1248,1249,1250,1251,1252,1253,1254,1255,1256,1257,1258,'
        '1259,1260,1261,1262,1263,1264,1265,1266,1267,1268,1269,1270,1271,1272,'
        '1273,1274,1275,1276,1277,1278,1279,1280,1281,1282,1283,1284,1285,1286,'
        '1287,1288,1289,1290,1291,1292,1293,1294,1295,1296,1297,1298,1299,1300,'
        '1301,1302,1303,1304,1305,1306,1307,1308,1309,1310,1311,1312,1313,1314,'
        '1315,1316,1317,1318,1319,1320,1321,1322,1323,1324,1325,1326,1327,1328,'
        '1369,1370,1376,1415,1416,1417,1425,1470,1471,1472,1473,1475,1476,1478,'
        '1479,1480,1488,1515,1519,1523,1525,1552,1563,1568,1569,1570,1574,1575,'
        '1576,1577,1578,1583,1587,1600,1601,1608,1609,1611,1632,1642,1646,1648,'
        '1649,1652,1653,1657,1672,1690,1728,1729,1731,1740,1741,1742,1743,1744,'
        '1746,1748,1749,1750,1757,1759,1765,1767,1769,1770,1774,1776,1786,1789,'
        '1791,1792,1808,1809,1810,1813,1818,1822,1823,1832,1833,1834,1835,1836,'
        '1837,1839,1840,1867,1869,1870,1881,1884,1899,1901,1905,1906,1907,1909,'
        '1912,1914,1920,1958,1969,1970,1984,1994,2027,2036,2038,2045,2046,2048,'
        '2070,2074,2075,2084,2085,2088,2089,2094,2112,2113,2118,2120,2121,2122,'
        '2132,2133,2134,2137,2140,2144,2145,2146,2150,2151,2152,2153,2155,2208,'
        '2218,2221,2222,2223,2225,2227,2229,2230,2233,2234,2238,2259,2274,2275,'
        '2307,2308,2362,2363,2364,2365,2366,2369,2377,2381,2382,2384,2385,2392,'
        '2400,2402,2404,2406,2416,2417,2433,2434,2436,2437,2445,2447,2449,2451,'
        '2473,2474,2481,2482,2483,2486,2490,2492,2493,2494,2497,2501,2503,2505,'
        '2507,2509,2510,2511,2519,2520,2528,2530,2532,2534,2546,2556,2557,2558,'
        '2559,2561,2563,2564,2565,2571,2575,2577,2579,2601,2602,2609,2610,2611,'
        '2613,2614,2616,2618,2620,2621,2622,2625,2627,2631,2633,2635,2637,2638,'
        '2641,2642,2652,2653,2662,2672,2674,2677,2678,2689,2691,2692,2693,2702,'
        '2703,2706,2707,2729,2730,2737,2738,2740,2741,2746,2748,2749,2750,2753,'
        '2758,2759,2761,2762,2763,2765,2766,2768,2769,2784,2786,2788,2790,2800,'
        '2809,2810,2816,2817,2818,2820,2821,2829,2831,2833,2835,2857,2858,2865,'
        '2866,2868,2869,2874,2876,2877,2878,2879,2880,2881,2885,2887,2889,2891,'
        '2893,2894,2902,2903,2904,2911,2914,2916,2918,2928,2929,2930,2946,2947,'
        '2948,2949,2955,2958,2961,2962,2966,2969,2971,2972,2973,2974,2976,2979,'
        '2981,2984,2987,2990,3002,3006,3008,3009,3011,3014,3017,3018,3021,3022,'
        '3024,3025,3031,3032,3046,3056,3072,3073,3076,3077,3085,3086,3089,3090,'
        '3113,3114,3130,3133,3134,3137,3141,3142,3145,3146,3149,3150,3157,3159,'
        '3160,3163,3168,3170,3172,3174,3184,3200,3201,3202,3204,3205,3213,3214,'
        '3217,3218,3241,3242,3252,3253,3258,3260,3261,3262,3263,3264,3269,3270,'
        '3271,3273,3274,3276,3277,3278,3285,3287,3294,3295,3296,3298,3300,3302,'
        '3312,3313,3315,3328,3330,3332,3333,3341,3342,3345,3346,3387,3389,3390,'
        '3393,3397,3398,3401,3402,3405,3406,3407,3412,3415,3416,3423,3426,3428,'
        '3430,3440,3450,3456,3458,3460,3461,3479,3482,3506,3507,3516,3517,3518,'
        '3520,3527,3530,3531,3535,3538,3541,3542,3543,3544,3552,3558,3568,3570,'
        '3572,3585,3633,3634,3635,3636,3642,3643,3648,3655,3663,3664,3674,3713,'
        '3715,3716,3717,3718,3723,3724,3748,3749,3750,3751,3761,3762,3763,3764,'
        '3770,3771,3773,3774,3776,3781,3782,3783,3784,3790,3792,3802,3806,3808,'
        '3840,3841,3851,3852,3864,3866,3872,3882,3893,3894,3895,3896,3897,3898,'
        '3902,3904,3907,3908,3912,3913,3917,3918,3922,3923,3927,3928,3932,3933,'
        '3945,3946,3949,3953,3955,3956,3957,3962,3967,3968,3969,3970,3972,3973,'
        '3974,3976,3981,3987,3988,3992,3993,3997,3998,4002,4003,4007,4008,4012,'
        '4013,4025,4026,4029,4038,4039,4096,4139,4141,4145,4146,4152,4153,4155,'
        '4157,4159,4170,4176,4182,4184,4186,4190,4193,4194,4197,4199,4206,4209,'
        '4213,4226,4227,4229,4231,4237,4238,4239,4240,4250,4253,4254,4304,4347,'
        '4349,4352,4608,4681,4682,4686,4688,4695,4696,4697,4698,4702,4704,4745,'
        '4746,4750,4752,4785,4786,4790,4792,4799,4800,4801,4802,4806,4808,4823,'
        '4824,4881,4882,4886,4888,4955,4957,4960,4992,5008,5024,5110,5121,5741,'
        '5743,5760,5761,5787,5792,5867,5873,5881,5888,5901,5902,5906,5908,5909,'
        '5920,5938,5940,5941,5952,5970,5972,5984,5997,5998,6001,6002,6004,6016,'
        '6068,6070,6071,6078,6086,6087,6089,6098,6099,6100,6103,6104,6108,6109,'
        '6110,6112,6122,6160,6170,6176,6265,6272,6277,6279,6313,6314,6315,6320,'
        '6390,6400,6431,6432,6435,6439,6441,6444,6448,6450,6451,6457,6460,6470,'
        '6510,6512,6517,6528,6572,6576,6602,6608,6618,6656,6679,6681,6683,6684,'
        '6688,6741,6742,6743,6744,6751,6752,6753,6754,6755,6757,6765,6771,6781,'
        '6783,6784,6794,6800,6810,6823,6824,6832,6846,6912,6916,6917,6964,6965,'
        '6966,6971,6972,6973,6978,6979,6980,6981,6988,6992,7002,7019,7028,7040,'
        '7042,7043,7073,7074,7078,7080,7082,7083,7084,7086,7142,7143,7144,7146,'
        '7149,7150,7151,7154,7156,7168,7204,7212,7220,7222,7224,7232,7242,7245,'
        '7294,7376,7379,7380,7393,7394,7401,7405,7406,7412,7413,7415,7416,7418,'
        '7419,7424,7462,7467,7468,7471,7472,7483,7484,7502,7503,7531,7544,7545,'
        '7579,7616,7674,7675,7680,7681,7682,7683,7684,7685,7686,7687,7688,7689,'
        '7690,7691,7692,7693,7694,7695,7696,7697,7698,7699,7700,7701,7702,7703,'
        '7704,7705,7706,7707,7708,7709,7710,7711,7712,7713,7714,7715,7716,7717,'
        '7718,7719,7720,7721,7722,7723,7724,7725,7726,7727,7728,7729,7730,7731,'
        '7732,7733,7734,7735,7736,7737,7738,7739,7740,7741,7742,7743,7744,7745,'
        '7746,7747,7748,7749,7750,7751,7752,7753,7754,7755,7756,7757,7758,7759,'
        '7760,7761,7762,7763,7764,7765,7766,7767,7768,7769,7770,7771,7772,7773,'
        '7774,7775,7776,7777,7778,7779,7780,7781,7782,7783,7784,7785,7786,7787,'
        '7788,7789,7790,7791,7792,7793,7794,7795,7796,7797,7798,7799,7800,7801,'
        '7802,7803,7804,7805,7806,7807,7808,7809,7810,7811,7812,7813,7814,7815,'
        '7816,7817,7818,7819,7820,7821,7822,7823,7824,7825,7826,7827,7828,7829,'
        '7834,7836,7838,7839,7840,7841,7842,7843,7844,7845,7846,7847,7848,7849,'
        '7850,7851,7852,7853,7854,7855,7856,7857,7858,7859,7860,7861,7862,7863,'
        '7864,7865,7866,7867,7868,7869,7870,7871,7872,7873,7874,7875,7876,7877,'
        '7878,7879,7880,7881,7882,7883,7884,7885,7886,7887,7888,7889,7890,7891,'
        '7892,7893,7894,7895,7896,7897,7898,7899,7900,7901,7902,7903,7904,7905,'
        '7906,7907,7908,7909,7910,7911,7912,7913,7914,7915,7916,7917,7918,7919,'
        '7920,7921,7922,7923,7924,7925,7926,7927,7928,7929,7930,7931,7932,7933,'
        '7934,7935,7936,7944,7952,7958,7968,7976,7984,7992,8000,8006,8016,8024,'
        '8032,8040,8048,8049,8050,8051,8052,8053,8054,8055,8056,8057,8058,8059,'
        '8060,8061,8112,8114,8118,8119,8134,8135,8144,8147,8150,8152,8160,8163,'
        '8164,8168,8182,8183,8204,8206,8526,8527,8580,8581,11312,11359,11361,'
        '11362,11365,11367,11368,11369,11370,11371,11372,11373,11377,11378,11379,'
        '11381,11382,11388,11393,11394,11395,11396,11397,11398,11399,11400,11401,'
        '11402,11403,11404,11405,11406,11407,11408,11409,11410,11411,11412,11413,'
        '11414,11415,11416,11417,11418,11419,11420,11421,11422,11423,11424,11425,'
        '11426,11427,11428,11429,11430,11431,11432,11433,11434,11435,11436,11437,'
        '11438,11439,11440,11441,11442,11443,11444,11445,11446,11447,11448,11449,'
        '11450,11451,11452,11453,11454,11455,11456,11457,11458,11459,11460,11461,'
        '11462,11463,11464,11465,11466,11467,11468,11469,11470,11471,11472,11473,'
        '11474,11475,11476,11477,11478,11479,11480,11481,11482,11483,11484,11485,'
        '11486,11487,11488,11489,11490,11491,11493,11500,11501,11502,11503,11506,'
        '11507,11508,11520,11558,11559,11560,11565,11566,11568,11624,11647,11648,'
        '11671,11680,11687,11688,11695,11696,11703,11704,11711,11712,11719,11720,'
        '11727,11728,11735,11736,11743,11744,11776,11823,11824,12293,12294,12295,'
        '12296,12330,12334,12348,12349,12353,12439,12441,12443,12445,12447,12449,'
        '12539,12540,12541,12543,12549,12592,12704,12731,12784,12800,13312,19894,'
        '19968,40944,40960,42125,42192,42238,42240,42509,42512,42540,42561,42562,'
        '42563,42564,42565,42566,42567,42568,42569,42570,42571,42572,42573,42574,'
        '42575,42576,42577,42578,42579,42580,42581,42582,42583,42584,42585,42586,'
        '42587,42588,42589,42590,42591,42592,42593,42594,42595,42596,42597,42598,'
        '42599,42600,42601,42602,42603,42604,42605,42607,42608,42612,42622,42623,'
        '42624,42625,42626,42627,42628,42629,42630,42631,42632,42633,42634,42635,'
        '42636,42637,42638,42639,42640,42641,42642,42643,42644,42645,42646,42647,'
        '42648,42649,42650,42651,42652,42654,42656,42726,42736,42738,42775,42784,'
        '42787,42788,42789,42790,42791,42792,42793,42794,42795,42796,42797,42798,'
        '42799,42802,42803,42804,42805,42806,42807,42808,42809,42810,42811,42812,'
        '42813,42814,42815,42816,42817,42818,42819,42820,42821,42822,42823,42824,'
        '42825,42826,42827,42828,42829,42830,42831,42832,42833,42834,42835,42836,'
        '42837,42838,42839,42840,42841,42842,42843,42844,42845,42846,42847,42848,'
        '42849,42850,42851,42852,42853,42854,42855,42856,42857,42858,42859,42860,'
        '42861,42862,42863,42864,42865,42873,42874,42875,42876,42877,42879,42880,'
        '42881,42882,42883,42884,42885,42886,42887,42888,42889,42892,42893,42894,'
        '42896,42897,42898,42899,42902,42903,42904,42905,42906,42907,42908,42909,'
        '42910,42911,42912,42913,42914,42915,42916,42917,42918,42919,42920,42921,'
        '42922,42927,42928,42933,42934,42935,42936,42937,42938,42939,42940,42941,'
        '42942,42943,42944,42947,42948,42999,43000,43002,43010,43011,43014,43015,'
        '43019,43020,43043,43045,43047,43048,43072,43122,43123,43124,43136,43138,'
        '43188,43204,43205,43206,43216,43226,43232,43250,43256,43259,43260,43261,'
        '43263,43264,43302,43310,43312,43335,43346,43347,43348,43392,43395,43396,'
        '43443,43444,43446,43450,43452,43454,43456,43457,43471,43482,43488,43493,'
        '43494,43519,43520,43561,43567,43569,43571,43573,43575,43584,43587,43588,'
        '43596,43597,43598,43600,43610,43616,43639,43642,43643,43644,43645,43646,'
        '43696,43697,43698,43701,43703,43705,43710,43712,43713,43714,43715,43739,'
        '43742,43744,43755,43756,43758,43760,43762,43765,43766,43767,43777,43783,'
        '43785,43791,43793,43799,43808,43815,43816,43823,43824,43867,43872,43877,'
        '43878,43880,43968,44003,44005,44006,44008,44009,44011,44012,44013,44014,'
        '44016,44026,44032,55204,64014,64016,64017,64018,64019,64021,64031,64032,'
        '64033,64034,64035,64037,64039,64042,64286,64287,65056,65072,65139,65140,'
        '65536,65548,65549,65575,65576,65595,65596,65598,65599,65614,65616,65630,'
        '65664,65787,66045,66046,66176,66205,66208,66257,66272,66273,66304,66336,'
        '66349,66369,66370,66378,66384,66422,66427,66432,66462,66464,66500,66504,'
        '66512,66600,66718,66720,66730,66776,66812,66816,66856,66864,66916,67072,'
        '67383,67392,67414,67424,67432,67584,67590,67592,67593,67594,67638,67639,'
        '67641,67644,67645,67647,67670,67680,67703,67712,67743,67808,67827,67828,'
        '67830,67840,67862,67872,67898,67968,68024,68030,68032,68096,68097,68100,'
        '68101,68103,68108,68112,68116,68117,68120,68121,68150,68152,68155,68159,'
        '68160,68192,68221,68224,68253,68288,68293,68294,68295,68296,68297,68299,'
        '68301,68302,68307,68311,68312,68317,68318,68321,68322,68324,68325,68327,'
        '68352,68406,68416,68438,68448,68467,68480,68481,68482,68483,68486,68489,'
        '68490,68492,68493,68494,68496,68497,68498,68608,68681,68800,68851,68864,'
        '68865,68898,68899,68900,68904,68912,68922,69376,69405,69415,69416,69424,'
        '69427,69428,69445,69446,69457,69600,69623,69632,69633,69634,69635,69688,'
        '69702,69703,69734,69744,69759,69760,69762,69763,69808,69811,69815,69817,'
        '69818,69819,69840,69865,69872,69882,69888,69891,69927,69932,69933,69939,'
        '69941,69942,69952,69956,69957,69959,69968,70003,70004,70006,70007,70016,'
        '70018,70019,70067,70070,70079,70080,70081,70085,70089,70093,70096,70107,'
        '70108,70109,70144,70162,70163,70188,70191,70194,70196,70197,70198,70200,'
        '70206,70207,70272,70279,70280,70281,70282,70286,70287,70302,70303,70313,'
        '70320,70367,70368,70371,70378,70379,70384,70394,70400,70402,70404,70405,'
        '70413,70415,70417,70419,70441,70442,70449,70450,70452,70453,70458,70459,'
        '70461,70462,70464,70465,70469,70471,70473,70475,70477,70478,70480,70481,'
        '70487,70488,70493,70498,70500,70502,70509,70512,70517,70656,70709,70712,'
        '70720,70722,70723,70725,70726,70727,70731,70736,70746,70750,70751,70752,'
        '70784,70832,70835,70841,70842,70843,70847,70849,70850,70851,70852,70854,'
        '70855,70856,70864,70874,71040,71087,71090,71094,71096,71100,71102,71103,'
        '71104,71105,71128,71132,71134,71168,71216,71219,71227,71229,71230,71231,'
        '71232,71233,71236,71237,71248,71258,71296,71339,71340,71341,71342,71344,'
        '71350,71351,71352,71353,71360,71370,71424,71451,71453,71456,71458,71462,'
        '71463,71467,71468,71472,71482,71680,71724,71727,71736,71737,71738,71739,'
        '71872,71914,71935,71936,72096,72104,72106,72145,72148,72152,72154,72156,'
        '72160,72161,72162,72163,72164,72165,72192,72193,72199,72201,72203,72243,'
        '72244,72245,72249,72250,72251,72255,72263,72264,72272,72273,72279,72281,'
        '72284,72330,72343,72344,72345,72346,72349,72350,72384,72441,72704,72713,'
        '72714,72751,72752,72759,72760,72766,72767,72768,72769,72784,72794,72818,'
        '72848,72850,72872,72873,72874,72881,72882,72884,72885,72887,72960,72967,'
        '72968,72970,72971,73009,73015,73018,73019,73020,73022,73023,73028,73030,'
        '73031,73032,73040,73050,73056,73062,73063,73065,73066,73098,73103,73104,'
        '73106,73107,73109,73110,73111,73112,73113,73120,73130,73440,73459,73461,'
        '73463,73728,74650,74880,75076,77824,78895,82944,83527,92160,92729,92736,'
        '92767,92768,92778,92880,92910,92912,92917,92928,92976,92983,92992,92996,'
        '93008,93018,93027,93048,93053,93072,93792,93824,93952,94027,94031,94032,'
        '94033,94088,94095,94099,94112,94176,94178,94179,94180,94208,100344,'
        '100352,101107,110592,110593,110879,110928,110931,110948,110952,110960,'
        '111356,113664,113771,113776,113789,113792,113801,113808,113818,113821,'
        '113823,121344,121399,121403,121453,121461,121462,121476,121477,121499,'
        '121504,121505,121520,122880,122887,122888,122905,122907,122914,122915,'
        '122917,122918,122923,123136,123181,123184,123191,123198,123200,123210,'
        '123214,123215,123584,123628,123632,123642,124928,125125,125136,125143,'
        '125218,125252,125259,125260,125264,125274,131072,173783,173824,177973,'
        '177984,178206,178208,183970,183984,191457}'::int[];
    classes  constant text := '.A.B.C.D.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.EC.'
        'EC.E.C.F.F.F.F.G.G.H.G.G.G.G.G.G.G.G.G.G.C.C.C.C.C.C.C.G.G.G.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.F.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.I.I.I.I.I.J.JK.F.LM'
        'NLNLNLNL.LNLFO.LFNM.LNLNLNLNLNLN.NF.FMF.FNPLML.NFLNLNLNLNLNLNF.NLNLNLNLN'
        'LNLMFM.QRFQ.F.QFQFQFQF.SRSRSRSRQF.LMLMNLN.LNMNLNL.LNL.F.FTCFTFCTFTUTCF.C'
        'F.C.CFT.C.C.C.C.C.C.FCTF.T.TUC.T.CF.C.C.F.FT.C.C.C.C.C.C.C.F.TF.F.FU.F.C'
        '.CFCF.FT.C.C.C.C.C.C.FCTF.FT.TU.C.CF.C.CF.FT.C.C.C.C.C.C.FCTFTF.T.TU.FT.'
        'CF.C.C.FC.C.C.C.C.C.C.C.C.C.TFT.T.TU.C.T.C.FTFC.C.C.C.CFT.F.FU.F.C.CF.C.'
        'CFT.C.C.C.C.C.FCTVT.VT.TFU.T.C.CF.C.C.FT.C.C.CUCTF.T.TUC.CT.CF.C.C.T.C.C'
        '.C.C.C.U.TF.F.T.C.T.CFC.FU.CF.C.C.C.C.C.C.CFC.FUFC.C.C.F.C.C.C.C.F.C.F.F'
        '.F.TC.C.C.C.C.C.C.C.F.F.FTF.FU.FCF.F.F.F.F.F.F.F.F.CTFTFTUTFC.CTFCFCTCTC'
        'FCFTFTFCTCTF.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.F.C.C.C.C.C.C.C.C.CFU.C'
        'FU.CF.C.C.F.C.TFTFTFUF.C.CF.C.C.W.CFWFW.C.C.FTFT.TFTF.C.C.C.C.C.CFTF.CTF'
        'TF.UTFTFTF.FC.C.C.F.FTCFTFTFTFTXC.C.F.FTCTFTFXUFCFTFTFTFX.CTFTF.C.C.F.FT'
        'FCFCFCTFC.CGC.C.C.C.C.C.F.F.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.'
        'C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.'
        'C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.'
        'C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.CG.G.G.G.G.G'
        '.G.G.G.G.G.G.G.G.G.G.G.G.G.G.G.G.Y.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.CF.C.C.C.C.C.UC.C.C.C.C.C.C.C.C.F.E.ZCZ.F.C.a.F.a.bDCb.C.'
        'C.b.Z.Z.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.CF.F.E.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.FC.F.E.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.'
        'C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.C.CE.C.C.C.C.C.C.C.C.C.C.C'
        '.C.C.C.C.C.C.C.C.C.C.C.C.CFCUCFCTFT.WcC.TCTUF.C.FC.C.CFCF.CFTX.FTCFTFTFT'
        'X.C.CFC.CFTFTF.CFCFT.C.C.CTFTCFCFCFCFCFC.C.CTFT.CTU.C.C.C.C.C.C.CGC.CTFT'
        'FT.TU.C.C.Z.Z.Z.Z.Z.Z.Z.I.F.M.C.C.C.C.C.C.C.F.C.C.F.C.C.C.CF.C.C.C.C.C.C'
        '.C.C.C.C.C.Q.Q.Q.Q.Q.Q.Q.Q.Q.Q.Q.Q.Q.Q.QF.F.FQ.Q.Q.F.U.Q.Q.RSQS.SQdSRdRS'
        'RSQSF.Q.Q.Q.RSRSRSRSRSRS.Q.Q.eLNLF.f.Q.Q.LNLMF.Q.TFTCFU.C.UFTCTFTUF.C.C.'
        'FCFTFU.C.CT.CF.C.FTCTFTXC.F.C.C.C.CTFTFXF.F.C.C.C.C.C.CFTFU.C.FT.C.C.C.C'
        '.C.C.FCTFT.T.TX.C.T.CT.F.F.CTFTUFTFC.C.FC.CTFTFTFTUFC.C.C.CTF.TFTUF.CF.C'
        'TFTFTUF.C.C.CFTFTFXFC.C.C.FTFTFU.C.CTFTUF.C.C.C.CTF.FTUC.CT.CFVFCFUFTCF.'
        'U.CFTFCFTFU.C.C.C.CTF.FTgC.C.C.F.TFTFTF.C.C.CF.F.F.FUCF.C.C.C.CT.F.TFTUC'
        '.C.CFT.C.C.C.C.C.C.C.C.F.CF.C.C.C.C.C.C.FCT.FC.C.C.C.C.ba.a.b.C.C.C.C.C.'
        'F.F.F.F.F.F.F.F.F.F.F.F.C.FC.C.C.CFC.Q.F.RFh.Q.Z.Z.Z.Z.Z.';
    -- One character per class, in the order of alphabet.
    alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh';
    l_prop   constant text := 'PPPOPPPOPPOPPPOOPPPPPPPPJPPPPPPPPP'; -- P PVALID, J CONTEXTJ, O CONTEXTO
    l_bidi   constant text := 'SELOOMLOMRRAAANERRRLMLLLBLLLLRANLR'; -- Bidi_Class, see below
    l_mark   constant text := '-----M--M----------MMM-M--------M-'; -- M General_Category Mn, Mc, Me
    l_virama constant text := '--------------------V--V--------V-'; -- V Canonical_Combining_Class Virama
    l_join   constant text := 'UUUUUTUUTUUDURUUUDRUTTDUUUUULLLUTT'; -- Joining_Type L, D, R, T, else U
    l_script constant text := '------GGHHH--------------CIK------'; -- G Greek, H Hebrew, I Hiragana, K Katakana, C Han
-- END GENERATED IDNA TABLE
    n       int := cardinality(cps);
    cls     text := '';
    c       int;
    has_ai  boolean := false;
    has_eai boolean := false;
    prop    text;
    script  text;
    joining text;
    virama  text;
    ok      boolean;
begin
    if n = 0 then
        return null;
    end if;
    foreach c in array cps loop
        cls := cls || substr(classes, width_bucket(c, bounds), 1);
        has_ai := has_ai or c between 1632 and 1641;
        has_eai := has_eai or c between 1776 and 1785;
    end loop;
    if strpos(cls, '.') > 0 then
        return null;
    end if;
    if cps[1] = 45 or cps[n] = 45 or (n >= 4 and cps[3] = 45 and cps[4] = 45) then
        return null;
    end if;
    if translate(left(cls, 1), alphabet, l_mark) = 'M' then
        return null;
    end if;
    prop := translate(cls, alphabet, l_prop);
    if strpos(prop, 'J') > 0 or strpos(prop, 'O') > 0 then
        script := translate(cls, alphabet, l_script);
        joining := translate(cls, alphabet, l_join);
        virama := translate(cls, alphabet, l_virama);
        for p in 1 .. n loop
            continue when substr(prop, p, 1) = 'P';
            c := cps[p];
            ok := case
                -- A.1 ZERO WIDTH NON-JOINER: after a virama, or between joining characters
                when c = 8204 then (p > 1 and substr(virama, p - 1, 1) = 'V')
                                   or (left(joining, p - 1) ~ '[LD]T*$' and substr(joining, p + 1) ~ '^T*[RD]')
                -- A.2 ZERO WIDTH JOINER: after a virama
                when c = 8205 then p > 1 and substr(virama, p - 1, 1) = 'V'
                -- A.3 MIDDLE DOT: between two "l"
                when c = 183 then p > 1 and p < n and cps[p - 1] = 108 and cps[p + 1] = 108
                -- A.4 GREEK LOWER NUMERAL SIGN (KERAIA): followed by Greek
                when c = 885 then p < n and substr(script, p + 1, 1) = 'G'
                -- A.5, A.6 HEBREW GERESH and GERSHAYIM: preceded by Hebrew
                when c in (1523, 1524) then p > 1 and substr(script, p - 1, 1) = 'H'
                -- A.7 KATAKANA MIDDLE DOT: with Hiragana, Katakana or Han in the label
                when c = 12539 then script ~ '[IKC]'
                -- A.8, A.9 the two Arabic-Indic digit sets do not mix
                when c between 1632 and 1641 then not has_eai
                when c between 1776 and 1785 then not has_ai
                else false
            end;
            if not ok then
                return null;
            end if;
        end loop;
    end if;
    return translate(cls, alphabet, l_bidi);
end;
$$;

-- A host name against IDNA2008, for hostname (mapped false: value is an
-- RFC 1123 host name already; its xn-- labels are checked) and idn_hostname
-- (mapped true: value is mapped first).
--
--   mapping   (idn_hostname only) a subset of UTS #46 §4.1: remove the
--             code points UTS #46 ignores, NFKC (full-width forms, the
--             full-width and halfwidth full stops), the ideographic full
--             stop U+3002 as ".", ASCII lowercase
--   A-label   "xn--" (either case) and Punycode that decodes (RFC 3492),
--             re-encodes to the same text, contains a non-ASCII code point,
--             is NFC, and is a valid U-label (_idna_label)
--   U-label   a valid label (_idna_label) whose A-label is at most 63 octets
--   ASCII     letters, digits and hyphens, 1 to 63, no hyphen first or last;
--             for idn_hostname also not "--" in the third and fourth
--             positions unless it is an A-label (RFC 5890 §2.3.1)
--   name      at most 253 octets in A-label form
--   Bidi      RFC 5893 §2 rules 1-6 for every label, when any label has a
--             right-to-left character (R, AL or AN)
--
-- The NFC check of A-labels needs a UTF8 database; elsewhere it is skipped.
-- Mapping non-ASCII input needs a UTF8 database (normalize raises).
create function validate._idna_hostname(value text, mapped boolean)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
-- BEGIN GENERATED UTS46 IGNORED by data/refresh_idna.py --sql
    -- UTS #46 12.0.0 IdnaMappingTable, status "ignored"
    ignored constant text := '[' || chr(173) || chr(847) || chr(6155) || '-' || chr(6157) ||
        chr(8203) || chr(8288) || chr(8292) || chr(65024) || '-' ||
        chr(65039) || chr(65279) || chr(113824) || '-' ||
        chr(113827) || chr(917760) || '-' || chr(917999) || ']';
-- END GENERATED UTS46 IGNORED
    lab    text;
    low    text;
    cps    int[];
    u      text;
    bidi   text;
    bidis  text[] := '{}';
    rtl    boolean := false;
    total  int := 0;
    alen   int;
    utf8   boolean := pg_catalog.getdatabaseencoding() = 'UTF8';
    upper_ constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    lower_ constant text := 'abcdefghijklmnopqrstuvwxyz';
begin
    if mapped then
        if value ~ ('[^' || chr(1) || '-' || chr(127) || ']') then
            value := regexp_replace(value, ignored, '', 'g');
            value := pg_catalog.normalize(value, 'NFKC');
            value := replace(value, chr(12290), '.');
        end if;
        value := translate(value, upper_, lower_);
    end if;
    foreach lab in array string_to_array(value, '.') loop
        if lab = '' then
            return false;
        end if;
        if lab ~ ('^[' || chr(1) || '-' || chr(127) || ']+$') then
            low := translate(lab, upper_, lower_);
            if left(low, 4) = 'xn--' then
                if char_length(lab) > 63 or low !~ '^[a-z0-9-]+$' or right(low, 1) = '-' then
                    return false;
                end if;
                cps := validate._punycode_decode(substr(low, 5));
                if cps is null or not exists (select 1 from unnest(cps) x where x > 127)
                   or validate._punycode_encode(cps) <> substr(low, 5) then
                    return false;
                end if;
                if utf8 then
                    u := array_to_string(array(select chr(x) from unnest(cps) with ordinality o(x, k) order by k), '');
                    if not pg_catalog.is_normalized(u, 'NFC') then
                        return false;
                    end if;
                end if;
                bidi := validate._idna_label(cps);
                if bidi is null then
                    return false;
                end if;
            elsif not mapped then
                -- hostname: RFC 1123 labels, checked by the caller
                bidi := translate(low, lower_ || '0123456789-', repeat('L', 26) || repeat('E', 10) || 'S');
            else
                if char_length(lab) > 63 or low !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' or substr(low, 3, 2) = '--' then
                    return false;
                end if;
                bidi := translate(low, lower_ || '0123456789-', repeat('L', 26) || repeat('E', 10) || 'S');
            end if;
            alen := char_length(lab);
        else
            cps := array(select ascii(x) from regexp_split_to_table(lab, '') with ordinality o(x, k) order by k);
            bidi := validate._idna_label(cps);
            if bidi is null then
                return false;
            end if;
            alen := 4 + char_length(validate._punycode_encode(cps));
            if alen > 63 then
                return false;
            end if;
        end if;
        total := total + alen + 1;
        bidis := bidis || bidi;
        rtl := rtl or bidi ~ '[RAN]';
    end loop;
    if total - 1 > 253 then
        return false;
    end if;
    -- RFC 5893 §2: in a Bidi domain name, every label satisfies the Bidi rule
    if rtl then
        foreach bidi in array bidis loop
            if left(bidi, 1) in ('R', 'A') then
                -- rules 2-4: right-to-left label
                if bidi !~ '^[RANESCTOBM]+$' or bidi !~ '[RAEN]M*$'
                   or (strpos(bidi, 'E') > 0 and strpos(bidi, 'N') > 0) then
                    return false;
                end if;
            elsif left(bidi, 1) = 'L' then
                -- rules 5-6: left-to-right label
                if bidi !~ '^[LESCTOBM]+$' or bidi !~ '[LE]M*$' then
                    return false;
                end if;
            else
                -- rule 1: a label starts with L, R or AL
                return false;
            end if;
        end loop;
    end if;
    return true;
end;
$$;

-- Host name, RFC 1123 §2.1 (relaxing RFC 952): dot-separated labels of
-- letters, digits and hyphens, 1 to 63 characters each (RFC 1035 §2.3.4),
-- starting and ending with a letter or digit; at most 253 characters in
-- total (255 octets on the wire). Either case. A single label is a valid
-- host name. No trailing dot, no underscore, ASCII only (convert IDNs to
-- A-labels, xn--..., first, or use validate.idn_hostname). A label that
-- starts with "xn--" (either case) must be a valid IDNA2008 A-label
-- (RFC 5891 §5.4, see validate._idna_hostname), and the Bidi rule (RFC 5893)
-- applies when an A-label holds right-to-left characters.
create function validate.hostname(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select octet_length(value) <= 253
       and value ~ '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
       and (strpos(translate(value, 'XN', 'xn'), 'xn--') = 0 or validate._idna_hostname(value, false))
$$;

-- A registered-style domain name: a host name with at least two labels whose
-- last label (the top-level domain) is alphabetic, or an IDN A-label
-- (xn--...). RFC 3696 §2: top-level domains are never all-numeric, so
-- 192.168.0.1 is not a domain.
create function validate.domain(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate.hostname(value)
       and strpos(value, '.') > 0
       and value ~ '[.]([A-Za-z]{2,63}|[Xx][Nn]--[A-Za-z0-9-]{1,59})$'
$$;

-- Internationalized host name: RFC 5890 §2.3.2.3, labels that are U-labels,
-- A-labels or ASCII letter-digit-hyphen labels, checked against IDNA2008
-- (RFC 5891 §5.4, RFC 5892 with the IANA tables for Unicode 12.0.0,
-- RFC 5893 Bidi rule) after a subset of the UTS #46 mapping. See
-- validate._idna_hostname for the exact rules. Separators may be ".",
-- U+3002, U+FF0E or U+FF61. No trailing dot; at most 63 octets per label
-- and 253 for the name, both in A-label form.
--
-- Not done: the UTS #46 mapping beyond NFKC, removal of ignored code points
-- and ASCII lowercase. Uppercase non-ASCII letters (É), which UTS #46 would
-- lowercase, are DISALLOWED and rejected; so are characters that UTS #46
-- maps to other strings and NFKC does not. Characters added in Unicode 13.0
-- or later are rejected (UNASSIGNED in the IANA 12.0.0 tables). Needs a UTF8
-- database for non-ASCII input.
create function validate.idn_hostname(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value <> '' and validate._idna_hostname(value, true)
$$;

-- Email address syntax: an RFC 5322 §3.4.1 addr-spec restricted to the forms
-- that RFC 5321 (SMTP) can carry.
--
--   local-part  RFC 5321 §4.1.2 Dot-string (RFC 5322 dot-atom) or
--               Quoted-string ("john doe"), at most 64 octets (§4.5.3.1.1)
--   domain      RFC 5321 §4.1.2 Domain (host name labels, a single label is
--               allowed) or an address literal (§4.1.3): [192.0.2.1] or
--               [IPv6:2001:db8::1]
--   total       at most 254 octets (§4.5.3.1.3 path limit of 256, less the
--               angle brackets; RFC 3696 erratum 1690)
--
-- Not accepted: comments and folding white space (CFWS), obsolete syntax,
-- general address literals, and non-ASCII addresses (RFC 6531 SMTPUTF8).
-- Syntax only: it does not check that the domain exists or accepts mail.
create function validate.email(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    at     int;
    lpart  text;
    dpart  text;
    m      text[];
begin
    -- printable ASCII only: no spaces outside quotes, no controls, no UTF-8
    if octet_length(value) > 254 or value ~ '[^ -~]' or strpos(value, '@') = 0 then
        return false;
    end if;
    -- the domain never contains '@'; a quoted local part may
    at := char_length(value) - strpos(reverse(value), '@') + 1;
    lpart := left(value, at - 1);
    dpart := substr(value, at + 1);

    if octet_length(lpart) not between 1 and 64 then
        return false;
    end if;
    -- atext (RFC 5322 §3.2.3) separated by single dots, or a quoted string
    -- of qtextSMTP and quoted-pairSMTP (RFC 5321 §4.1.2)
    if not (lpart ~ '^[A-Za-z0-9!#$%&''*+/=?^_`{|}~-]+([.][A-Za-z0-9!#$%&''*+/=?^_`{|}~-]+)*$'
            or lpart ~ ('^"([]-~ !#-[]|' || chr(92) || chr(92) || '[ -~])*"$')) then
        return false;
    end if;

    if left(dpart, 1) = '[' then
        m := regexp_match(dpart, '^[[][Ii][Pp][Vv]6:(.*)[]]$');
        if m is not null then
            return validate.ipv6(m[1]);
        end if;
        m := regexp_match(dpart, '^[[](.*)[]]$');
        return m is not null and validate.ipv4(m[1]);
    end if;
    return validate.hostname(dpart);
end;
$$;

-- Internationalized email address syntax: RFC 6531 §3.3, which extends the
-- addr-spec of validate.email with UTF-8 (RFC 6532 §3.2 UTF8-non-ascii, any
-- code point from U+0080) in atext and in quoted strings, and with
-- internationalized domain names.
--
--   local-part  Dot-string or Quoted-string, atext / qtextSMTP plus any
--               non-ASCII character, at most 64 octets of UTF-8
--   domain      validate.idn_hostname (U-labels, A-labels or ASCII labels,
--               after its mapping), or an address literal as in
--               validate.email
--   total       at most 254 octets of UTF-8
--
-- An ASCII address is valid here exactly when validate.email accepts it,
-- except that the domain goes through idn_hostname (which, for example,
-- rejects R-LDH labels such as "ab--c" that hostname accepts). Not checked:
-- whether the local part is NFC (RFC 6532 §3.1 is a SHOULD) and anything
-- about deliverability or SMTPUTF8 support. Needs a UTF8 database for
-- non-ASCII input.
create function validate.idn_email(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    nonascii constant text := '[^' || chr(1) || '-' || chr(127) || ']';
    atext    constant text := '([A-Za-z0-9!#$%&''*+/=?^_`{|}~-]|' || nonascii || ')';
    at       int;
    lpart    text;
    dpart    text;
    m        text[];
begin
    -- no ASCII controls or DEL; no space outside a quoted local part
    if octet_length(value) > 254 or strpos(value, '@') = 0
       or value ~ ('[' || chr(1) || '-' || chr(31) || chr(127) || ']') then
        return false;
    end if;
    at := char_length(value) - strpos(reverse(value), '@') + 1;
    lpart := left(value, at - 1);
    dpart := substr(value, at + 1);
    if octet_length(lpart) not between 1 and 64 then
        return false;
    end if;
    if not (lpart ~ ('^' || atext || '+([.]' || atext || '+)*$')
            or lpart ~ ('^"([]-~ !#-[]|' || nonascii || '|' || chr(92) || chr(92) || '[ -~])*"$')) then
        return false;
    end if;
    if left(dpart, 1) = '[' then
        m := regexp_match(dpart, '^[[][Ii][Pp][Vv]6:(.*)[]]$');
        if m is not null then
            return validate.ipv6(m[1]);
        end if;
        m := regexp_match(dpart, '^[[](.*)[]]$');
        return m is not null and validate.ipv4(m[1]);
    end if;
    return validate.idn_hostname(dpart);
end;
$$;

-- RFC 3987 §2.2 ucschar and, when private, iprivate, as one bracket
-- expression of code point ranges. Needs a UTF8 database (chr above 255).
create function validate._iri_chars(private boolean)
returns text
language sql immutable strict parallel safe
set search_path = ''
as $$
    select '[' || chr(160) || '-' || chr(55295) || chr(63744) || '-' || chr(64975)
        || chr(65008) || '-' || chr(65519)
        || (select string_agg(chr(p * 65536) || '-' || chr(p * 65536 + 65533), '' order by p)
            from generate_series(1, 13) p)
        || chr(921600) || '-' || chr(983037)
        || case when private
                then chr(57344) || '-' || chr(63743) || chr(983040) || '-' || chr(1048573)
                     || chr(1048576) || '-' || chr(1114109)
                else '' end
        || ']'
$$;

-- RFC 3986 parser shared by uri, uri_reference, url, iri and
-- iri_reference. kind is 'uri' (§3 URI: scheme required), 'reference'
-- (§4.1 URI-reference: a URI or a relative reference), 'url' (an http or
-- https URI, see validate.url), 'iri' or 'iri-reference' (RFC 3987 §2.2: the
-- same grammar with ucschar wherever unreserved is allowed, and iprivate in
-- the query; both become "~" before the URI rules run, which keeps them out
-- of the scheme, IP literals and the port).
create function validate._uri(value text, kind text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    -- §2: pchar = unreserved / pct-encoded / sub-delims / ":" / "@"
    pchar     constant text := '([A-Za-z0-9._~!$&''()*+,;=:@-]|%[0-9A-Fa-f]{2})';
    -- segment-nz-nc (§3.3): pchar without ":"
    pchar_nc  constant text := '([A-Za-z0-9._~!$&''()*+,;=@-]|%[0-9A-Fa-f]{2})';
    m         text[];
    scheme    text;
    authority text;
    path      text;
    query     text;
    fragment  text;
    is_url    boolean := kind = 'url';
    at        int;
    hostport  text;
    host      text;
    port      text;
    pos       int;
begin
    if kind in ('iri', 'iri-reference') then
        if value ~ ('[^' || chr(1) || '-' || chr(127) || ']') then
            m := regexp_match(value, '^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)([?]([^#]*))?(#(.*))?$');
            -- RFC 3987 §2.2: iprivate only in iquery
            if concat(m[1], m[3], m[5], m[8]) ~ ('[' || chr(57344) || '-' || chr(63743) || chr(983040) || '-'
                                                   || chr(1048573) || chr(1048576) || '-' || chr(1114109) || ']') then
                return false;
            end if;
            value := regexp_replace(value, validate._iri_chars(true), '~', 'g');
        end if;
        kind := case kind when 'iri' then 'uri' else 'reference' end;
    end if;
    -- §2: a URI is ASCII; space and controls never appear unencoded
    if value ~ '[^!-~]' then
        return false;
    end if;
    -- Appendix B: split into the five components
    m := regexp_match(value, '^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)([?]([^#]*))?(#(.*))?$');
    scheme := m[2];
    authority := m[4];
    path := m[5];
    query := m[7];
    fragment := m[9];

    -- §3.1 scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    if scheme is null then
        if kind <> 'reference' then
            return false;
        end if;
    elsif scheme !~ '^[A-Za-z][A-Za-z0-9+.-]*$' then
        return false;
    end if;
    if is_url and (scheme !~ '^[Hh][Tt][Tt][Pp][Ss]?$' or m[3] is null) then
        return false;
    end if;

    -- §3.4 query, §3.5 fragment = *( pchar / "/" / "?" )
    if query is not null and query !~ ('^(' || pchar || '|[/?])*$') then
        return false;
    end if;
    if fragment is not null and fragment !~ ('^(' || pchar || '|[/?])*$') then
        return false;
    end if;

    if m[3] is not null then
        -- §3.2 authority = [ userinfo "@" ] host [ ":" port ]
        at := strpos(authority, '@');
        if at > 0 then
            -- RFC 9110 §4.2.4: http(s) URIs must not carry userinfo
            if is_url or left(authority, at - 1) !~ '^([A-Za-z0-9._~!$&''()*+,;=:-]|%[0-9A-Fa-f]{2})*$' then
                return false;
            end if;
            hostport := substr(authority, at + 1);
        else
            hostport := authority;
        end if;

        if left(hostport, 1) = '[' then
            -- §3.2.2 IP-literal = "[" ( IPv6address / IPvFuture ) "]"
            pos := strpos(hostport, ']');
            if pos = 0 then
                return false;
            end if;
            host := substr(hostport, 2, pos - 2);
            port := substr(hostport, pos + 1);
            if port <> '' then
                if left(port, 1) <> ':' then
                    return false;
                end if;
                port := substr(port, 2);
            else
                port := null;
            end if;
            if not (validate.ipv6(host)
                    or (not is_url and host ~ '^[Vv][0-9A-Fa-f]+[.][A-Za-z0-9._~!$&''()*+,;=:-]+$')) then
                return false;
            end if;
        else
            pos := strpos(hostport, ':');
            if pos > 0 then
                host := left(hostport, pos - 1);
                port := substr(hostport, pos + 1);
            else
                host := hostport;
                port := null;
            end if;
            if is_url then
                -- a DNS name (one trailing dot allowed) or an IPv4 address
                if host ~ '^[0-9.]+$' then
                    if not validate.ipv4(host) then
                        return false;
                    end if;
                elsif not validate.hostname(case when right(host, 1) = '.' then left(host, -1) else host end) then
                    return false;
                end if;
            elsif host !~ '^([A-Za-z0-9._~!$&''()*+,;=-]|%[0-9A-Fa-f]{2})*$' then
                -- §3.2.2 reg-name (IPv4address is a subset of it)
                return false;
            end if;
        end if;

        -- §3.2.3 port = *DIGIT; url: 0 to 65535 and not empty
        if port is not null then
            if is_url then
                if port !~ '^[0-9]{1,5}$' or port::int > 65535 then
                    return false;
                end if;
            elsif port !~ '^[0-9]*$' then
                return false;
            end if;
        end if;

        -- §3.3 path-abempty
        return path ~ ('^(/' || pchar || '*)*$');
    elsif scheme is not null then
        -- path-absolute / path-rootless / path-empty
        return path ~ ('^/?(' || pchar || '+(/' || pchar || '*)*)?$');
    else
        -- §4.2 relative-part without authority: path-absolute / path-noscheme / path-empty
        return path ~ ('^(/(' || pchar || '+(/' || pchar || '*)*)?|' || pchar_nc || '+(/' || pchar || '*)*)?$');
    end if;
end;
$$;

-- RFC 3986 §3 URI: any scheme, with or without an authority, with an
-- optional query and fragment. ASCII only (IRIs, RFC 3987, are not URIs).
create function validate.uri(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._uri(value, 'uri')
$$;

-- RFC 3986 §4.1 URI-reference: a URI or a relative reference such as
-- "../a?b#c", "//example.com/x" or "" (the empty string).
create function validate.uri_reference(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._uri(value, 'reference')
$$;

-- RFC 3987 §2.2 IRI: a URI (validate.uri) in which unreserved characters
-- may also be ucschar (U+00A0 to U+D7FF, U+F900 to U+FDCF, U+FDF0 to U+FFEF,
-- and the planes 1 to 14 without their last two code points and the start
-- of plane 14), and the query may also hold iprivate (U+E000 to U+F8FF,
-- planes 15 and 16). The scheme, IP literals and the port stay ASCII. Not
-- checked: the bidirectional rules of §4.1 (a SHOULD) and IDNA for the host.
create function validate.iri(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._uri(value, 'iri')
$$;

-- RFC 3987 §2.2 IRI-reference: an IRI or a relative reference with the
-- same character rules, such as "/âππ" or "#ƒrägmênt".
create function validate.iri_reference(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._uri(value, 'iri-reference')
$$;

-- An absolute http or https URL (RFC 3986 §3 with RFC 9110 §4.2): scheme
-- http or https (either case), an authority whose host is a DNS host name
-- (RFC 1123, optional trailing dot), an IPv4 address or a bracketed IPv6
-- address, an optional port 0 to 65535, no userinfo (RFC 9110 §4.2.4), then
-- an RFC 3986 path, query and fragment.
create function validate.url(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._uri(value, 'url')
$$;

-- IEEE 802 MAC-48 / EUI-48 address: six pairs of hex digits separated by
-- colons or by hyphens (the IEEE canonical form), consistently. Either case.
create function validate.mac(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'
        or value ~ '^[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}$'
$$;

-- A TCP or UDP port number in decimal, 1 to 65535, without leading zeros or
-- sign. Port 0 is reserved (RFC 6335 §6) and rejected.
create function validate.port(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select case when value ~ '^[1-9][0-9]{0,4}$' then value::int <= 65535 else false end
$$;

-- ============================================================================
-- Dates and times
-- ============================================================================
--
-- Pure arithmetic on the digits: no cast to date or timestamptz, so the
-- result never depends on DateStyle, TimeZone or the time zone database.
-- Leap seconds (second 60) are allowed where the grammar allows them; they
-- are not checked against the published leap second table.

-- RFC 3339 §5.6. kind is 'date-time', 'date' (full-date) or 'time'
-- (full-time, which includes the offset).
create function validate._rfc3339(value text, kind text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    m    text[];
    hh   int;
    mi   int;
    ss   int;
    utc  int;
begin
    if kind = 'date' then
        m := regexp_match(value, '^([0-9]{4})-([0-9]{2})-([0-9]{2})$');
        return m is not null and validate._valid_date(m[1]::int, m[2]::int, m[3]::int);
    end if;

    -- full-time = time-hour ":" time-minute ":" time-second [time-secfrac] time-offset
    if kind = 'date-time' then
        -- §5.6 note: "T" and "Z" may be lowercase
        m := regexp_match(value, '^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt](.*)$');
        if m is null or not validate._valid_date(m[1]::int, m[2]::int, m[3]::int) then
            return false;
        end if;
        value := m[4];
    end if;
    m := regexp_match(value, '^([0-9]{2}):([0-9]{2}):([0-9]{2})([.][0-9]+)?([Zz]|([+-])([0-9]{2}):([0-9]{2}))$');
    if m is null then
        return false;
    end if;
    hh := m[1]::int;
    mi := m[2]::int;
    ss := m[3]::int;
    if hh > 23 or mi > 59 or ss > 60 then
        return false;
    end if;
    if m[6] is not null and (m[7]::int > 23 or m[8]::int > 59) then
        return false;
    end if;
    -- §5.7: second 60 is a leap second, which happens at 23:59:60 UTC
    if ss = 60 then
        utc := hh * 60 + mi;
        if m[6] = '+' then
            utc := utc - (m[7]::int * 60 + m[8]::int);
        elsif m[6] = '-' then
            utc := utc + (m[7]::int * 60 + m[8]::int);
        end if;
        return (utc + 1440) % 1440 = 23 * 60 + 59;
    end if;
    return true;
end;
$$;

-- RFC 3339 §5.6 date-time, for example 1985-04-12T23:20:50.52Z.
create function validate.rfc3339(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._rfc3339(value, 'date-time')
$$;

-- RFC 3339 §5.6 full-date, for example 1985-04-12.
create function validate.rfc3339_date(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._rfc3339(value, 'date')
$$;

-- RFC 3339 §5.6 full-time, with its offset, for example 23:20:50.52Z.
create function validate.rfc3339_time(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate._rfc3339(value, 'time')
$$;

-- ISO 8601-1:2019 date or date and time, in this profile:
--
--   dates   calendar YYYY-MM-DD / YYYYMMDD, ordinal YYYY-DDD / YYYYDDD,
--           week YYYY-Www-D / YYYYWwwD; reduced precision YYYY-MM, YYYY,
--           YYYY-Www / YYYYWww (date alone only)
--   times   after "T": hh:mm:ss / hhmmss, hh:mm / hhmm, hh, with a decimal
--           fraction (. or ,) on the last component; 24:00[:00] for end of
--           day; zone Z, +hh, +hh:mm / +hhmm
--   rules   date and time both basic or both extended; four-digit years
--           0000 to 9999 (no expanded years); real calendar days, ordinal
--           days and ISO week numbers (week 53 only in long years)
--
-- Not accepted: times without a date, lowercase "t" or "z", durations and
-- intervals (see validate.duration), the space separator of RFC 3339.
create function validate.iso8601(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    t        int;
    d        text;
    tm       text;
    m        text[];
    y        int;
    ext      boolean;
    complete boolean := true;
    hh       int;
    mi       int;
    ss       int;
    frac     text;
    zh       int;
    zm       int;
begin
    t := strpos(value, 'T');
    if t > 0 then
        d := left(value, t - 1);
        tm := substr(value, t + 1);
    else
        d := value;
    end if;

    -- date
    if d ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        ext := true;
        if not validate._valid_date(left(d, 4)::int, substr(d, 6, 2)::int, substr(d, 9, 2)::int) then
            return false;
        end if;
    elsif d ~ '^[0-9]{8}$' then
        ext := false;
        if not validate._valid_date(left(d, 4)::int, substr(d, 5, 2)::int, substr(d, 7, 2)::int) then
            return false;
        end if;
    elsif d ~ '^[0-9]{4}-?[0-9]{3}$' then
        -- ordinal date
        ext := strpos(d, '-') > 0;
        y := left(d, 4)::int;
        if right(d, 3)::int not between 1 and (case when validate._is_leap(y) then 366 else 365 end) then
            return false;
        end if;
    elsif d ~ '^[0-9]{4}-?W' then
        -- week date: YYYY-Www-D, YYYY-Www, YYYYWwwD, YYYYWww
        m := regexp_match(d, '^([0-9]{4})(-?)W([0-9]{2})(-?)([1-7]?)$');
        if m is null
           or not ((m[2] = '-' and ((m[4] = '-' and m[5] <> '') or (m[4] = '' and m[5] = '')))
                   or (m[2] = '' and m[4] = '')) then
            return false;
        end if;
        ext := m[2] = '-';
        complete := m[5] <> '';
        if m[3]::int not between 1 and validate._iso_weeks_in_year(m[1]::int) then
            return false;
        end if;
    elsif d ~ '^[0-9]{4}-[0-9]{2}$' then
        -- reduced precision: a month (YYYYMM is not ISO 8601)
        complete := false;
        if substr(d, 6, 2)::int not between 1 and 12 then
            return false;
        end if;
    elsif d ~ '^[0-9]{4}$' then
        complete := false;
    else
        return false;
    end if;

    if tm is null then
        return t = 0;
    end if;
    if not complete or tm = '' then
        return false;
    end if;

    -- time, in the same format (basic or extended) as the date
    if ext then
        m := regexp_match(tm, '^([0-9]{2})(:([0-9]{2})(:([0-9]{2}))?)?([.,][0-9]+)?(Z|[+-]([0-9]{2})(:([0-9]{2}))?)?$');
        if m is null then
            return false;
        end if;
        hh := m[1]::int; mi := m[3]::int; ss := m[5]::int; frac := m[6];
        zh := m[8]::int; zm := m[10]::int;
    else
        m := regexp_match(tm, '^([0-9]{2})(([0-9]{2})([0-9]{2})?)?([.,][0-9]+)?(Z|[+-]([0-9]{2})([0-9]{2})?)?$');
        if m is null then
            return false;
        end if;
        hh := m[1]::int; mi := m[3]::int; ss := m[4]::int; frac := m[5];
        zh := m[7]::int; zm := m[8]::int;
    end if;
    if hh > 24 or coalesce(mi, 0) > 59 or coalesce(ss, 0) > 60
       or coalesce(zh, 0) > 23 or coalesce(zm, 0) > 59 then
        return false;
    end if;
    -- 24:00:00 is the end of a day; nothing may follow it
    if hh = 24 and (coalesce(mi, 0) <> 0 or coalesce(ss, 0) <> 0 or coalesce(frac, '.0') !~ '^[.,]0+$') then
        return false;
    end if;
    return true;
end;
$$;

-- ISO 8601-1 duration: PnYnMnDTnHnMnS with the components in that order,
-- each optional but at least one present, "T" before any time component,
-- or PnW alone. Values are non-negative integers; the last component may
-- have a decimal fraction (. or ,). This accepts every duration of the
-- RFC 3339 Appendix A grammar, plus combinations it omits such as P1Y2D.
create function validate.duration(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    v text := value;
begin
    if strpos(v, '.') > 0 or strpos(v, ',') > 0 then
        if v !~ '[0-9][.,][0-9]+[YMWDHS]$' then
            return false;
        end if;
        v := regexp_replace(v, '[.,][0-9]+(?=[YMWDHS]$)', '');
        if strpos(v, '.') > 0 or strpos(v, ',') > 0 then
            return false;
        end if;
    end if;
    return v ~ '^P([0-9]+W|([0-9]+Y)?([0-9]+M)?([0-9]+D)?(T([0-9]+H)?([0-9]+M)?([0-9]+S)?)?)$'
       and v <> 'P'
       and right(v, 1) <> 'T';
end;
$$;

-- ============================================================================
-- International
-- ============================================================================

-- ITU-T E.164 number in its international form: "+", a country code that
-- does not start with 0, then the rest, at most 15 digits in total (E.164
-- §6.1). No spaces or punctuation. Structure only: the country code and the
-- national number plan are not checked.
create function validate.e164(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[+][1-9][0-9]{1,14}$'
$$;

-- ISO 3166-1 alpha-2, the 249 officially assigned codes, uppercase.
-- User-assigned (XK and others), exceptionally reserved (UK, EU) and
-- withdrawn codes are rejected. Snapshot: Debian iso-codes iso_3166-1.json,
-- retrieved 2026-11-03, cross-checked with Wikipedia's officially assigned
-- table (data/README.md).
create function validate.country_code(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[A-Z]{2}$'
       and strpos(
             ' AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ'
             ' BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ'
             ' CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ'
             ' DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR'
             ' GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY'
             ' HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP'
             ' KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY'
             ' MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ'
             ' NA NC NE NF NG NI NL NO NP NR NU NZ OM'
             ' PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW'
             ' SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ'
             ' TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ'
             ' VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW ',
             ' ' || value || ' ') > 0
$$;

-- ISO 3166-1 alpha-3, the 249 officially assigned codes, uppercase. Same
-- snapshot as country_code.
create function validate.country_code_alpha3(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[A-Z]{3}$'
       and strpos(
             ' ABW AFG AGO AIA ALA ALB AND ARE ARG ARM ASM ATA ATF ATG AUS AUT AZE'
             ' BDI BEL BEN BES BFA BGD BGR BHR BHS BIH BLM BLR BLZ BMU BOL BRA BRB BRN BTN BVT BWA'
             ' CAF CAN CCK CHE CHL CHN CIV CMR COD COG COK COL COM CPV CRI CUB CUW CXR CYM CYP CZE'
             ' DEU DJI DMA DNK DOM DZA ECU EGY ERI ESH ESP EST ETH FIN FJI FLK FRA FRO FSM'
             ' GAB GBR GEO GGY GHA GIB GIN GLP GMB GNB GNQ GRC GRD GRL GTM GUF GUM GUY'
             ' HKG HMD HND HRV HTI HUN IDN IMN IND IOT IRL IRN IRQ ISL ISR ITA JAM JEY JOR JPN'
             ' KAZ KEN KGZ KHM KIR KNA KOR KWT LAO LBN LBR LBY LCA LIE LKA LSO LTU LUX LVA'
             ' MAC MAF MAR MCO MDA MDG MDV MEX MHL MKD MLI MLT MMR MNE MNG MNP MOZ MRT MSR MTQ MUS MWI MYS MYT'
             ' NAM NCL NER NFK NGA NIC NIU NLD NOR NPL NRU NZL OMN'
             ' PAK PAN PCN PER PHL PLW PNG POL PRI PRK PRT PRY PSE PYF QAT REU ROU RUS RWA'
             ' SAU SDN SEN SGP SGS SHN SJM SLB SLE SLV SMR SOM SPM SRB SSD STP SUR SVK SVN SWE SWZ SXM SYC SYR'
             ' TCA TCD TGO THA TJK TKL TKM TLS TON TTO TUN TUR TUV TWN TZA'
             ' UGA UKR UMI URY USA UZB VAT VCT VEN VGB VIR VNM VUT WLF WSM YEM ZAF ZMB ZWE ',
             ' ' || value || ' ') > 0
$$;

-- ISO 4217 alphabetic code from List One (current currencies and funds,
-- including the X codes for precious metals, XTS for testing and XXX for no
-- currency), uppercase. Historic codes (List Three) are rejected. Snapshot:
-- the 178 codes of List One as published by SIX on 2026-09-17, retrieved
-- 2026-11-03 (data/README.md).
create function validate.currency_code(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[A-Z]{3}$'
       and strpos(
             ' AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD'
             ' CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR'
             ' FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY'
             ' KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU'
             ' MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR'
             ' RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND'
             ' TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAD XAF XAG XAU XBA'
             ' XBB XBC XBD XCD XCG XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG ',
             ' ' || value || ' ') > 0
$$;

-- ISO 639-1 two-letter language code, the 183 current codes, lowercase
-- (bh, deprecated in 2021, is rejected). Not BCP 47 language tags (en-US):
-- see docs/roadmap.md. Snapshot: the alpha_2 codes of Debian iso-codes
-- iso_639-2.json, retrieved 2026-11-03, cross-checked with Wikipedia's list
-- of ISO 639 codes (data/README.md).
create function validate.language_code(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[a-z]{2}$'
       and strpos(
             ' aa ab ae af ak am an ar as av ay az ba be bg bi bm bn bo br bs ca ce ch co cr cs cu cv cy'
             ' da de dv dz ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz'
             ' ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky'
             ' la lb lg li ln lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny'
             ' oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw'
             ' ta te tg th ti tk tl tn to tr ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu ',
             ' ' || value || ' ') > 0
$$;

-- ============================================================================
-- Developer formats
-- ============================================================================

-- RFC 4648 §4 base64 in canonical form: the standard alphabet, padding to a
-- multiple of 4 characters, and zero pad bits (§3.5), so each byte string
-- has exactly one valid encoding. No line breaks or white space (MIME base64
-- is not accepted). The empty string encodes zero bytes.
create function validate.base64(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/][AQgw]==|[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=)?$'
$$;

-- RFC 4648 §5 base64url: the URL- and filename-safe alphabet (- and _),
-- padding optional (as in JWS, RFC 7515 §2) but correct when present, zero
-- pad bits.
create function validate.base64url(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^([A-Za-z0-9_-]{4})*([A-Za-z0-9_-][AQgw](==)?|[A-Za-z0-9_-]{2}[AEIMQUYcgkosw048]=?)?$'
$$;

-- Hexadecimal encoding of bytes (RFC 4648 §8, either case): an even number
-- of hex digits, no 0x prefix, no separators. What decode(value, 'hex')
-- accepts, minus its white space.
create function validate.hex(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^([0-9A-Fa-f]{2})*$'
$$;

-- RFC 6901 §3 JSON Pointer: "" or a sequence of "/" reference-token, where
-- "~" appears only as the escapes ~0 and ~1.
create function validate.json_pointer(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^(/([^~/]|~[01])*)*$'
$$;

-- Relative JSON Pointer, draft-handrews-relative-json-pointer-01 §3, the
-- version JSON Schema Draft 2020-12 cites: a non-negative integer without
-- leading zeros, then "#" or a JSON Pointer (RFC 6901). ASCII digits only.
-- The index manipulation ("+1", "-1") of later drafts is not accepted.
create function validate.relative_json_pointer(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^(0|[1-9][0-9]*)(#|(/([^~/]|~[01])*)*)$'
$$;

-- URI Template, RFC 6570 §2 syntax, levels 1 to 4: literals (with the
-- apostrophe of erratum 6937, ucschar, iprivate and percent-encoded
-- triplets) and expressions "{" [operator] varspec *("," varspec) "}" with
-- the operators + # . / ; ? &, dotted variable names of ALPHA, DIGIT, "_"
-- and percent-encoded triplets, and the modifiers :1 to :9999 and *.
-- The operators that §2.2 reserves for future extensions (= , ! @ |) are
-- rejected: no processor can expand them. Syntax only: not whether an
-- expansion yields a valid URI.
create function validate.uri_template(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    lit constant text := '([]!#$&''()*+,./0-9:;=?@A-Z[_a-z~-]|%[0-9A-Fa-f]{2})';
    vc  constant text := '([A-Za-z0-9_]|%[0-9A-Fa-f]{2})';
    vs  constant text := vc || '+([.]' || vc || '+)*(:[1-9][0-9]{0,3}|[*])?';
begin
    -- ucschar and iprivate are allowed in literals only: map them to a
    -- literal character that no expression accepts
    if value ~ ('[^' || chr(1) || '-' || chr(127) || ']') then
        value := regexp_replace(value, validate._iri_chars(true), '!', 'g');
    end if;
    return value ~ ('^(' || lit || '|[{][+#./;?&]?' || vs || '(,' || vs || ')*[}])*$');
end;
$$;

-- One cron field: a comma-separated list of *, n, n-m, */s or n-m/s. Names
-- (JAN, MON, either case) may stand for numbers where names is not null.
create function validate._cron_field(field text, lo int, hi int, names text[])
returns boolean
language plpgsql immutable parallel safe
set search_path = ''
as $$
declare
    item  text;
    base  text;
    step  text;
    parts text[];
    a     int;
    b     int;
    p     text;
    k     int;
begin
    foreach item in array string_to_array(field, ',') loop
        if item = '' or item ~ '/.*/' then
            return false;
        end if;
        base := split_part(item, '/', 1);
        step := nullif(split_part(item, '/', 2), '');
        if strpos(item, '/') > 0 and (step is null or step !~ '^[0-9]{1,2}$' or step::int not between 1 and hi) then
            return false;
        end if;
        if base = '*' then
            continue;
        end if;
        parts := string_to_array(base, '-');
        -- a step needs a range: 5/15 is not cron syntax
        if cardinality(parts) not in (1, 2) or (step is not null and cardinality(parts) = 1) then
            return false;
        end if;
        a := null;
        b := null;
        for i in 1 .. cardinality(parts) loop
            p := parts[i];
            if p ~ '^[0-9]{1,2}$' then
                k := p::int;
            elsif names is not null and p ~ '^[A-Za-z]{3}$' then
                k := array_position(names, translate(p, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'));
                if k is null then
                    return false;
                end if;
                k := k - 1 + lo;
            else
                return false;
            end if;
            if k not between lo and hi then
                return false;
            end if;
            if i = 1 then a := k; else b := k; end if;
        end loop;
        if b is not null and a > b then
            return false;
        end if;
    end loop;
    return true;
end;
$$;

-- A standard five-field cron schedule (POSIX crontab, with the Vixie cron
-- extensions that cronie and pg_cron accept): minute (0-59), hour (0-23),
-- day of month (1-31), month (1-12 or JAN-DEC), day of week (0-7, 0 and 7
-- are Sunday, or SUN-SAT). Each field is a list of *, n, n-m and steps */s
-- or n-m/s. Fields are separated by spaces or tabs. The macros @yearly,
-- @annually, @monthly, @weekly, @daily, @midnight and @hourly are accepted.
--
-- Not accepted: a seconds or year field, the Quartz extensions ? L W #,
-- @reboot, n/s without a range, environment lines and commands.
create function validate.cron(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    f text[];
begin
    if value ~ '^@(yearly|annually|monthly|weekly|daily|midnight|hourly)$' then
        return true;
    end if;
    f := regexp_split_to_array(value, '[ ' || chr(9) || ']+');
    return cardinality(f) = 5
       and validate._cron_field(f[1], 0, 59, null)
       and validate._cron_field(f[2], 0, 23, null)
       and validate._cron_field(f[3], 1, 31, null)
       and validate._cron_field(f[4], 1, 12, '{JAN,FEB,MAR,APR,MAY,JUN,JUL,AUG,SEP,OCT,NOV,DEC}')
       and validate._cron_field(f[5], 0, 7, '{SUN,MON,TUE,WED,THU,FRI,SAT}');
end;
$$;

-- A RegExpIdentifierName (ECMA-262 §22.2.1) in a pattern split into
-- characters, starting at ch[i], the character after "<", up to ">". Returns
-- the index after ">" and the name as its code points ("97,98"), or a null
-- name when it is not an identifier. ASCII characters follow the grammar
-- ($, _, letters, and digits after the first); non-ASCII characters are
-- accepted without checking ID_Start / ID_Continue. \u escapes count as the
-- code point they denote.
create function validate._regex_name(ch text[], i int, out next int, out name text)
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    n   int := cardinality(ch);
    cp  int;
    j   int;
    hex text;
begin
    name := '';
    loop
        if i > n then
            name := null;
            return;
        end if;
        exit when ch[i] = '>';
        if ch[i] = chr(92) then
            if i + 1 > n or ch[i + 1] <> 'u' then
                name := null;
                return;
            end if;
            if i + 2 <= n and ch[i + 2] = '{' then
                j := array_position(ch, '}', i + 3);
                hex := array_to_string(ch[i + 3:j - 1], '');
                hex := ltrim(hex, '0');
                if j is null or hex !~ '^[0-9A-Fa-f]{0,6}$' or ('x' || lpad(hex, 8, '0'))::bit(32)::int > 1114111
                   or ch[i + 3] = '}' then
                    name := null;
                    return;
                end if;
                i := j + 1;
            else
                hex := array_to_string(ch[i + 2:i + 5], '');
                if hex !~ '^[0-9A-Fa-f]{4}$' then
                    name := null;
                    return;
                end if;
                i := i + 6;
            end if;
            cp := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
        else
            cp := ascii(ch[i]);
            i := i + 1;
        end if;
        if not (cp between 65 and 90 or cp between 97 and 122 or cp in (36, 95) or cp > 127
                or (name <> '' and cp between 48 and 57)) then
            name := null;
            return;
        end if;
        name := name || case when name = '' then '' else ',' end || cp;
    end loop;
    if name = '' then
        name := null;
        return;
    end if;
    next := i + 1;
end;
$$;

-- A Unicode property expression of \p{...} or \P{...} (ECMA-262 §22.2.2.9,
-- UnicodeMatchProperty and UnicodeMatchPropertyValue): a General_Category
-- value or a binary property alone, or General_Category / Script /
-- Script_Extensions (or gc / sc / scx) = value. Names are case-sensitive and
-- exact. Script values are checked for their shape only.
create function validate._regex_property(body text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    with gc(v) as (
        select unnest('{C,Other,Cc,Control,cntrl,Cf,Format,Cn,Unassigned,Co,Private_Use,Cs,Surrogate,L,Letter,LC,Cased_Letter,Ll,Lowercase_Letter,Lm,Modifier_Letter,Lo,Other_Letter,Lt,Titlecase_Letter,Lu,Uppercase_Letter,M,Mark,Combining_Mark,Mc,Spacing_Mark,Me,Enclosing_Mark,Mn,Nonspacing_Mark,N,Number,Nd,Decimal_Number,digit,Nl,Letter_Number,No,Other_Number,P,Punctuation,punct,Pc,Connector_Punctuation,Pd,Dash_Punctuation,Pe,Close_Punctuation,Pf,Final_Punctuation,Pi,Initial_Punctuation,Po,Other_Punctuation,Ps,Open_Punctuation,S,Symbol,Sc,Currency_Symbol,Sk,Modifier_Symbol,Sm,Math_Symbol,So,Other_Symbol,Z,Separator,Zl,Line_Separator,Zp,Paragraph_Separator,Zs,Space_Separator}'::text[])
    ), bin(v) as (
        select unnest('{ASCII,ASCII_Hex_Digit,AHex,Alphabetic,Alpha,Any,Assigned,Bidi_Control,Bidi_C,Bidi_Mirrored,Bidi_M,Case_Ignorable,CI,Cased,Changes_When_Casefolded,CWCF,Changes_When_Casemapped,CWCM,Changes_When_Lowercased,CWL,Changes_When_NFKC_Casefolded,CWKCF,Changes_When_Titlecased,CWT,Changes_When_Uppercased,CWU,Dash,Default_Ignorable_Code_Point,DI,Deprecated,Dep,Diacritic,Dia,Emoji,Emoji_Component,EComp,Emoji_Modifier,EMod,Emoji_Modifier_Base,EBase,Emoji_Presentation,EPres,Extended_Pictographic,ExtPict,Extender,Ext,Grapheme_Base,Gr_Base,Grapheme_Extend,Gr_Ext,Hex_Digit,Hex,IDS_Binary_Operator,IDSB,IDS_Trinary_Operator,IDST,ID_Continue,IDC,ID_Start,IDS,Ideographic,Ideo,Join_Control,Join_C,Logical_Order_Exception,LOE,Lowercase,Lower,Math,Noncharacter_Code_Point,NChar,Pattern_Syntax,Pat_Syn,Pattern_White_Space,Pat_WS,Quotation_Mark,QMark,Radical,Regional_Indicator,RI,Sentence_Terminal,STerm,Soft_Dotted,SD,Terminal_Punctuation,Term,Unified_Ideograph,UIdeo,Uppercase,Upper,Variation_Selector,VS,White_Space,space,XID_Continue,XIDC,XID_Start,XIDS}'::text[])
    )
    select case
        when strpos(body, '=') = 0 then
            exists (select 1 from gc where v = body) or exists (select 1 from bin where v = body)
        when split_part(body, '=', 1) in ('General_Category', 'gc') then
            exists (select 1 from gc where v = substr(body, strpos(body, '=') + 1))
        when split_part(body, '=', 1) in ('Script', 'sc', 'Script_Extensions', 'scx') then
            substr(body, strpos(body, '=') + 1) ~ '^[A-Za-z]+(_[A-Za-z]+)*$'
        else false
    end
$$;

-- One escape of a pattern split into characters, ch[i] being the backslash
-- (ECMA-262 §22.2.1 AtomEscape, or ClassEscape when inclass), in Unicode
-- mode. kind is 'char' (cp is its code point), 'class' (\d, \p{...} and
-- the like), 'assert' (\b, \B), 'backref' (cp is the group number), 'named'
-- (\k<name>, name as _regex_name returns it) or 'error'. next is the index
-- after the escape.
create function validate._regex_escape(
    ch text[],
    i int,
    inclass boolean,
    out next int,
    out cp int,
    out kind text,
    out name text
)
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    n   int := cardinality(ch);
    d   text;
    a   int;
    j   int;
    hex text;
    r   record;
begin
    kind := 'error';
    if i + 1 > n then
        return;
    end if;
    d := ch[i + 1];
    a := ascii(d);
    next := i + 2;
    if d in ('d', 'D', 's', 'S', 'w', 'W') then
        kind := 'class';
    elsif d in ('p', 'P') then
        j := array_position(ch, '}', i + 3);
        if i + 2 <= n and ch[i + 2] = '{' and j is not null
           and validate._regex_property(array_to_string(ch[i + 3:j - 1], '')) then
            kind := 'class';
            next := j + 1;
        end if;
    elsif d = 'b' then
        if inclass then
            kind := 'char';
            cp := 8;
        else
            kind := 'assert';
        end if;
    elsif d = 'B' then
        if not inclass then
            kind := 'assert';
        end if;
    elsif a between 49 and 57 then
        -- DecimalEscape: a backreference, never inside a class
        if not inclass then
            j := i + 1;
            while j + 1 <= n and ascii(ch[j + 1]) between 48 and 57 loop
                j := j + 1;
            end loop;
            hex := array_to_string(ch[i + 1:j], '');
            kind := 'backref';
            cp := case when char_length(hex) > 9 then 2147483647 else hex::int end;
            next := j + 1;
        end if;
    elsif d = '0' then
        -- \0 is NUL only when no digit follows
        if not (i + 2 <= n and ascii(ch[i + 2]) between 48 and 57) then
            kind := 'char';
            cp := 0;
        end if;
    elsif d = 'k' then
        if not inclass and i + 2 <= n and ch[i + 2] = '<' then
            r := validate._regex_name(ch, i + 3);
            if r.name is not null then
                kind := 'named';
                name := r.name;
                next := r.next;
            end if;
        end if;
    elsif d in ('f', 'n', 'r', 't', 'v') then
        kind := 'char';
        cp := case d when 'f' then 12 when 'n' then 10 when 'r' then 13 when 't' then 9 else 11 end;
    elsif d = 'c' then
        if i + 2 <= n and (ascii(ch[i + 2]) between 65 and 90 or ascii(ch[i + 2]) between 97 and 122) then
            kind := 'char';
            cp := ascii(ch[i + 2]) % 32;
            next := i + 3;
        end if;
    elsif d = 'x' then
        hex := array_to_string(ch[i + 2:i + 3], '');
        if hex ~ '^[0-9A-Fa-f]{2}$' then
            kind := 'char';
            cp := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
            next := i + 4;
        end if;
    elsif d = 'u' then
        if i + 2 <= n and ch[i + 2] = '{' then
            j := array_position(ch, '}', i + 3);
            hex := array_to_string(ch[i + 3:j - 1], '');
            if j is not null and hex ~ '^[0-9A-Fa-f]+$' and char_length(ltrim(hex, '0')) <= 6
               and ('x' || lpad(ltrim(hex, '0'), 8, '0'))::bit(32)::int <= 1114111 then
                kind := 'char';
                cp := ('x' || lpad(ltrim(hex, '0'), 8, '0'))::bit(32)::int;
                next := j + 1;
            end if;
        else
            hex := array_to_string(ch[i + 2:i + 5], '');
            if hex ~ '^[0-9A-Fa-f]{4}$' then
                kind := 'char';
                cp := ('x' || lpad(hex, 8, '0'))::bit(32)::int;
                next := i + 6;
                -- a surrogate pair written as two escapes is one code point
                hex := array_to_string(ch[i + 6:i + 11], '');
                if cp between 55296 and 56319 and hex ~ ('^' || chr(92) || chr(92) || 'u[Dd][C-Fc-f][0-9A-Fa-f]{2}$') then
                    cp := 65536 + (cp - 55296) * 1024 + (('x' || lpad(substr(hex, 3), 8, '0'))::bit(32)::int - 56320);
                    next := i + 12;
                end if;
            end if;
        end if;
    elsif d = '-' then
        if inclass then
            kind := 'char';
            cp := 45;
        end if;
    elsif strpos('^$' || chr(92) || '.*+?()[]{}|/', d) > 0 then
        -- IdentityEscape in Unicode mode: a SyntaxCharacter or "/"
        kind := 'char';
        cp := a;
    end if;
end;
$$;

-- ECMA-262 (2025) §22.2.1 Pattern, in Unicode mode (the u flag): the
-- syntax and its early errors. Checked: the grammar of alternatives,
-- groups ((?:), (?<name>), lookahead, lookbehind, modifiers (?ims-ims:)),
-- quantifiers ({n,m} with n <= m; assertions other than groups take none),
-- character classes (ranges in order, no class escape in a range), every
-- escape, backreferences to existing groups, \k<name> to an existing name,
-- and duplicate group names only in different alternatives. Unicode mode
-- rejects the Annex B leniencies: a lone "{", "}" or "]", \a and other
-- identity escapes of letters, \c without a letter, quantified lookaheads,
-- octal escapes.
--
-- Not checked: ID_Start / ID_Continue of non-ASCII characters in group
-- names, Script values in \p{Script=...} beyond their shape, and the v flag
-- (unicodeSets) syntax.
create function validate.regex(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    ch     text[] := regexp_split_to_array(value, '');
    n      int := cardinality(ch);
    i      int := 1;
    c      text;
    atom   boolean := false;
    quant  boolean[] := '{}';
    path   text[] := '{0:0}';
    ndis   int := 0;
    ncap   int := 0;
    maxref int := 0;
    names  text[] := '{}';
    npaths text[] := '{}';
    refs   text[] := '{}';
    r      record;
    j      int;
    q      text;
    cp1    int;
    k1     text;
    cp2    int;
    k2     text;
    p1     text[];
    p2     text[];
    on_    text;
    off_   text;
begin
    if value = '' then
        return true;
    end if;
    while i <= n loop
        c := ch[i];
        if c = '|' then
            path[cardinality(path)] := split_part(path[cardinality(path)], ':', 1) || ':'
                                       || (split_part(path[cardinality(path)], ':', 2)::int + 1);
            atom := false;
            i := i + 1;
        elsif c = '(' then
            if i + 1 <= n and ch[i + 1] = '?' then
                if i + 2 > n then
                    return false;
                end if;
                c := ch[i + 2];
                if c = ':' then
                    quant := quant || true;
                    i := i + 3;
                elsif c in ('=', '!') then
                    quant := quant || false;
                    i := i + 3;
                elsif c = '<' and i + 3 <= n and ch[i + 3] in ('=', '!') then
                    quant := quant || false;
                    i := i + 4;
                elsif c = '<' then
                    r := validate._regex_name(ch, i + 3);
                    if r.name is null then
                        return false;
                    end if;
                    names := names || r.name;
                    npaths := npaths || array_to_string(path, '/');
                    ncap := ncap + 1;
                    quant := quant || true;
                    i := r.next;
                else
                    -- modifiers (?ims-ims:...): each flag at most once, not both lists empty
                    j := i + 2;
                    on_ := '';
                    off_ := '';
                    while j <= n and ch[j] in ('i', 'm', 's') loop
                        on_ := on_ || ch[j];
                        j := j + 1;
                    end loop;
                    if j <= n and ch[j] = '-' then
                        j := j + 1;
                        while j <= n and ch[j] in ('i', 'm', 's') loop
                            off_ := off_ || ch[j];
                            j := j + 1;
                        end loop;
                        if on_ = '' and off_ = '' then
                            return false;
                        end if;
                    end if;
                    if j > n or ch[j] <> ':'
                       or (on_ || off_) ~ ('(.).*' || chr(92) || '1') then
                        return false;
                    end if;
                    quant := quant || true;
                    i := j + 1;
                end if;
            else
                ncap := ncap + 1;
                quant := quant || true;
                i := i + 1;
            end if;
            ndis := ndis + 1;
            path := path || (ndis || ':0');
            atom := false;
        elsif c = ')' then
            if cardinality(quant) = 0 then
                return false;
            end if;
            atom := quant[cardinality(quant)];
            quant := quant[1:cardinality(quant) - 1];
            path := path[1:cardinality(path) - 1];
            i := i + 1;
        elsif c in ('*', '+', '?') then
            if not atom then
                return false;
            end if;
            i := i + 1;
            if i <= n and ch[i] = '?' then
                i := i + 1;
            end if;
            atom := false;
        elsif c = '{' then
            -- {n}, {n,} or {n,m}; in Unicode mode a "{" is always a quantifier
            q := array_to_string(ch[i:least(n, i + 40)], '');
            q := substring(q from '^[{][0-9]+(?:,[0-9]*)?[}]');
            if q is null or not atom then
                return false;
            end if;
            if q ~ ',[0-9]+[}]$'
               and substring(q from '^[{]([0-9]+)')::numeric > substring(q from ',([0-9]+)[}]$')::numeric then
                return false;
            end if;
            i := i + char_length(q);
            if i <= n and ch[i] = '?' then
                i := i + 1;
            end if;
            atom := false;
        elsif c in ('}', ']') then
            return false;
        elsif c in ('^', '$') then
            atom := false;
            i := i + 1;
        elsif c = chr(92) then
            r := validate._regex_escape(ch, i, false);
            if r.kind = 'error' then
                return false;
            elsif r.kind = 'backref' then
                maxref := greatest(maxref, r.cp);
            elsif r.kind = 'named' then
                refs := refs || r.name;
            end if;
            atom := r.kind <> 'assert';
            i := r.next;
        elsif c = '[' then
            i := i + 1;
            if i <= n and ch[i] = '^' then
                i := i + 1;
            end if;
            loop
                if i > n then
                    return false;
                end if;
                exit when ch[i] = ']';
                -- ClassAtom, then an optional "-" ClassAtom range
                if ch[i] = chr(92) then
                    r := validate._regex_escape(ch, i, true);
                    if r.kind not in ('char', 'class') then
                        return false;
                    end if;
                    cp1 := r.cp;
                    k1 := r.kind;
                    i := r.next;
                else
                    cp1 := ascii(ch[i]);
                    k1 := 'char';
                    i := i + 1;
                end if;
                if i + 1 <= n and ch[i] = '-' and ch[i + 1] <> ']' then
                    i := i + 1;
                    if ch[i] = chr(92) then
                        r := validate._regex_escape(ch, i, true);
                        if r.kind not in ('char', 'class') then
                            return false;
                        end if;
                        cp2 := r.cp;
                        k2 := r.kind;
                        i := r.next;
                    else
                        cp2 := ascii(ch[i]);
                        k2 := 'char';
                        i := i + 1;
                    end if;
                    if k1 = 'class' or k2 = 'class' or cp1 > cp2 then
                        return false;
                    end if;
                end if;
            end loop;
            i := i + 1;
            atom := true;
        else
            atom := true;
            i := i + 1;
        end if;
    end loop;
    if cardinality(quant) > 0 or maxref > ncap then
        return false;
    end if;
    -- \k<name> needs a group of that name
    if exists (select 1 from unnest(refs) x where not x = any(names)) then
        return false;
    end if;
    -- a name used twice must be in different alternatives of one disjunction
    for a in 1 .. cardinality(names) loop
        for b in a + 1 .. cardinality(names) loop
            continue when names[a] <> names[b];
            p1 := string_to_array(npaths[a], '/');
            p2 := string_to_array(npaths[b], '/');
            j := 1;
            while j <= least(cardinality(p1), cardinality(p2)) and p1[j] = p2[j] loop
                j := j + 1;
            end loop;
            if j > least(cardinality(p1), cardinality(p2))
               or split_part(p1[j], ':', 1) <> split_part(p2[j], ':', 1) then
                return false;
            end if;
        end loop;
    end loop;
    return true;
end;
$$;

-- ============================================================================
-- Financial
-- ============================================================================

-- Luhn (ISO/IEC 7812-1 Annex B, "mod 10") check over a string of at least two
-- decimal digits.
create function validate.luhn(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    n     int := char_length(value);
    total int := 0;
    d     int;
begin
    if value !~ '^[0-9]{2,}$' then
        return false;
    end if;
    for i in 0 .. n - 1 loop
        d := ascii(substr(value, n - i, 1)) - 48;
        if i % 2 = 1 then
            d := d * 2;
            if d > 9 then
                d := d - 9;
            end if;
        end if;
        total := total + d;
    end loop;
    return total % 10 = 0;
end;
$$;

-- Payment card number (PAN, ISO/IEC 7812-1): 12 to 19 digits with a valid
-- Luhn check digit. No spaces or hyphens. Does not check the issuer (IIN)
-- or that the card exists.
create function validate.card_number(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select value ~ '^[0-9]{12,19}$' and validate.luhn(value)
$$;

-- ISO 2108 ISBN-10 in compact form: nine digits and a check character
-- (0-9 or uppercase X for 10) with sum(weight * digit) divisible by 11.
create function validate.isbn10(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    total int := 0;
begin
    if value !~ '^[0-9]{9}[0-9X]$' then
        return false;
    end if;
    for i in 1 .. 9 loop
        total := total + (11 - i) * (ascii(substr(value, i, 1)) - 48);
    end loop;
    total := total + case when right(value, 1) = 'X' then 10 else ascii(right(value, 1)) - 48 end;
    return total % 11 = 0;
end;
$$;

-- ISO 2108 ISBN-13 in compact form: an EAN-13 with the prefix 978 or 979
-- (979-0 is ISMN, not ISBN) and a valid EAN check digit (weights 1 and 3).
create function validate.isbn13(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    total int := 0;
begin
    if value !~ '^(978|979[1-9])[0-9]{9,10}$' or char_length(value) <> 13 then
        return false;
    end if;
    for i in 1 .. 13 loop
        total := total + (ascii(substr(value, i, 1)) - 48) * case when i % 2 = 0 then 3 else 1 end;
    end loop;
    return total % 10 = 0;
end;
$$;

-- ISBN-10 or ISBN-13, compact form (no hyphens or spaces).
create function validate.isbn(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select validate.isbn10(value) or validate.isbn13(value)
$$;

-- ISO 13616-1 IBAN in electronic format (uppercase, no spaces): a country
-- code from the SWIFT IBAN registry, the length that registry gives for the
-- country, check digits 02 to 98, an alphanumeric BBAN, and the ISO 7064
-- MOD 97-10 check (remainder 1). The national BBAN structure and national
-- check digits are not checked. Snapshot: the 89 countries of the SWIFT IBAN
-- Registry (TXT) as updated on 2026-09-17, retrieved 2026-11-03
-- (data/README.md). Territories that the registry lists under another
-- prefix (GF, RE and the other French territories under FR; IM, JE, GG
-- under GB; AX under FI) use that prefix and are rejected as prefixes.
create function validate.iban(value text)
returns boolean
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    expected int;
    s        text;
    digits   text := '';
    c        int;
begin
    if value !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then
        return false;
    end if;
    -- SWIFT IBAN Registry: country code and IBAN length
    expected := case left(value, 2)
        when 'AD' then 24 when 'AE' then 23 when 'AL' then 28 when 'AT' then 20
        when 'AZ' then 28 when 'BA' then 20 when 'BE' then 16 when 'BG' then 22
        when 'BH' then 22 when 'BI' then 27 when 'BR' then 29 when 'BY' then 28
        when 'CH' then 21 when 'CR' then 22 when 'CY' then 28 when 'CZ' then 24
        when 'DE' then 22 when 'DJ' then 27 when 'DK' then 18 when 'DO' then 28
        when 'EE' then 20 when 'EG' then 29 when 'ES' then 24 when 'FI' then 18
        when 'FK' then 18 when 'FO' then 18 when 'FR' then 27 when 'GB' then 22
        when 'GE' then 22 when 'GI' then 23 when 'GL' then 18 when 'GR' then 27
        when 'GT' then 28 when 'HN' then 28 when 'HR' then 21 when 'HU' then 28
        when 'IE' then 22 when 'IL' then 23 when 'IQ' then 23 when 'IS' then 26
        when 'IT' then 27 when 'JO' then 30 when 'KW' then 30 when 'KZ' then 20
        when 'LB' then 28 when 'LC' then 32 when 'LI' then 21 when 'LT' then 20
        when 'LU' then 20 when 'LV' then 21 when 'LY' then 25 when 'MC' then 27
        when 'MD' then 24 when 'ME' then 22 when 'MK' then 19 when 'MN' then 20
        when 'MR' then 27 when 'MT' then 31 when 'MU' then 30 when 'NI' then 28
        when 'NL' then 18 when 'NO' then 15 when 'OM' then 23 when 'PK' then 24
        when 'PL' then 28 when 'PS' then 29 when 'PT' then 25 when 'QA' then 29
        when 'RO' then 24 when 'RS' then 22 when 'RU' then 33 when 'SA' then 24
        when 'SC' then 31 when 'SD' then 18 when 'SE' then 24 when 'SI' then 19
        when 'SK' then 24 when 'SM' then 27 when 'SO' then 23 when 'ST' then 25
        when 'SV' then 28 when 'TL' then 23 when 'TN' then 24 when 'TR' then 26
        when 'UA' then 29 when 'VA' then 22 when 'VG' then 24 when 'XK' then 20
        when 'YE' then 30
    end;
    if expected is null or char_length(value) <> expected
       or substr(value, 3, 2) in ('00', '01', '99') then
        return false;
    end if;
    -- ISO 7064 MOD 97-10: move the first four characters to the end, then
    -- A = 10 ... Z = 35
    s := substr(value, 5) || left(value, 4);
    for i in 1 .. char_length(s) loop
        c := ascii(substr(s, i, 1));
        digits := digits || case when c >= 65 then (c - 55)::text else chr(c) end;
    end loop;
    return digits::numeric % 97 = 1;
end;
$$;

-- ============================================================================
-- Format registry
-- ============================================================================
--
-- One row per named format. Built-in rows point at the validators above and
-- are inserted by this file; applications add their own with
-- register_format. The validator is stored by schema and name (its
-- signature is always (text)), not as regprocedure: reg* columns block
-- pg_upgrade, and a name survives dump and restore.
--
-- Security model (docs/registry.md):
--   - Everyone can read the registry and call format(); format() is SECURITY
--     INVOKER, so a validator runs with the caller's privileges.
--   - Registering needs INSERT on validate.formats, unregistering DELETE, plus
--     EXECUTE on the functions. None of these is granted to PUBLIC.
--   - _registry_guard (a trigger, so it also covers direct DML) protects the
--     built-in rows and lets a role change only its own entries, unless it
--     has the privileges of the entry's owner or of the registry's owner.

create table validate.formats (
    name             text primary key,
    validator_schema text not null,
    validator_name   text not null,
    builtin          boolean not null default false,
    description      text,
    owner            name not null default current_user,
    created_at       timestamptz not null default now(),
    constraint formats_name_check check (name ~ '^[A-Za-z][A-Za-z0-9_.-]{0,62}$')
);

comment on table validate.formats is
    'Named formats for validate.format(): the built-in validators and registered custom ones.';

-- Built-in rows, from the validators' comments below.
create function validate._builtin_formats()
returns text[]
language sql immutable parallel safe
set search_path = ''
as $$
    select '{base64,base64url,card_number,country_code,country_code_alpha3,cron,currency_code,domain,duration,e164,email,git_sha,hex,hostname,iban,idn_email,idn_hostname,ipv4,ipv6,iri,iri_reference,isbn,isbn10,isbn13,iso8601,json_pointer,language_code,luhn,mac,nanoid,port,regex,relative_json_pointer,rfc3339,rfc3339_date,rfc3339_time,semver,slug,ulid,uri,uri_reference,uri_template,url,uuid}'::text[]
$$;

comment on function validate.uuid(text) is 'RFC 9562 UUID string form (8-4-4-4-12 hex), any version.';
comment on function validate.uuid(text, int) is 'RFC 9562 UUID string form with the RFC variant and the given version (1-8).';
comment on function validate.ulid(text) is 'ULID: 26 Crockford base32 characters, first at most 7.';
comment on function validate.nanoid(text) is 'Nano ID with the default URL-safe alphabet and 21 characters.';
comment on function validate.nanoid(text, int, text) is 'Nano ID of a given size over a given alphabet.';
comment on function validate.slug(text) is 'Lowercase ASCII letters and digits joined by single hyphens.';
comment on function validate.semver(text) is 'Semantic Versioning 2.0.0 version string.';
comment on function validate.git_sha(text) is 'Full git object name: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.';
comment on function validate.ipv4(text) is 'IPv4 dotted-decimal address (RFC 3986 IPv4address).';
comment on function validate.ipv6(text) is 'IPv6 address text form (RFC 3986 IPv6address, RFC 4291 2.2).';
comment on function validate.hostname(text) is 'Host name (RFC 1123 labels, at most 253 characters; xn-- labels must be IDNA2008 A-labels).';
comment on function validate.domain(text) is 'Domain name with at least two labels and an alphabetic or xn-- top-level domain.';
comment on function validate.email(text) is 'Email address syntax (RFC 5321/5322 addr-spec, ASCII); not deliverability.';
comment on function validate.idn_email(text) is 'Internationalized email address syntax (RFC 6531 addr-spec, UTF-8 local part, IDN domain); not deliverability.';
comment on function validate.idn_hostname(text) is 'Internationalized host name (RFC 5890 U-labels and A-labels, IDNA2008 rules, Unicode 12.0 tables).';
comment on function validate.uri(text) is 'RFC 3986 URI with any scheme.';
comment on function validate.uri_reference(text) is 'RFC 3986 URI-reference: a URI or a relative reference.';
comment on function validate.iri(text) is 'RFC 3987 IRI: a URI that may also hold non-ASCII characters (ucschar, iprivate in the query).';
comment on function validate.iri_reference(text) is 'RFC 3987 IRI-reference: an IRI or a relative reference.';
comment on function validate.url(text) is 'Absolute http or https URL with a DNS, IPv4 or IPv6 host.';
comment on function validate.mac(text) is 'MAC-48/EUI-48 address with colon or hyphen separators.';
comment on function validate.port(text) is 'TCP/UDP port number 1-65535 in decimal.';
comment on function validate.rfc3339(text) is 'RFC 3339 date-time with a real calendar date and an offset.';
comment on function validate.rfc3339_date(text) is 'RFC 3339 full-date (YYYY-MM-DD) with a real calendar date.';
comment on function validate.rfc3339_time(text) is 'RFC 3339 full-time (hh:mm:ss[.f] with offset).';
comment on function validate.iso8601(text) is 'ISO 8601 calendar, ordinal or week date, optionally with a time and zone.';
comment on function validate.duration(text) is 'ISO 8601 duration (PnYnMnDTnHnMnS or PnW).';
comment on function validate.e164(text) is 'E.164 phone number in international form (+ and up to 15 digits).';
comment on function validate.country_code(text) is 'ISO 3166-1 alpha-2 country code (officially assigned, uppercase).';
comment on function validate.country_code_alpha3(text) is 'ISO 3166-1 alpha-3 country code (officially assigned, uppercase).';
comment on function validate.currency_code(text) is 'ISO 4217 current currency code (uppercase).';
comment on function validate.language_code(text) is 'ISO 639-1 two-letter language code (lowercase).';
comment on function validate.base64(text) is 'RFC 4648 base64, padded and canonical.';
comment on function validate.base64url(text) is 'RFC 4648 base64url, padding optional, canonical.';
comment on function validate.hex(text) is 'Hex-encoded bytes: an even number of hex digits.';
comment on function validate.json_pointer(text) is 'RFC 6901 JSON Pointer.';
comment on function validate.relative_json_pointer(text) is 'Relative JSON Pointer (draft-handrews-relative-json-pointer-01).';
comment on function validate.uri_template(text) is 'RFC 6570 URI Template syntax, levels 1 to 4.';
comment on function validate.regex(text) is 'ECMA-262 regular expression pattern syntax (Unicode mode, with early errors).';
comment on function validate.cron(text) is 'Five-field cron schedule (Vixie cron syntax) or a macro such as @daily.';
comment on function validate.luhn(text) is 'Digit string with a valid Luhn (mod 10) check digit.';
comment on function validate.card_number(text) is 'Payment card number: 12-19 digits with a valid Luhn check digit; not existence.';
comment on function validate.isbn10(text) is 'ISBN-10 (compact) with a valid check character.';
comment on function validate.isbn13(text) is 'ISBN-13 (compact, 978/979) with a valid check digit.';
comment on function validate.isbn(text) is 'ISBN-10 or ISBN-13 (compact) with a valid check digit.';
comment on function validate.iban(text) is 'IBAN (electronic format) with registry length and a valid MOD 97 check.';

insert into validate.formats (name, validator_schema, validator_name, builtin, description)
select b.name, 'validate', b.name, true,
       pg_catalog.obj_description(pg_catalog.to_regprocedure('validate.' || b.name || '(text)'), 'pg_proc')
from unnest(validate._builtin_formats()) as b(name);

-- JSON Schema's format names for the same validators, so that "format":
-- "date-time" in validate.json_schema() finds validate.rfc3339. Built in too.
insert into validate.formats (name, validator_schema, validator_name, builtin, description)
values
    ('date-time', 'validate', 'rfc3339', true, 'JSON Schema "date-time": validate.rfc3339 (RFC 3339 date-time).'),
    ('date', 'validate', 'rfc3339_date', true, 'JSON Schema "date": validate.rfc3339_date (RFC 3339 full-date).'),
    ('time', 'validate', 'rfc3339_time', true, 'JSON Schema "time": validate.rfc3339_time (RFC 3339 full-time).'),
    ('uri-reference', 'validate', 'uri_reference', true, 'JSON Schema "uri-reference": validate.uri_reference (RFC 3986).'),
    ('json-pointer', 'validate', 'json_pointer', true, 'JSON Schema "json-pointer": validate.json_pointer (RFC 6901).'),
    ('relative-json-pointer', 'validate', 'relative_json_pointer', true, 'JSON Schema "relative-json-pointer": validate.relative_json_pointer.'),
    ('uri-template', 'validate', 'uri_template', true, 'JSON Schema "uri-template": validate.uri_template (RFC 6570).'),
    ('iri-reference', 'validate', 'iri_reference', true, 'JSON Schema "iri-reference": validate.iri_reference (RFC 3987).'),
    ('idn-hostname', 'validate', 'idn_hostname', true, 'JSON Schema "idn-hostname": validate.idn_hostname (RFC 5890).'),
    ('idn-email', 'validate', 'idn_email', true, 'JSON Schema "idn-email": validate.idn_email (RFC 6531).');

-- Whether the current role may create, change or remove an entry owned by
-- p_owner: it is the owner, or has the privileges of the owner or of the
-- registry table's owner (the extension owner). Superusers always may.
create function validate._can_manage(p_owner name)
returns boolean
language plpgsql stable
set search_path = ''
as $$
begin
    if p_owner = current_user then
        return true;
    end if;
    if pg_catalog.pg_has_role(current_user,
                              (select c.relowner from pg_catalog.pg_class c
                               where c.oid = 'validate.formats'::pg_catalog.regclass),
                              'usage') then
        return true;
    end if;
    return exists (select 1 from pg_catalog.pg_roles r where r.rolname = p_owner)
       and pg_catalog.pg_has_role(current_user, p_owner, 'usage');
end;
$$;

-- The trigger on both registries, validate.formats and validate.schemas
-- (JSON Schema section): built-in formats are fixed, and a role changes only
-- entries it may manage (_can_manage). For validate.schemas it also checks
-- and compiles the schema, so direct DML gets the same checks as
-- register_schema.
create function validate._registry_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    noun text := case tg_table_name when 'formats' then 'format' else 'JSON schema' end;
begin
    if tg_op = 'TRUNCATE' then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('validate.%s cannot be truncated', tg_table_name),
            hint = case tg_table_name when 'formats' then 'Use validate.unregister_format() for each custom format.'
                                      else 'Use validate.unregister_schema() for each schema.' end;
    end if;
    if tg_table_name = 'formats' then
        if tg_op in ('UPDATE', 'DELETE') and old.builtin then
            raise exception using
                errcode = '42501',
                message = pg_catalog.format('format "%s" is built in and cannot be changed or unregistered', old.name);
        end if;
        if tg_op in ('INSERT', 'UPDATE') and new.builtin then
            raise exception using
                errcode = '42501',
                message = 'only the extension can add built-in formats';
        end if;
    end if;
    if tg_op in ('UPDATE', 'DELETE') and not validate._can_manage(old.owner) then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('%s "%s" belongs to role %s', noun, old.name, old.owner),
            hint = 'Only its owner, a role with the owner''s privileges, or the extension owner can change it.';
    end if;
    if tg_op in ('INSERT', 'UPDATE') and not validate._can_manage(new.owner) then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('cannot register a %s on behalf of role %s', noun, new.owner);
    end if;
    if tg_table_name = 'schemas' and tg_op in ('INSERT', 'UPDATE') then
        new.compiled := validate._js_compile_named(new.schema);
    end if;
    return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- Created after the built-in rows, so this file can insert them.
create trigger formats_guard
before insert or update or delete on validate.formats
for each row execute function validate._registry_guard();

create trigger formats_guard_truncate
before truncate on validate.formats
for each statement execute function validate._registry_guard();

-- pg_dump keeps registered formats, not the built-in rows that CREATE
-- EXTENSION recreates. Only possible inside CREATE EXTENSION; a plain
-- `psql -f` install skips it.
do $$
begin
    perform pg_catalog.pg_extension_config_dump('validate.formats', 'where not builtin');
exception when feature_not_supported then
    null;
end;
$$;

-- Register a custom format. validator must take exactly one text argument,
-- return boolean, return a single row, and be IMMUTABLE or STABLE. The caller
-- needs EXECUTE on it, INSERT on validate.formats, and EXECUTE on this
-- function (none of which PUBLIC has). The caller becomes the entry's owner.
create function validate.register_format(
    name text,
    validator regprocedure,
    description text default null
)
returns void
language plpgsql
set search_path = ''
as $$
declare
    p        record;
    existing record;
begin
    if register_format.name is null or validator is null then
        raise exception using
            errcode = '22004',
            message = 'name and validator are required';
    end if;
    if register_format.name !~ '^[A-Za-z][A-Za-z0-9_.-]{0,62}$' then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('invalid format name: %s', pg_catalog.quote_literal(register_format.name)),
            hint = 'A name starts with a letter and has at most 63 letters, digits, "_", "-" or ".".';
    end if;

    select pr.proname, n.nspname, pr.pronargs, pr.proargtypes, pr.prorettype,
           pr.proretset, pr.prokind, pr.provolatile, pr.provariadic
    into p
    from pg_catalog.pg_proc pr
    join pg_catalog.pg_namespace n on n.oid = pr.pronamespace
    where pr.oid = validator;
    if not found then
        raise exception using
            errcode = '42883',
            message = pg_catalog.format('function with OID %s does not exist', validator::oid);
    end if;

    if p.prokind <> 'f' or p.pronargs <> 1 or p.proargtypes[0] <> 'pg_catalog.text'::pg_catalog.regtype
       or p.provariadic <> 0 or p.prorettype <> 'pg_catalog.bool'::pg_catalog.regtype or p.proretset then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('validator %s must take one text argument and return boolean', validator),
            hint = 'Declare it as: create function my_schema.my_format(value text) returns boolean ...';
    end if;
    if p.provolatile = 'v' then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('validator %s must be IMMUTABLE or STABLE, not VOLATILE', validator),
            hint = 'A validator must not change data or depend on anything but its argument and the database state.';
    end if;
    if not pg_catalog.has_function_privilege(validator, 'execute') then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('permission denied for function %s', validator);
    end if;

    select f.builtin, f.owner into existing
    from validate.formats f
    where f.name = register_format.name;
    if found then
        raise exception using
            errcode = '42710',
            message = case when existing.builtin
                then pg_catalog.format('format "%s" is built in and cannot be replaced', register_format.name)
                else pg_catalog.format('format "%s" is already registered (owner %s)', register_format.name, existing.owner)
            end,
            hint = case when existing.builtin
                then 'Register your validator under another name.'
                else 'Call validate.unregister_format() first to replace it.'
            end;
    end if;

    insert into validate.formats (name, validator_schema, validator_name, description)
    values (register_format.name, p.nspname, p.proname, register_format.description);
end;
$$;

-- Remove a custom format. Built-in formats cannot be removed. The caller
-- needs DELETE on validate.formats and must own the entry (or have the
-- privileges of its owner or of the extension owner).
create function validate.unregister_format(name text)
returns void
language plpgsql
set search_path = ''
as $$
declare
    existing record;
begin
    select f.builtin, f.owner into existing
    from validate.formats f
    where f.name = unregister_format.name;
    if not found then
        raise exception using
            errcode = '42704',
            message = pg_catalog.format('format "%s" does not exist', unregister_format.name),
            hint = 'validate.list_formats() lists the registered formats.';
    end if;
    if existing.builtin then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('format "%s" is built in and cannot be unregistered', unregister_format.name);
    end if;
    -- _registry_guard checks ownership; DELETE privilege is checked here.
    delete from validate.formats f
    where f.name = unregister_format.name;
end;
$$;

-- Check value against the named format. Built-in names call the validators
-- above; registered names call their function. SECURITY INVOKER: the
-- validator runs as the caller, with the caller's privileges. STABLE, not
-- IMMUTABLE, because the registry can change: a CHECK constraint that uses
-- it is not rechecked when an entry changes. Call the validator itself in
-- constraints. PARALLEL UNSAFE because a registered validator may be.
create function validate.format(name text, value text)
returns boolean
language plpgsql stable strict
set search_path = ''
as $$
declare
    v_schema text;
    v_name   text;
    result   boolean;
begin
    select f.validator_schema, f.validator_name into v_schema, v_name
    from validate.formats f
    where f.name = format.name;
    if not found then
        raise exception using
            errcode = '42704',
            message = pg_catalog.format('format "%s" does not exist', format.name),
            hint = 'validate.list_formats() lists the registered formats.';
    end if;
    if pg_catalog.to_regprocedure(pg_catalog.format('%I.%I(text)', v_schema, v_name)) is null then
        raise exception using
            errcode = '42883',
            message = pg_catalog.format('validator %I.%I(text) of format "%s" does not exist', v_schema, v_name, format.name),
            hint = 'It was dropped or renamed. Unregister the format and register it again.';
    end if;
    -- Identifiers are quoted with %I and the value is a parameter, never text
    -- in the statement.
    execute pg_catalog.format('select %I.%I($1)', v_schema, v_name) into result using value;
    return result;
end;
$$;

-- Every format in the registry. validator is null when a registered
-- function no longer exists.
create function validate.list_formats()
returns table (
    name        text,
    builtin     boolean,
    validator   regprocedure,
    description text,
    owner       name
)
language sql stable
set search_path = ''
as $$
    select f.name,
           f.builtin,
           pg_catalog.to_regprocedure(pg_catalog.format('%I.%I(text)', f.validator_schema, f.validator_name)),
           f.description,
           f.owner
    from validate.formats f
    order by f.builtin desc, f.name
$$;

comment on function validate.format(text, text) is 'Check a value against a named format from the registry (STABLE, SECURITY INVOKER).';
comment on function validate.register_format(text, regprocedure, text) is 'Register a custom format: a function(text) returns boolean. Not granted to PUBLIC.';
comment on function validate.unregister_format(text) is 'Remove a custom format you own. Not granted to PUBLIC.';
comment on function validate.list_formats() is 'List the built-in and registered formats.';

-- ============================================================================
-- JSON Schema (Draft 2020-12)
-- ============================================================================
--
-- A JSON Schema evaluator in PL/pgSQL (docs/json-schema.md). The schema gets
-- an evaluation context (_js_context; the full index of base URIs, $id,
-- $anchor and $dynamicAnchor from _js_compile when it needs one), then is
-- evaluated recursively (_js_eval). "format" is an assertion through the
-- registry (_js_format), so registered formats work and unknown ones raise.
-- Named schemas (validate.schemas) store the context once. Everything here is
-- SECURITY INVOKER; the evaluator is STABLE because format dispatch reads the
-- registry.

-- Base URI of a schema document without $id. Relative $ids and $refs resolve
-- against it.
create function validate._js_default_base()
returns text
language sql immutable parallel safe
set search_path = ''
as $$
    select 'pg-validate:/schema'
$$;

-- RFC 3986 §5.2.4 remove_dot_segments.
create function validate._js_remove_dots(path text)
returns text
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    input  text := path;
    output text := '';
begin
    while input <> '' loop
        if left(input, 3) = '../' then
            input := substr(input, 4);
        elsif left(input, 2) = './' then
            input := substr(input, 3);
        elsif left(input, 3) = '/./' then
            input := substr(input, 3);
        elsif input = '/.' then
            input := '/';
        elsif left(input, 4) = '/../' or input = '/..' then
            input := '/' || substr(input, 5);
            output := regexp_replace(output, '/?[^/]*$', '');
        elsif input in ('.', '..') then
            input := '';
        else
            output := output || substring(input from '^/?[^/]*');
            input := substr(input, char_length(substring(input from '^/?[^/]*')) + 1);
        end if;
    end loop;
    return output;
end;
$$;

-- RFC 3986 §5.2.2: resolve reference ref against the absolute URI base.
create function validate._js_resolve(base text, ref text)
returns text
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    -- Appendix B: 2 scheme, 4 authority, 5 path, 7 query, 9 fragment
    b  text[] := regexp_match(base, '^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)([?]([^#]*))?(#(.*))?$');
    r  text[] := regexp_match(ref, '^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)([?]([^#]*))?(#(.*))?$');
    scheme    text;
    authority text;
    has_auth  boolean;
    path      text;
    query     text;
begin
    if r[1] is not null then
        scheme := r[2]; has_auth := r[3] is not null; authority := r[4];
        path := validate._js_remove_dots(r[5]); query := r[7];
    else
        if r[3] is not null then
            has_auth := true; authority := r[4];
            path := validate._js_remove_dots(r[5]); query := r[7];
        else
            if r[5] = '' then
                path := b[5];
                query := coalesce(r[7], b[7]);
            else
                if left(r[5], 1) = '/' then
                    path := validate._js_remove_dots(r[5]);
                elsif b[3] is not null and b[5] = '' then
                    path := validate._js_remove_dots('/' || r[5]);
                else
                    path := validate._js_remove_dots(substring(b[5] from '^(.*/)') || r[5]);
                    if path is null then
                        path := validate._js_remove_dots(r[5]);
                    end if;
                end if;
                query := r[7];
            end if;
            has_auth := b[3] is not null; authority := b[4];
        end if;
        scheme := b[2];
    end if;
    return concat(scheme || ':', case when has_auth then '//' || authority end, path,
                  '?' || query, '#' || r[9]);
end;
$$;

-- An object key as a JSON Pointer token (RFC 6901 §3).
create function validate._js_token(key text)
returns text
language sql immutable strict parallel safe
set search_path = ''
as $$
    select replace(replace(key, '~', '~0'), '/', '~1')
$$;

-- Percent-decode a URI fragment (RFC 3986 §2.1) as UTF-8.
create function validate._js_pct_decode(value text)
returns text
language sql stable strict parallel safe
set search_path = ''
as $$
    select case when strpos(value, '%') = 0 then value else (
        select pg_catalog.convert_from(
                   pg_catalog.string_agg(
                       case when m[1] is not null then pg_catalog.decode(substr(m[1], 2), 'hex')
                            else pg_catalog.convert_to(m[2], 'UTF8') end,
                       ''::bytea order by t.n),
                   'UTF8')
        from regexp_matches(value, '(%[0-9A-Fa-f]{2})|([^%]+|%)', 'g') with ordinality as t(m, n))
    end
$$;

-- ECMA-262 regular expression (JSON Schema "pattern") to a Postgres ARE.
-- Translates the class escapes whose meaning differs: \d \w and \s (and
-- their negations) become the ASCII / ECMA white space sets that ECMA-262
-- defines, inside and outside brackets. Unicode property escapes raise.
create function validate._js_regex(pattern text)
returns text
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    bs      constant text := chr(92);
    ws      text := chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || ' '
                    || bs || 'u00a0' || bs || 'u1680' || bs || 'u2000-' || bs || 'u200a'
                    || bs || 'u2028' || bs || 'u2029' || bs || 'u202f' || bs || 'u205f'
                    || bs || 'u3000' || bs || 'ufeff';
    out     text := '';
    n       int := char_length(pattern);
    i       int := 1;
    c       text;
    d       text;
    inclass boolean := false;
begin
    if strpos(pattern, bs) = 0 then
        return pattern;
    end if;
    while i <= n loop
        c := substr(pattern, i, 1);
        if c = bs and i < n then
            d := substr(pattern, i + 1, 1);
            out := out || case d
                when 'd' then case when inclass then '0-9' else '[0-9]' end
                when 'D' then case when inclass then bs || 'D' else '[^0-9]' end
                when 'w' then case when inclass then 'A-Za-z0-9_' else '[A-Za-z0-9_]' end
                when 'W' then case when inclass then bs || 'W' else '[^A-Za-z0-9_]' end
                when 's' then case when inclass then ws else '[' || ws || ']' end
                when 'S' then case when inclass then bs || 'S' else '[^' || ws || ']' end
                else bs || d
            end;
            if d in ('p', 'P') then
                raise exception using
                    errcode = '0A000',
                    message = pg_catalog.format('unsupported regular expression in JSON Schema pattern: %s', pattern),
                    hint = 'Unicode property escapes (\p{...}) have no Postgres equivalent.';
            end if;
            i := i + 2;
            continue;
        end if;
        if c = '[' and not inclass then
            inclass := true;
        elsif c = ']' and inclass then
            inclass := false;
        end if;
        out := out || c;
        i := i + 1;
    end loop;
    return out;
end;
$$;

-- Every subschema the applicator keywords reach in a schema document: its
-- JSON Pointer, the value (normally an object or a boolean), the base URI in
-- effect at its parent ("pbase") and its own base URI (after its $id).
create function validate._js_walk(schema jsonb)
returns table (ptr text, node jsonb, pbase text, base text)
language sql immutable parallel safe
set search_path = ''
as $$
    with recursive walk(ptr, node, pbase, base) as (
        select ''::text, schema, validate._js_default_base(),
               case when jsonb_typeof(schema -> '$id') = 'string'
                    then split_part(validate._js_resolve(validate._js_default_base(), schema ->> '$id'), '#', 1)
                    else validate._js_default_base() end
        union all
        select w.ptr || c.path, c.child, w.base,
               case when jsonb_typeof(c.child -> '$id') = 'string'
                    then split_part(validate._js_resolve(w.base, c.child ->> '$id'), '#', 1)
                    else w.base end
        from walk w
        cross join lateral (
            select '/' || k, w.node -> k
            from unnest(array['additionalProperties', 'contains', 'else', 'if', 'items', 'not',
                              'propertyNames', 'then', 'unevaluatedItems', 'unevaluatedProperties']) k
            where w.node ? k
            union all
            select '/' || k || '/' || validate._js_token(e.key), e.value
            from unnest(array['$defs', 'properties', 'patternProperties', 'dependentSchemas']) k,
                 jsonb_each(case when jsonb_typeof(w.node -> k) = 'object' then w.node -> k end) e
            union all
            select '/' || k || '/' || (e.n - 1), e.value
            from unnest(array['allOf', 'anyOf', 'oneOf', 'prefixItems']) k,
                 jsonb_array_elements(case when jsonb_typeof(w.node -> k) = 'array' then w.node -> k end)
                     with ordinality e(value, n)
        ) c(path, child)
        where jsonb_typeof(w.node) = 'object'
    )
    select * from walk
$$;

-- Index a schema document: the base URI in effect at each subschema's parent
-- ("pbase"), the resources ($id -> pointer), plain-name anchors and dynamic
-- anchors, and whether any unevaluated* keyword needs annotations.
create function validate._js_compile(schema jsonb)
returns jsonb
language sql immutable parallel safe
set search_path = ''
as $$
    with walk as (select * from validate._js_walk(schema))
    select jsonb_build_object(
        'root', schema,
        'pbase', (select jsonb_object_agg(ptr, pbase) from walk),
        'ids', (select jsonb_object_agg(base, ptr)
                from (select distinct on (base) base, ptr from walk
                      where ptr = '' or jsonb_typeof(node -> '$id') = 'string'
                      order by base, char_length(ptr)) r),
        'anchors', coalesce((select jsonb_object_agg(a, ptr)
                    from (select distinct on (a) a, ptr
                          from walk, unnest(array[node ->> '$anchor', node ->> '$dynamicAnchor']) n
                          cross join lateral (select base || '#' || n) x(a)
                          where jsonb_typeof(node) = 'object' and n is not null
                          order by a, char_length(ptr)) an), '{}'),
        'dynanchors', coalesce((select jsonb_object_agg(base || '#' || (node ->> '$dynamicAnchor'), ptr)
                       from walk where jsonb_typeof(node -> '$dynamicAnchor') = 'string'), '{}'),
        'annot', exists (select 1 from walk
                         where jsonb_typeof(node) = 'object'
                           and (node ? 'unevaluatedProperties' or node ? 'unevaluatedItems'))
    )
$$;

-- The evaluation context for a schema. The index walk is needed only to
-- find embedded resources and anchors: a schema whose only "$id" is its
-- root's, without $anchor, $dynamicAnchor or $dynamicRef (the common case,
-- including "$ref": "#/$defs/..."), gets a context without the walk, where
-- every subschema's base URI is the root's. annot says whether any
-- unevaluated* keyword needs annotations. Both tests read the schema's text:
-- a key such as "$id" always appears there as "$id", and a false positive
-- (the word in a value) only costs the walk.
create function validate._js_context(schema jsonb)
returns jsonb
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    txt   text := schema::text;
    annot boolean := strpos(txt, '"unevaluated') > 0 and txt ~ '"unevaluated(Properties|Items)"';
    pos   int := strpos(txt, '"$id"');
begin
    if strpos(txt, '"$') > 0 and txt ~ '"[$](anchor|dynamicAnchor|dynamicRef)"'
       or pos > 0 and (jsonb_typeof(schema -> '$id') is distinct from 'string'
                       or strpos(substr(txt, pos + 5), '"$id"') > 0) then
        return validate._js_compile(schema);
    end if;
    return jsonb_build_object(
        'root', schema,
        'pbase', jsonb_build_object('', validate._js_default_base()),
        'ids', jsonb_build_object(case when pos > 0
                                       then split_part(validate._js_resolve(validate._js_default_base(), schema ->> '$id'), '#', 1)
                                       else validate._js_default_base() end, ''),
        'anchors', '{}'::jsonb,
        'dynanchors', '{}'::jsonb,
        'annot', annot);
end;
$$;

-- Resolve a $ref or $dynamicRef to (target schema, base URI at its parent,
-- the resource it belongs to). Remote references raise. A fragment-only
-- reference ("#/$defs/a", "#node"), the common case, skips RFC 3986
-- resolution: the base URI never has a fragment. Lookups use #> and #>> on
-- the context, which do not copy the intermediate objects.
create function validate._js_target(
    ctx jsonb,
    base text,
    ref text,
    dynamic boolean,
    dyn text[],
    out target jsonb,
    out tbase text,
    out resource text
)
language plpgsql stable
set search_path = ''
as $$
declare
    abs  text;
    pos  int;
    uri  text;
    frag text;
    ptr  text;
    toks text[];
begin
    if left(ref, 1) = '#' then
        abs := base || ref;
        uri := base;
        frag := substr(ref, 2);
    else
        abs := validate._js_resolve(base, ref);
        pos := strpos(abs, '#');
        if pos > 0 then
            uri := left(abs, pos - 1);
            frag := substr(abs, pos + 1);
        else
            uri := abs;
            frag := '';
        end if;
    end if;
    if strpos(frag, '%') > 0 then
        frag := validate._js_pct_decode(frag);
    end if;
    ptr := ctx #>> array['ids', uri];
    if ptr is null then
        raise exception using
            errcode = '0A000',
            message = pg_catalog.format('remote $ref is not supported: %s', abs),
            hint = 'validate.json_schema() resolves references within the schema document only: JSON Pointers, $anchor, $dynamicAnchor and embedded $id resources. Inline the referenced schema under $defs with its $id.';
    end if;
    if frag = '' or left(frag, 1) = '/' then
        ptr := ptr || frag;
    else
        ptr := ctx #>> array['anchors', uri || '#' || frag];
        -- $dynamicRef to a $dynamicAnchor: the outermost resource in the
        -- dynamic scope that has the same dynamic anchor wins.
        if dynamic and ctx #> array['dynanchors', uri || '#' || frag] is not null then
            for i in 1 .. coalesce(cardinality(dyn), 0) loop
                if ctx #> array['dynanchors', dyn[i] || '#' || frag] is not null then
                    ptr := ctx #>> array['dynanchors', dyn[i] || '#' || frag];
                    uri := dyn[i];
                    exit;
                end if;
            end loop;
        end if;
    end if;
    if ptr = '' then
        target := ctx -> 'root';
    elsif ptr is not null then
        -- RFC 6901: split on "/", then unescape ~1 and ~0 in each token
        toks := case when ptr = '/' then '{""}'::text[] else string_to_array(substr(ptr, 2), '/') end;
        if strpos(ptr, '~') > 0 then
            toks := array(select replace(replace(t, '~1', '/'), '~0', '~') from unnest(toks) t);
        end if;
        target := ctx #> ('{root}'::text[] || toks);
    end if;
    if target is null then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('$ref target not found in the schema: %s', abs);
    end if;
    tbase := coalesce(ctx #>> array['pbase', ptr], uri);
    resource := uri;
end;
$$;

-- "format" for the evaluator. Built-in names call their validator directly,
-- which skips the registry lookup and the dynamic EXECUTE in format(); the
-- built-in rows cannot be changed (_registry_guard), so this is the same
-- function format() would call. Other names go through format().
create function validate._js_format(name text, value text)
returns boolean
language plpgsql stable
set search_path = ''
as $$
begin
    return case name
        when 'date-time' then validate.rfc3339(value)
        when 'email' then validate.email(value)
        when 'uri' then validate.uri(value)
        when 'uuid' then validate.uuid(value)
        when 'date' then validate.rfc3339_date(value)
        when 'time' then validate.rfc3339_time(value)
        when 'hostname' then validate.hostname(value)
        when 'ipv4' then validate.ipv4(value)
        when 'ipv6' then validate.ipv6(value)
        when 'uri-reference' then validate.uri_reference(value)
        when 'duration' then validate.duration(value)
        when 'json-pointer' then validate.json_pointer(value)
        when 'relative-json-pointer' then validate.relative_json_pointer(value)
        when 'uri-template' then validate.uri_template(value)
        when 'iri' then validate.iri(value)
        when 'iri-reference' then validate.iri_reference(value)
        when 'idn-hostname' then validate.idn_hostname(value)
        when 'idn-email' then validate.idn_email(value)
        when 'regex' then validate.regex(value)
        else validate.format(name, value)
    end;
end;
$$;

-- Evaluate schema sch against instance inst. Returns validity, the property
-- names and array indices this schema evaluated at this instance location
-- (for unevaluatedProperties / unevaluatedItems, collected only when the
-- schema has one of them), and, when errs, the errors as a jsonb array of
-- {instanceLocation, keywordLocation, keyword, error}. Without errs it stops
-- at the first failure.
--
-- Each group of keywords is skipped with one ?| test when the schema has none
-- of them, and loops avoid SQL queries where an index loop over the jsonb
-- array does the same: those two account for most of the cost of a
-- subschema.
create function validate._js_eval(
    inst jsonb,
    sch jsonb,
    ctx jsonb,
    base text,
    dyn text[],
    iloc text,
    kloc text,
    depth int,
    errs boolean,
    out valid boolean,
    out props text[],
    out items int[],
    out errors jsonb
)
language plpgsql stable
set search_path = ''
as $$
declare
    t      text := jsonb_typeof(inst);
    st     text := jsonb_typeof(sch);
    annot  boolean;
    r      record;
    tg     record;
    k      text;
    v      jsonb;
    i      int;
    n      int;
    cnt    int;
    num    numeric;
    lim    numeric;
    s      text;
    ok     boolean;
    sub    jsonb;
    pobj   jsonb;
    ppobj  jsonb;
    found_ boolean;
    branch_errors jsonb;
begin
    valid := true;
    props := '{}';
    items := '{}';
    errors := '[]';

    if depth > 256 then
        raise exception using
            errcode = '54001',
            message = 'JSON Schema evaluation is nested more than 256 levels deep',
            hint = 'The schema probably has a $ref cycle that does not consume the instance.';
    end if;

    if st = 'boolean' then
        if sch = 'false'::jsonb then
            valid := false;
            if errs then
                errors := jsonb_build_array(jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc,
                          'keyword', 'false', 'error', 'the false schema allows no value'));
            end if;
        end if;
        return;
    elsif st <> 'object' then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('invalid JSON Schema at %s: a schema must be an object or a boolean', coalesce(nullif(kloc, ''), '/'));
    end if;

    annot := (ctx ->> 'annot')::boolean;

    -- A new schema resource
    if sch ? '$id' and jsonb_typeof(sch -> '$id') = 'string' then
        base := split_part(validate._js_resolve(base, sch ->> '$id'), '#', 1);
    end if;
    if dyn is null or cardinality(dyn) = 0 or dyn[cardinality(dyn)] <> base then
        dyn := coalesce(dyn, '{}') || base;
    end if;

    -- $ref and $dynamicRef: evaluate the target in place
    if sch ?| '{$ref,$dynamicRef}'::text[] then
        foreach k in array array['$ref', '$dynamicRef'] loop
            if jsonb_typeof(sch -> k) = 'string' then
                tg := validate._js_target(ctx, base, sch ->> k, k = '$dynamicRef', dyn);
                r := validate._js_eval(inst, tg.target, ctx, tg.tbase,
                                       -- the target's resource joins the dynamic scope, unless
                                       -- the target is a resource itself ($id), which adds itself
                                       case when dyn[cardinality(dyn)] = tg.resource or jsonb_typeof(tg.target -> '$id') = 'string'
                                            then dyn else dyn || tg.resource end,
                                       iloc, kloc || '/' || k, depth + 1, errs);
                if r.valid then
                    if annot then
                        props := props || r.props;
                        items := items || r.items;
                    end if;
                else
                    valid := false;
                    errors := errors || r.errors;
                    if not errs then return; end if;
                end if;
            end if;
        end loop;
    end if;

    -- type, enum, const
    if sch ? 'type' then
        v := sch -> 'type';
        ok := false;
        if jsonb_typeof(v) = 'string' then
            k := v #>> '{}';
            ok := k = t or (k = 'integer' and case when t = 'number' then (inst #>> '{}')::numeric % 1 = 0 else false end);
        elsif jsonb_typeof(v) = 'array' then
            for i in 0 .. jsonb_array_length(v) - 1 loop
                k := v ->> i;
                if k = t or (k = 'integer' and case when t = 'number' then (inst #>> '{}')::numeric % 1 = 0 else false end) then
                    ok := true;
                    exit;
                end if;
            end loop;
        end if;
        if not ok then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/type',
                      'keyword', 'type', 'error', pg_catalog.format('expected %s, got %s', v, t));
        end if;
    end if;
    if sch ? 'enum' then
        -- JSON equality: for a scalar, containment in the array is equality
        -- with one of its elements (1 = 1.0); objects and arrays compare whole.
        if t in ('object', 'array') or jsonb_typeof(sch -> 'enum') <> 'array' then
            ok := exists (select 1 from jsonb_array_elements(sch -> 'enum') e where e = inst);
        else
            ok := (sch -> 'enum') @> jsonb_build_array(inst);
        end if;
        if not ok then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/enum',
                      'keyword', 'enum', 'error', 'value is not one of the enum values');
        end if;
    end if;
    if sch ? 'const' and inst is distinct from sch -> 'const' then
        valid := false;
        if not errs then return; end if;
        errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/const',
                  'keyword', 'const', 'error', pg_catalog.format('value must be %s', sch -> 'const'));
    end if;

    -- numbers
    if t = 'number' and sch ?| '{multipleOf,maximum,exclusiveMaximum,minimum,exclusiveMinimum}'::text[] then
        num := (inst #>> '{}')::numeric;
        foreach k in array array['multipleOf', 'maximum', 'exclusiveMaximum', 'minimum', 'exclusiveMinimum'] loop
            if jsonb_typeof(sch -> k) = 'number' then
                lim := (sch ->> k)::numeric;
                ok := case k
                    when 'multipleOf' then num % lim = 0
                    when 'maximum' then num <= lim
                    when 'exclusiveMaximum' then num < lim
                    when 'minimum' then num >= lim
                    else num > lim
                end;
                if not ok then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/' || k,
                              'keyword', k, 'error', pg_catalog.format('%s does not satisfy %s %s', num, k, lim));
                end if;
            end if;
        end loop;
    end if;

    -- strings
    if t = 'string' and sch ?| '{maxLength,minLength,pattern,format}'::text[] then
        s := inst #>> '{}';
        if jsonb_typeof(sch -> 'maxLength') = 'number' and char_length(s) > (sch ->> 'maxLength')::numeric then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/maxLength',
                      'keyword', 'maxLength', 'error', pg_catalog.format('string is longer than %s characters', sch ->> 'maxLength'));
        end if;
        if jsonb_typeof(sch -> 'minLength') = 'number' and char_length(s) < (sch ->> 'minLength')::numeric then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/minLength',
                      'keyword', 'minLength', 'error', pg_catalog.format('string is shorter than %s characters', sch ->> 'minLength'));
        end if;
        if jsonb_typeof(sch -> 'pattern') = 'string' and s !~ validate._js_regex(sch ->> 'pattern') then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/pattern',
                      'keyword', 'pattern', 'error', pg_catalog.format('string does not match pattern %s', sch ->> 'pattern'));
        end if;
        -- format assertion; an unknown name raises
        if jsonb_typeof(sch -> 'format') = 'string' and not validate._js_format(sch ->> 'format', s) then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/format',
                      'keyword', 'format', 'error', pg_catalog.format('string is not a valid %s', sch ->> 'format'));
        end if;
    end if;

    -- in-place applicators
    if sch ?| '{allOf,anyOf,oneOf,not,if}'::text[] then
        if jsonb_typeof(sch -> 'allOf') = 'array' then
            for i in 0 .. jsonb_array_length(sch -> 'allOf') - 1 loop
                r := validate._js_eval(inst, sch -> 'allOf' -> i, ctx, base, dyn, iloc, kloc || '/allOf/' || i, depth + 1, errs);
                if r.valid then
                    if annot then
                        props := props || r.props;
                        items := items || r.items;
                    end if;
                else
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if jsonb_typeof(sch -> 'anyOf') = 'array' then
            ok := false;
            branch_errors := '[]';
            for i in 0 .. jsonb_array_length(sch -> 'anyOf') - 1 loop
                r := validate._js_eval(inst, sch -> 'anyOf' -> i, ctx, base, dyn, iloc, kloc || '/anyOf/' || i, depth + 1, errs);
                if r.valid then
                    ok := true;
                    if not annot then exit; end if;
                    props := props || r.props;
                    items := items || r.items;
                else
                    branch_errors := branch_errors || r.errors;
                end if;
            end loop;
            if not ok then
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/anyOf',
                          'keyword', 'anyOf', 'error', 'value does not match any schema in anyOf') || branch_errors;
            end if;
        end if;
        if jsonb_typeof(sch -> 'oneOf') = 'array' then
            cnt := 0;
            branch_errors := '[]';
            for i in 0 .. jsonb_array_length(sch -> 'oneOf') - 1 loop
                r := validate._js_eval(inst, sch -> 'oneOf' -> i, ctx, base, dyn, iloc, kloc || '/oneOf/' || i, depth + 1, errs);
                if r.valid then
                    cnt := cnt + 1;
                    if cnt = 1 and annot then
                        sub := jsonb_build_object('p', r.props, 'i', r.items);
                    end if;
                    -- a second match decides the result
                    if cnt > 1 and not errs then exit; end if;
                else
                    branch_errors := branch_errors || r.errors;
                end if;
            end loop;
            if cnt = 1 then
                if annot then
                    props := props || array(select jsonb_array_elements_text(sub -> 'p'));
                    items := items || array(select x::int from jsonb_array_elements_text(sub -> 'i') x);
                end if;
            else
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/oneOf',
                          'keyword', 'oneOf', 'error', pg_catalog.format('value matches %s schemas in oneOf, expected exactly 1', cnt))
                          || case when cnt = 0 then branch_errors else '[]' end;
            end if;
        end if;
        if sch ? 'not' then
            r := validate._js_eval(inst, sch -> 'not', ctx, base, dyn, iloc, kloc || '/not', depth + 1, false);
            if r.valid then
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/not',
                          'keyword', 'not', 'error', 'value must not match the schema in not');
            end if;
        end if;
        if sch ? 'if' then
            r := validate._js_eval(inst, sch -> 'if', ctx, base, dyn, iloc, kloc || '/if', depth + 1, false);
            if r.valid then
                if annot then
                    props := props || r.props;
                    items := items || r.items;
                end if;
                k := 'then';
            else
                k := 'else';
            end if;
            if sch ? k then
                r := validate._js_eval(inst, sch -> k, ctx, base, dyn, iloc, kloc || '/' || k, depth + 1, errs);
                if r.valid then
                    if annot then
                        props := props || r.props;
                        items := items || r.items;
                    end if;
                else
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end if;
        end if;
    end if;

    -- objects
    if t = 'object' and sch ?| '{maxProperties,minProperties,required,dependentRequired,dependentSchemas,properties,patternProperties,additionalProperties,propertyNames,unevaluatedProperties}'::text[] then
        if jsonb_typeof(sch -> 'maxProperties') = 'number' or jsonb_typeof(sch -> 'minProperties') = 'number' then
            n := (select count(*) from jsonb_object_keys(inst));
            if jsonb_typeof(sch -> 'maxProperties') = 'number' and n > (sch ->> 'maxProperties')::numeric
               or jsonb_typeof(sch -> 'minProperties') = 'number' and n < (sch ->> 'minProperties')::numeric then
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation',
                          kloc || case when n > coalesce((sch ->> 'maxProperties')::numeric, n) then '/maxProperties' else '/minProperties' end,
                          'keyword', case when n > coalesce((sch ->> 'maxProperties')::numeric, n) then 'maxProperties' else 'minProperties' end,
                          'error', pg_catalog.format('object has %s properties', n));
            end if;
        end if;
        if jsonb_typeof(sch -> 'required') = 'array' then
            v := sch -> 'required';
            for i in 0 .. jsonb_array_length(v) - 1 loop
                k := v ->> i;
                if not inst ? k then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/required',
                              'keyword', 'required', 'error', pg_catalog.format('required property %s is missing', to_jsonb(k)));
                end if;
            end loop;
        end if;
        if jsonb_typeof(sch -> 'dependentRequired') = 'object' then
            for k, v in select e.key, e.value from jsonb_each(sch -> 'dependentRequired') e where inst ? e.key loop
                for s in select x from jsonb_array_elements_text(v) x where not inst ? x loop
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || jsonb_build_object('instanceLocation', iloc,
                              'keywordLocation', kloc || '/dependentRequired/' || validate._js_token(k),
                              'keyword', 'dependentRequired', 'error', pg_catalog.format('property %s is required when %s is present', to_jsonb(s), to_jsonb(k)));
                end loop;
            end loop;
        end if;
        if jsonb_typeof(sch -> 'dependentSchemas') = 'object' then
            for k, v in select e.key, e.value from jsonb_each(sch -> 'dependentSchemas') e where inst ? e.key loop
                r := validate._js_eval(inst, v, ctx, base, dyn, iloc, kloc || '/dependentSchemas/' || validate._js_token(k), depth + 1, errs);
                if r.valid then
                    if annot then
                        props := props || r.props;
                        items := items || r.items;
                    end if;
                else
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if sch ?| '{properties,patternProperties,additionalProperties,propertyNames}'::text[] then
            pobj := case when jsonb_typeof(sch -> 'properties') = 'object' then sch -> 'properties' end;
            ppobj := case when jsonb_typeof(sch -> 'patternProperties') = 'object' then sch -> 'patternProperties' end;
            for k, v in select e.key, e.value from jsonb_each(inst) e loop
                found_ := false;
                sub := pobj -> k;
                if sub is not null then
                    found_ := true;
                    r := validate._js_eval(v, sub, ctx, base, dyn, iloc || '/' || validate._js_token(k),
                                           kloc || '/properties/' || validate._js_token(k), depth + 1, errs);
                    if not r.valid then
                        valid := false;
                        if not errs then return; end if;
                        errors := errors || r.errors;
                    end if;
                end if;
                if ppobj is not null then
                    for s, sub in select e.key, e.value from jsonb_each(ppobj) e
                                  where k ~ validate._js_regex(e.key) loop
                        found_ := true;
                        r := validate._js_eval(v, sub, ctx, base, dyn, iloc || '/' || validate._js_token(k),
                                               kloc || '/patternProperties/' || validate._js_token(s), depth + 1, errs);
                        if not r.valid then
                            valid := false;
                            if not errs then return; end if;
                            errors := errors || r.errors;
                        end if;
                    end loop;
                end if;
                if not found_ and sch ? 'additionalProperties' then
                    found_ := true;
                    r := validate._js_eval(v, sch -> 'additionalProperties', ctx, base, dyn, iloc || '/' || validate._js_token(k),
                                           kloc || '/additionalProperties', depth + 1, errs);
                    if not r.valid then
                        valid := false;
                        if not errs then return; end if;
                        errors := errors || r.errors;
                    end if;
                end if;
                if found_ and annot then
                    props := props || k;
                end if;
                if sch ? 'propertyNames' then
                    r := validate._js_eval(to_jsonb(k), sch -> 'propertyNames', ctx, base, dyn, iloc,
                                           kloc || '/propertyNames', depth + 1, errs);
                    if not r.valid then
                        valid := false;
                        if not errs then return; end if;
                        errors := errors || r.errors;
                    end if;
                end if;
            end loop;
        end if;
        if sch ? 'unevaluatedProperties' then
            for k, v in select e.key, e.value from jsonb_each(inst) e where not e.key = any(props) loop
                r := validate._js_eval(v, sch -> 'unevaluatedProperties', ctx, base, dyn, iloc || '/' || validate._js_token(k),
                                       kloc || '/unevaluatedProperties', depth + 1, errs);
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
                props := props || k;
            end loop;
        end if;
    end if;

    -- arrays
    if t = 'array' and sch ?| '{maxItems,minItems,uniqueItems,prefixItems,items,contains,unevaluatedItems}'::text[] then
        n := jsonb_array_length(inst);
        if jsonb_typeof(sch -> 'maxItems') = 'number' and n > (sch ->> 'maxItems')::numeric
           or jsonb_typeof(sch -> 'minItems') = 'number' and n < (sch ->> 'minItems')::numeric then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation',
                      kloc || case when n > coalesce((sch ->> 'maxItems')::numeric, n) then '/maxItems' else '/minItems' end,
                      'keyword', case when n > coalesce((sch ->> 'maxItems')::numeric, n) then 'maxItems' else 'minItems' end,
                      'error', pg_catalog.format('array has %s items', n));
        end if;
        if n > 1 and sch -> 'uniqueItems' = 'true'::jsonb
           and (select count(distinct e) from jsonb_array_elements(inst) e) < n then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/uniqueItems',
                      'keyword', 'uniqueItems', 'error', 'array items are not unique');
        end if;
        cnt := 0;
        if jsonb_typeof(sch -> 'prefixItems') = 'array' then
            cnt := least(n, jsonb_array_length(sch -> 'prefixItems'));
            for i in 0 .. cnt - 1 loop
                r := validate._js_eval(inst -> i, sch -> 'prefixItems' -> i, ctx, base, dyn, iloc || '/' || i,
                                       kloc || '/prefixItems/' || i, depth + 1, errs);
                if annot then
                    items := items || i;
                end if;
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if sch ? 'items' then
            sub := sch -> 'items';
            for i in cnt .. n - 1 loop
                r := validate._js_eval(inst -> i, sub, ctx, base, dyn, iloc || '/' || i,
                                       kloc || '/items', depth + 1, errs);
                if annot then
                    items := items || i;
                end if;
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if sch ? 'contains' then
            cnt := 0;
            sub := sch -> 'contains';
            for i in 0 .. n - 1 loop
                r := validate._js_eval(inst -> i, sub, ctx, base, dyn, iloc || '/' || i,
                                       kloc || '/contains', depth + 1, false);
                if r.valid then
                    cnt := cnt + 1;
                    if annot then
                        items := items || i;
                    end if;
                end if;
            end loop;
            if cnt < coalesce((sch ->> 'minContains')::numeric, 1)
               or (jsonb_typeof(sch -> 'maxContains') = 'number' and cnt > (sch ->> 'maxContains')::numeric) then
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/contains',
                          'keyword', 'contains', 'error', pg_catalog.format('array has %s items matching contains, expected %s to %s',
                          cnt, coalesce(sch ->> 'minContains', '1'), coalesce(sch ->> 'maxContains', 'any number')));
            end if;
        end if;
        if sch ? 'unevaluatedItems' then
            for i in 0 .. n - 1 loop
                if not i = any(items) then
                    r := validate._js_eval(inst -> i, sch -> 'unevaluatedItems', ctx, base, dyn, iloc || '/' || i,
                                           kloc || '/unevaluatedItems', depth + 1, errs);
                    if not r.valid then
                        valid := false;
                        if not errs then return; end if;
                        errors := errors || r.errors;
                    end if;
                end if;
            end loop;
            items := items || array(select generate_series(0, n - 1));
        end if;
    end if;
end;
$$;

-- Whether doc is valid against schema (JSON Schema Draft 2020-12, with
-- format assertion through the registry).
create function validate.json_schema(doc jsonb, schema jsonb)
returns boolean
language plpgsql stable strict
set search_path = ''
as $$
declare
    r record;
begin
    r := validate._js_eval(doc, schema, validate._js_context(schema), validate._js_default_base(),
                           '{}', '', '', 0, false);
    return r.valid;
end;
$$;

-- Why doc is not valid against schema: one row per error. No rows means
-- valid. instance_location and keyword_location are JSON Pointers (the
-- keyword location follows $ref, as in the specification's output formats).
create function validate.json_schema_errors(doc jsonb, schema jsonb)
returns table (
    instance_location text,
    keyword_location text,
    keyword text,
    message text
)
language plpgsql stable strict
set search_path = ''
as $$
declare
    r record;
begin
    r := validate._js_eval(doc, schema, validate._js_context(schema), validate._js_default_base(),
                           '{}', '', '', 0, true);
    return query
        select e ->> 'instanceLocation', e ->> 'keywordLocation', e ->> 'keyword', e ->> 'error'
        from jsonb_array_elements(r.errors) e;
end;
$$;

comment on function validate.json_schema(jsonb, jsonb) is 'Validate a JSON document against a JSON Schema (Draft 2020-12, format assertion through the registry).';
comment on function validate.json_schema_errors(jsonb, jsonb) is 'The errors that make a document invalid against a JSON Schema, one row each.';

-- ----------------------------------------------------------------------------
-- Named schemas
-- ----------------------------------------------------------------------------
--
-- A registry of JSON Schemas by name, with the same security model as the
-- format registry (docs/registry.md): everyone can read it and validate
-- against it; registering needs INSERT on validate.schemas and EXECUTE on
-- register_schema, neither granted to PUBLIC; _registry_guard lets a role
-- change only its own entries. The guard also checks each schema and stores
-- its compiled form (the full index, _js_compile), so json_schema_named
-- skips the indexing that json_schema does on every call.

-- Check a schema for registration and return its compiled form: the
-- evaluation context of _js_context, with the full index when the schema
-- needs one. Raises for what json_schema would raise only when evaluation
-- reaches it: a
-- subschema that is neither an object nor a boolean (22023), a remote $ref
-- (0A000), a $ref whose target is not in the document (22023), and a pattern
-- that Postgres cannot compile (2201B) or that uses \p{...} (0A000). The
-- error message names the keyword's location in the schema.
create function validate._js_compile_named(schema jsonb)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
    ctx  jsonb;
    w    record;
    loc  text;
    msg  text;
    hint text;
    code text;
begin
    if schema is null or jsonb_typeof(schema) not in ('object', 'boolean') then
        raise exception using
            errcode = '22023',
            message = 'invalid JSON Schema at /: a schema must be an object or a boolean';
    end if;
    ctx := validate._js_compile(schema);
    for w in select * from validate._js_walk(schema) loop
        loc := coalesce(nullif(w.ptr, ''), '/');
        if jsonb_typeof(w.node) not in ('object', 'boolean') then
            raise exception using
                errcode = '22023',
                message = pg_catalog.format('invalid JSON Schema at %s: a schema must be an object or a boolean', loc);
        end if;
        continue when jsonb_typeof(w.node) <> 'object';
        begin
            if jsonb_typeof(w.node -> '$ref') = 'string' then
                loc := w.ptr || '/$ref';
                perform validate._js_target(ctx, w.base, w.node ->> '$ref', false, '{}');
            end if;
            if jsonb_typeof(w.node -> '$dynamicRef') = 'string' then
                loc := w.ptr || '/$dynamicRef';
                perform validate._js_target(ctx, w.base, w.node ->> '$dynamicRef', false, '{}');
            end if;
            if jsonb_typeof(w.node -> 'pattern') = 'string' then
                loc := w.ptr || '/pattern';
                perform '' ~ validate._js_regex(w.node ->> 'pattern');
            end if;
            if jsonb_typeof(w.node -> 'patternProperties') = 'object' then
                loc := w.ptr || '/patternProperties';
                perform '' ~ validate._js_regex(k) from jsonb_object_keys(w.node -> 'patternProperties') k;
            end if;
        exception when others then
            get stacked diagnostics code = returned_sqlstate, msg = message_text, hint = pg_exception_hint;
            if hint = '' then
                raise exception using
                    errcode = code,
                    message = pg_catalog.format('invalid JSON Schema at %s: %s', loc, msg);
            end if;
            raise exception using
                errcode = code,
                message = pg_catalog.format('invalid JSON Schema at %s: %s', loc, msg),
                hint = hint;
        end;
    end loop;
    return validate._js_context(schema);
end;
$$;

create table validate.schemas (
    name        text primary key,
    schema      jsonb not null,
    compiled    jsonb not null,
    description text,
    owner       name not null default current_user,
    created_at  timestamptz not null default now(),
    constraint schemas_name_check check (name ~ '^[A-Za-z][A-Za-z0-9_.-]{0,62}$')
);

comment on table validate.schemas is
    'Named JSON Schemas for validate.json_schema_named(), with their compiled form.';
comment on column validate.schemas.compiled is
    'The index of the schema (_js_compile), set by the trigger from schema. Do not write it.';

-- Keep the compiled form in the row, compressed, rather than in TOAST:
-- json_schema_named reads it on every call.
alter table validate.schemas alter column compiled set storage main;

-- The guard sets compiled from schema on every insert and update, so a row
-- never holds a stale compiled form. NOT NULL is checked after it runs.
create trigger schemas_guard
before insert or update or delete on validate.schemas
for each row execute function validate._registry_guard();

create trigger schemas_guard_truncate
before truncate on validate.schemas
for each statement execute function validate._registry_guard();

-- pg_dump keeps every registered schema. The compiled form is dumped too, and
-- recomputed by the trigger when the row is restored.
do $$
begin
    perform pg_catalog.pg_extension_config_dump('validate.schemas', '');
exception when feature_not_supported then
    null;
end;
$$;

-- Register a JSON Schema under a name. The schema is checked now (see
-- _js_compile_named), and every "format" it uses must be registered. The
-- caller needs INSERT on validate.schemas and EXECUTE on this function
-- (neither of which PUBLIC has), and becomes the entry's owner.
create function validate.register_schema(
    name text,
    schema jsonb,
    description text default null
)
returns void
language plpgsql
set search_path = ''
as $$
declare
    existing name;
    f        record;
begin
    if register_schema.name is null or register_schema.schema is null then
        raise exception using
            errcode = '22004',
            message = 'name and schema are required';
    end if;
    if register_schema.name !~ '^[A-Za-z][A-Za-z0-9_.-]{0,62}$' then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('invalid schema name: %s', pg_catalog.quote_literal(register_schema.name)),
            hint = 'A name starts with a letter and has at most 63 letters, digits, "_", "-" or ".".';
    end if;
    select s.owner into existing
    from validate.schemas s
    where s.name = register_schema.name;
    if found then
        raise exception using
            errcode = '42710',
            message = pg_catalog.format('JSON schema "%s" is already registered (owner %s)', register_schema.name, existing),
            hint = 'Call validate.unregister_schema() first to replace it.';
    end if;
    -- An unknown format would raise on first use; say so now.
    select w.ptr, w.node ->> 'format' as fmt into f
    from validate._js_walk(register_schema.schema) w
    where jsonb_typeof(w.node -> 'format') = 'string'
      and not exists (select 1 from validate.formats x where x.name = w.node ->> 'format')
    limit 1;
    if found then
        raise exception using
            errcode = '42704',
            message = pg_catalog.format('invalid JSON Schema at %s/format: format "%s" does not exist', f.ptr, f.fmt),
            hint = 'validate.list_formats() lists the registered formats.';
    end if;
    -- _registry_guard checks the schema and compiles it.
    insert into validate.schemas (name, schema, compiled, description)
    values (register_schema.name, register_schema.schema, 'null', register_schema.description);
end;
$$;

-- Remove a named schema. The caller needs DELETE on validate.schemas and must
-- own the entry (or have the privileges of its owner or of the extension
-- owner).
create function validate.unregister_schema(name text)
returns void
language plpgsql
set search_path = ''
as $$
begin
    if not exists (select 1 from validate.schemas s where s.name = unregister_schema.name) then
        raise exception using
            errcode = '42704',
            message = pg_catalog.format('JSON schema "%s" does not exist', unregister_schema.name),
            hint = 'validate.list_schemas() lists the registered schemas.';
    end if;
    -- _registry_guard checks ownership; DELETE privilege is checked here.
    delete from validate.schemas s
    where s.name = unregister_schema.name;
end;
$$;

-- Every named schema.
create function validate.list_schemas()
returns table (
    name        text,
    schema      jsonb,
    description text,
    owner       name
)
language sql stable
set search_path = ''
as $$
    select s.name, s.schema, s.description, s.owner
    from validate.schemas s
    order by s.name
$$;

-- The compiled form of a named schema, or 42704.
create function validate._js_named(name text)
returns jsonb
language plpgsql stable strict
set search_path = ''
as $$
declare
    c jsonb;
begin
    select s.compiled into c
    from validate.schemas s
    where s.name = _js_named.name;
    if not found then
        raise exception using
            errcode = '42704',
            message = pg_catalog.format('JSON schema "%s" does not exist', _js_named.name),
            hint = 'validate.list_schemas() lists the registered schemas.';
    end if;
    return c;
end;
$$;

-- Whether doc is valid against the named schema. The same evaluation as
-- json_schema(doc, schema), from the compiled form. A separate name rather
-- than an overload json_schema(jsonb, text): with an untyped literal,
-- json_schema(doc, '{...}') would resolve to the text overload (Postgres
-- prefers the string category for unknown arguments) and look the schema up
-- by name. STABLE: the registry can change.
create function validate.json_schema_named(doc jsonb, name text)
returns boolean
language plpgsql stable strict
set search_path = ''
as $$
declare
    c jsonb := validate._js_named(json_schema_named.name);
    r record;
begin
    r := validate._js_eval(doc, c -> 'root', c, validate._js_default_base(), '{}', '', '', 0, false);
    return r.valid;
end;
$$;

-- Why doc is not valid against the named schema, as json_schema_errors.
create function validate.json_schema_named_errors(doc jsonb, name text)
returns table (
    instance_location text,
    keyword_location text,
    keyword text,
    message text
)
language plpgsql stable strict
set search_path = ''
as $$
declare
    c jsonb := validate._js_named(json_schema_named_errors.name);
    r record;
begin
    r := validate._js_eval(doc, c -> 'root', c, validate._js_default_base(), '{}', '', '', 0, true);
    return query
        select e ->> 'instanceLocation', e ->> 'keywordLocation', e ->> 'keyword', e ->> 'error'
        from jsonb_array_elements(r.errors) e;
end;
$$;

comment on function validate.register_schema(text, jsonb, text) is 'Register a JSON Schema under a name, checked and compiled. Not granted to PUBLIC.';
comment on function validate.unregister_schema(text) is 'Remove a named JSON Schema you own. Not granted to PUBLIC.';
comment on function validate.list_schemas() is 'List the named JSON Schemas.';
comment on function validate.json_schema_named(jsonb, text) is 'Validate a JSON document against a named JSON Schema (STABLE, SECURITY INVOKER).';
comment on function validate.json_schema_named_errors(jsonb, text) is 'The errors that make a document invalid against a named JSON Schema, one row each.';

-- ============================================================================
-- Privileges
-- ============================================================================

grant usage on schema validate to public;
revoke all on validate.formats from public;
grant select on validate.formats to public;
revoke all on validate.schemas from public;
grant select on validate.schemas to public;

-- Validators, helpers, format(), list_formats(), the json_schema functions
-- and list_schemas() keep the default EXECUTE for PUBLIC (they are SECURITY
-- INVOKER and call the helpers as the caller). Registration is for the owner
-- and the roles it grants:
--
--   grant execute on function
--       validate.register_format(text, regprocedure, text),
--       validate.unregister_format(text)
--   to app_admin;
--   grant insert, delete on validate.formats to app_admin;
--
--   grant execute on function
--       validate.register_schema(text, jsonb, text),
--       validate.unregister_schema(text)
--   to app_admin;
--   grant insert, delete on validate.schemas to app_admin;
revoke all on function
    validate.register_format(text, regprocedure, text),
    validate.unregister_format(text),
    validate.register_schema(text, jsonb, text),
    validate.unregister_schema(text)
from public;
