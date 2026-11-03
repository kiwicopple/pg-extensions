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
 *   - Embedded code lists (ISO 3166, ISO 4217, ISO 639, the IBAN registry)
 *     are snapshots; docs/reference/international.md and financial.md name
 *     the snapshot. Changing a list is a new extension version.
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

-- Host name, RFC 1123 §2.1 (relaxing RFC 952): dot-separated labels of
-- letters, digits and hyphens, 1 to 63 characters each (RFC 1035 §2.3.4),
-- starting and ending with a letter or digit; at most 253 characters in
-- total (255 octets on the wire). Either case. A single label is a valid
-- host name. No trailing dot, no underscore, ASCII only (convert IDNs to
-- A-labels, xn--..., first).
create function validate.hostname(value text)
returns boolean
language sql immutable strict parallel safe
set search_path = ''
as $$
    select octet_length(value) <= 253
       and value ~ '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
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

-- RFC 3986 parser shared by uri, uri_reference and url. kind is 'uri'
-- (§3 URI: scheme required), 'reference' (§4.1 URI-reference: a URI or a
-- relative reference) or 'url' (an http or https URI, see validate.url).
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
-- withdrawn codes are rejected.
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

-- ISO 3166-1 alpha-3, the 249 officially assigned codes, uppercase.
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
-- currency), uppercase. Historic codes (List Three) are rejected.
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
             ' TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB'
             ' XBC XBD XCD XCG XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG ',
             ' ' || value || ' ') > 0
$$;

-- ISO 639-1 two-letter language code, the 183 current codes, lowercase
-- (bh, deprecated in 2021, is rejected). Not BCP 47 language tags (en-US):
-- see docs/roadmap.md.
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
-- check digits are not checked.
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
--   - _formats_guard (a trigger, so it also covers direct DML) protects the
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
    select '{base64,base64url,card_number,country_code,country_code_alpha3,cron,currency_code,domain,duration,e164,email,git_sha,hex,hostname,iban,ipv4,ipv6,isbn,isbn10,isbn13,iso8601,json_pointer,language_code,luhn,mac,nanoid,port,rfc3339,rfc3339_date,rfc3339_time,semver,slug,ulid,uri,uri_reference,url,uuid}'::text[]
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
comment on function validate.hostname(text) is 'Host name (RFC 1123 labels, at most 253 characters).';
comment on function validate.domain(text) is 'Domain name with at least two labels and an alphabetic or xn-- top-level domain.';
comment on function validate.email(text) is 'Email address syntax (RFC 5321/5322 addr-spec, ASCII); not deliverability.';
comment on function validate.uri(text) is 'RFC 3986 URI with any scheme.';
comment on function validate.uri_reference(text) is 'RFC 3986 URI-reference: a URI or a relative reference.';
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
    ('json-pointer', 'validate', 'json_pointer', true, 'JSON Schema "json-pointer": validate.json_pointer (RFC 6901).');

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

create function validate._formats_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'TRUNCATE' then
        raise exception using
            errcode = '42501',
            message = 'validate.formats cannot be truncated',
            hint = 'Use validate.unregister_format() for each custom format.';
    end if;
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
    if tg_op in ('UPDATE', 'DELETE') and not validate._can_manage(old.owner) then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('format "%s" belongs to role %s', old.name, old.owner),
            hint = 'Only its owner, a role with the owner''s privileges, or the extension owner can change it.';
    end if;
    if tg_op in ('INSERT', 'UPDATE') and not validate._can_manage(new.owner) then
        raise exception using
            errcode = '42501',
            message = pg_catalog.format('cannot register a format on behalf of role %s', new.owner);
    end if;
    return case when tg_op = 'DELETE' then old else new end;
end;
$$;

-- Created after the built-in rows, so this file can insert them.
create trigger formats_guard
before insert or update or delete on validate.formats
for each row execute function validate._formats_guard();

create trigger formats_guard_truncate
before truncate on validate.formats
for each statement execute function validate._formats_guard();

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
    -- _formats_guard checks ownership; DELETE privilege is checked here.
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
-- A JSON Schema evaluator in PL/pgSQL (docs/json-schema.md). The schema is
-- first indexed (_js_compile: base URIs, $id, $anchor, $dynamicAnchor), then
-- evaluated recursively (_js_eval). "format" is an assertion that calls
-- validate.format(), so registered formats work and unknown ones raise.
-- Everything here is SECURITY INVOKER; the evaluator is STABLE because format
-- dispatch reads the registry.

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

-- The value at a JSON Pointer in doc, or null.
create function validate._js_ptr_get(doc jsonb, ptr text)
returns jsonb
language sql immutable strict parallel safe
set search_path = ''
as $$
    select case when ptr = '' then doc else doc #> (
        select array_agg(replace(replace(t, '~1', '/'), '~0', '~') order by n)
        from unnest(string_to_array(substr(ptr, 2), '/')) with ordinality as u(t, n))
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

-- Index a schema document: every subschema the applicator keywords reach,
-- with the base URI in effect at its parent ("pbase"), the resources ($id ->
-- pointer), plain-name anchors and dynamic anchors, and whether any
-- unevaluated* keyword needs annotations.
create function validate._js_compile(schema jsonb)
returns jsonb
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

-- The evaluation context for a schema: the full index when the schema has
-- identifiers, references or unevaluated* keywords, otherwise (the common
-- case) a minimal one, which saves the index walk.
create function validate._js_context(schema jsonb)
returns jsonb
language plpgsql immutable strict parallel safe
set search_path = ''
as $$
declare
    txt text := schema::text;
begin
    if txt ~ '"[$](id|anchor|dynamicAnchor|ref|dynamicRef)"' or txt ~ '"unevaluated(Properties|Items)"' then
        return validate._js_compile(schema);
    end if;
    return jsonb_build_object('root', schema, 'pbase', '{}'::jsonb,
                              'ids', jsonb_build_object(validate._js_default_base(), ''),
                              'anchors', '{}'::jsonb, 'dynanchors', '{}'::jsonb, 'annot', false);
end;
$$;

-- Resolve a $ref or $dynamicRef to (target schema, base URI at its parent,
-- the resource it belongs to). Remote references raise.
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
    abs  text := validate._js_resolve(base, ref);
    pos  int := strpos(abs, '#');
    uri  text;
    frag text;
    ptr  text;
begin
    if pos > 0 then
        uri := left(abs, pos - 1);
        frag := validate._js_pct_decode(substr(abs, pos + 1));
    else
        uri := abs;
        frag := '';
    end if;
    if not (ctx -> 'ids') ? uri then
        raise exception using
            errcode = '0A000',
            message = pg_catalog.format('remote $ref is not supported: %s', abs),
            hint = 'validate.json_schema() resolves references within the schema document only: JSON Pointers, $anchor, $dynamicAnchor and embedded $id resources. Inline the referenced schema under $defs with its $id.';
    end if;
    if frag = '' or left(frag, 1) = '/' then
        ptr := (ctx -> 'ids' ->> uri) || frag;
    else
        ptr := ctx -> 'anchors' ->> (uri || '#' || frag);
        -- $dynamicRef to a $dynamicAnchor: the outermost resource in the
        -- dynamic scope that has the same dynamic anchor wins.
        if dynamic and (ctx -> 'dynanchors') ? (uri || '#' || frag) then
            for i in 1 .. coalesce(cardinality(dyn), 0) loop
                if (ctx -> 'dynanchors') ? (dyn[i] || '#' || frag) then
                    ptr := ctx -> 'dynanchors' ->> (dyn[i] || '#' || frag);
                    uri := dyn[i];
                    exit;
                end if;
            end loop;
        end if;
    end if;
    target := case when ptr is not null then validate._js_ptr_get(ctx -> 'root', ptr) end;
    if target is null then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('$ref target not found in the schema: %s', abs);
    end if;
    tbase := coalesce(ctx -> 'pbase' ->> ptr, uri);
    resource := uri;
end;
$$;

-- Evaluate schema sch against instance inst. Returns validity, the property
-- names and array indices this schema evaluated at this instance location
-- (for unevaluatedProperties / unevaluatedItems), and, when errs, the errors
-- as a jsonb array of {instanceLocation, keywordLocation, keyword, error}.
-- Without errs it stops at the first failure.
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
    annot  boolean := (ctx ->> 'annot')::boolean;
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
    pats   text[];
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

    if jsonb_typeof(sch) = 'boolean' then
        if sch = 'false'::jsonb then
            valid := false;
            if errs then
                errors := jsonb_build_array(jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc,
                          'keyword', 'false', 'error', 'the false schema allows no value'));
            end if;
        end if;
        return;
    elsif jsonb_typeof(sch) <> 'object' then
        raise exception using
            errcode = '22023',
            message = pg_catalog.format('invalid JSON Schema at %s: a schema must be an object or a boolean', coalesce(nullif(kloc, ''), '/'));
    end if;

    -- A new schema resource
    if jsonb_typeof(sch -> '$id') = 'string' then
        base := split_part(validate._js_resolve(base, sch ->> '$id'), '#', 1);
    end if;
    if dyn is null or cardinality(dyn) = 0 or dyn[cardinality(dyn)] <> base then
        dyn := coalesce(dyn, '{}') || base;
    end if;

    -- $ref and $dynamicRef: evaluate the target in place
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
                props := props || r.props;
                items := items || r.items;
            else
                valid := false;
                errors := errors || r.errors;
                if not errs then return; end if;
            end if;
        end if;
    end loop;

    -- type, enum, const
    if sch ? 'type' then
        ok := false;
        for k in select x from jsonb_array_elements_text(case when jsonb_typeof(sch -> 'type') = 'array'
                                                                then sch -> 'type' else jsonb_build_array(sch -> 'type') end) x loop
            if k = t or (k = 'integer' and case when t = 'number' then (inst #>> '{}')::numeric % 1 = 0 else false end) then
                ok := true;
                exit;
            end if;
        end loop;
        if not ok then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/type',
                      'keyword', 'type', 'error', pg_catalog.format('expected %s, got %s', sch -> 'type', t));
        end if;
    end if;
    if sch ? 'enum' and not exists (select 1 from jsonb_array_elements(sch -> 'enum') e where e = inst) then
        valid := false;
        if not errs then return; end if;
        errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/enum',
                  'keyword', 'enum', 'error', 'value is not one of the enum values');
    end if;
    if sch ? 'const' and inst is distinct from sch -> 'const' then
        valid := false;
        if not errs then return; end if;
        errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/const',
                  'keyword', 'const', 'error', pg_catalog.format('value must be %s', sch -> 'const'));
    end if;

    -- numbers
    if t = 'number' then
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
    if t = 'string' then
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
        -- format assertion through the registry; an unknown name raises
        if jsonb_typeof(sch -> 'format') = 'string' and not validate.format(sch ->> 'format', s) then
            valid := false;
            if not errs then return; end if;
            errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/format',
                      'keyword', 'format', 'error', pg_catalog.format('string is not a valid %s', sch ->> 'format'));
        end if;
    end if;

    -- in-place applicators
    if jsonb_typeof(sch -> 'allOf') = 'array' then
        for i in 0 .. jsonb_array_length(sch -> 'allOf') - 1 loop
            r := validate._js_eval(inst, sch -> 'allOf' -> i, ctx, base, dyn, iloc, kloc || '/allOf/' || i, depth + 1, errs);
            if r.valid then
                props := props || r.props;
                items := items || r.items;
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
                props := props || r.props;
                items := items || r.items;
                if not annot then exit; end if;
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
                if cnt = 1 then
                    sub := jsonb_build_object('p', r.props, 'i', r.items);
                end if;
            else
                branch_errors := branch_errors || r.errors;
            end if;
        end loop;
        if cnt = 1 then
            props := props || array(select jsonb_array_elements_text(sub -> 'p'));
            items := items || array(select x::int from jsonb_array_elements_text(sub -> 'i') x);
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
            props := props || r.props;
            items := items || r.items;
            k := 'then';
        else
            k := 'else';
        end if;
        if sch ? k then
            r := validate._js_eval(inst, sch -> k, ctx, base, dyn, iloc, kloc || '/' || k, depth + 1, errs);
            if r.valid then
                props := props || r.props;
                items := items || r.items;
            else
                valid := false;
                if not errs then return; end if;
                errors := errors || r.errors;
            end if;
        end if;
    end if;

    -- objects
    if t = 'object' then
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
        if jsonb_typeof(sch -> 'required') = 'array' then
            for k in select x from jsonb_array_elements_text(sch -> 'required') x where not inst ? x loop
                valid := false;
                if not errs then return; end if;
                errors := errors || jsonb_build_object('instanceLocation', iloc, 'keywordLocation', kloc || '/required',
                          'keyword', 'required', 'error', pg_catalog.format('required property %s is missing', to_jsonb(k)));
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
                    props := props || r.props;
                    items := items || r.items;
                else
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if jsonb_typeof(sch -> 'patternProperties') = 'object' then
            pats := array(select validate._js_regex(x) from jsonb_object_keys(sch -> 'patternProperties') x);
        else
            pats := '{}';
        end if;
        for k, v in select e.key, e.value from jsonb_each(inst) e loop
            found_ := false;
            if jsonb_typeof(sch -> 'properties') = 'object' and (sch -> 'properties') ? k then
                found_ := true;
                r := validate._js_eval(v, sch -> 'properties' -> k, ctx, base, dyn, iloc || '/' || validate._js_token(k),
                                       kloc || '/properties/' || validate._js_token(k), depth + 1, errs);
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end if;
            if cardinality(pats) > 0 then
                for s, sub in select e.key, e.value from jsonb_each(sch -> 'patternProperties') e
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
            if found_ then
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
    if t = 'array' then
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
        if sch -> 'uniqueItems' = 'true'::jsonb
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
                items := items || i;
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if sch ? 'items' then
            for i in cnt .. n - 1 loop
                r := validate._js_eval(inst -> i, sch -> 'items', ctx, base, dyn, iloc || '/' || i,
                                       kloc || '/items', depth + 1, errs);
                items := items || i;
                if not r.valid then
                    valid := false;
                    if not errs then return; end if;
                    errors := errors || r.errors;
                end if;
            end loop;
        end if;
        if sch ? 'contains' then
            cnt := 0;
            for i in 0 .. n - 1 loop
                r := validate._js_eval(inst -> i, sch -> 'contains', ctx, base, dyn, iloc || '/' || i,
                                       kloc || '/contains', depth + 1, false);
                if r.valid then
                    cnt := cnt + 1;
                    items := items || i;
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

-- ============================================================================
-- Privileges
-- ============================================================================

grant usage on schema validate to public;
revoke all on validate.formats from public;
grant select on validate.formats to public;

-- Validators, helpers, format() and list_formats() keep the default EXECUTE
-- for PUBLIC (validators are SECURITY INVOKER and call the helpers as the
-- caller). Registration is for the owner and the roles it grants:
--
--   grant execute on function
--       validate.register_format(text, regprocedure, text),
--       validate.unregister_format(text)
--   to app_admin;
--   grant insert, delete on validate.formats to app_admin;
revoke all on function
    validate.register_format(text, regprocedure, text),
    validate.unregister_format(text)
from public;
