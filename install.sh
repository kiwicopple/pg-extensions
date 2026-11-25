#!/bin/sh
# Download and install one SQL package. Runs on macOS and Linux with POSIX sh.
set -eu

usage() {
    cat <<'HELP'
Usage: sh install.sh PACKAGE [options]

Packages: pg_idkit, pg_crdt, pg_permissions, pg_validate

  --database CONNECTION  Postgres URI or libpq connection string (or DATABASE_URL)
  --role ROLE            Install as an existing owner role using SET LOCAL ROLE
  --version VERSION      SQL file version; default: latest default_version on main
  --ref REF              Git commit, tag or branch to download from (default: main)
  --output FILE          Save transaction-wrapped SQL for a SQL editor or migration;
                         do not connect to a database (no psql required)
  -h, --help             Show this help

Examples:
  sh install.sh pg_crdt --database 'postgresql://postgres@localhost:5432/app'
  sh install.sh pg_permissions --database "$DATABASE_URL" --role app_owner
  sh install.sh pg_idkit --version 0.0.5 --output pg_idkit.sql

Requires curl, and psql unless using --output. Passwords can be supplied through
psql's prompt or .pgpass. The connection's role owns the objects unless --role is
given; it must be allowed to SET ROLE to that role. No roles are created.

Fresh installations only. Existing installations are refused, never upgraded or
removed. The SQL runs in one transaction and rolls back on any error.
HELP
}

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value"; }
valid_version() {
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

main() {
    package=
    database=${DATABASE_URL:-}
    role=
    version=latest
    ref=main
    output=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --database) need_value "$@"; database=$2; shift 2 ;;
            --role) need_value "$@"; role=$2; shift 2 ;;
            --version) need_value "$@"; version=$2; shift 2 ;;
            --ref) need_value "$@"; ref=$2; shift 2 ;;
            --output) need_value "$@"; output=$2; shift 2 ;;
            -*) fail "unknown option: $1 (see --help)" ;;
            *) [ -z "$package" ] || fail 'choose one package per invocation'; package=$1; shift ;;
        esac
    done

    case "$package" in
        pg_idkit) schema=extensions; min_version=130000 ;;
        pg_crdt) schema=crdt; min_version=160000 ;;
        pg_permissions) schema=permissions; min_version=160000 ;;
        pg_validate) schema=validate; min_version=160000 ;;
        *) fail 'choose pg_idkit, pg_crdt, pg_permissions or pg_validate (see --help)' ;;
    esac
    [ "$version" = latest ] || valid_version "$version" || fail 'version must be latest or N.N.N'
    case "$ref" in
        ''|*[!a-zA-Z0-9._/-]*|*..*) fail 'ref must be a Git commit, tag or branch name' ;;
    esac
    command -v curl >/dev/null 2>&1 || fail 'curl is required'
    if [ -z "$output" ]; then
        [ -n "$database" ] || fail 'provide --database or set DATABASE_URL (or use --output FILE)'
        command -v psql >/dev/null 2>&1 || fail 'install the Postgres client (psql), or use --output FILE for a SQL editor'
    else
        [ ! -e "$output" ] && [ ! -L "$output" ] || fail "output already exists: $output"
    fi

    work=$(mktemp -d "${TMPDIR:-/tmp}/pg-extensions.XXXXXX")
    trap 'rm -rf "$work"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    base="https://raw.githubusercontent.com/kiwicopple/pg-extensions/$ref/$package"
    if [ "$version" = latest ]; then
        curl --fail --silent --show-error --location --retry 3 \
            "$base/$package.control" -o "$work/package.control" || fail 'could not download package metadata'
        version=$(sed -n "s/^[[:space:]]*default_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$work/package.control")
        valid_version "$version" || fail 'package metadata has no valid default_version'
    fi
    source_url="$base/$package--$version.sql"
    printf 'Downloading %s %s (%s)\n' "$package" "$version" "$ref" >&2
    curl --fail --silent --show-error --location --retry 3 \
        "$source_url" -o "$work/package.sql" || fail "could not download $package $version; check --version and --ref"
    [ -s "$work/package.sql" ] || fail 'downloaded SQL is empty'

    # Generate plain SQL, so the exact same transaction can run in a SQL editor.
    # All interpolated values are allowlisted above; role is an SQL identifier.
    {
        printf -- '-- %s %s\n-- Source: %s\nbegin;\n' "$package" "$version" "$source_url"
        printf 'set local standard_conforming_strings = on;\nset local search_path = pg_catalog, pg_temp;\n'
        if [ -n "$role" ]; then
            quoted_role=$(printf '%s' "$role" | sed 's/"/""/g')
            printf 'set local role "%s";\n' "$quoted_role"
        fi
        cat <<SQL
do \$install\$
begin
    if current_setting('server_version_num')::int < $min_version then
        raise exception '$package needs Postgres % or later', $min_version / 10000;
    end if;
    if exists (select 1 from pg_extension where extname = '$package') then
        raise exception '$package is already installed as an extension. Use its documented upgrade procedure.';
    end if;
SQL
        if [ "$package" = pg_idkit ]; then
            cat <<'SQL'
    if exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'extensions' and p.proname in (
            'gen_random_uuid_v6', 'gen_random_uuid_v7', 'gen_random_ksuid_second',
            'gen_random_ksuid_microsecond', 'timestamp_from_uuid_v7', 'gen_random_ulid'
        )
    ) then
        raise exception 'pg_idkit functions already exist in extensions. Use the documented upgrade procedure.';
    end if;
SQL
        else
            cat <<SQL
    if to_regnamespace('$schema') is not null then
        raise exception 'Schema $schema already exists. Use a fresh database or the documented upgrade procedure.';
    end if;
SQL
        fi
        printf 'end;\n$install$;\n'
        if [ "$package" = pg_idkit ]; then
            printf 'create schema if not exists extensions;\nset local search_path = extensions, pg_catalog, pg_temp;\n'
        fi
        cat "$work/package.sql"
        printf '\ncommit;\n'
    } > "$work/install.sql"

    if [ -n "$output" ]; then
        # noclobber also protects against an output created during the download.
        (set -C; cat "$work/install.sql" > "$output") || fail "could not write $output"
        printf 'Saved %s %s to %s. Run the entire file in your SQL editor or migration.\n' "$package" "$version" "$output"
    else
        # -X ignores .psqlrc; ON_ERROR_STOP prevents a partial/failed install from
        # reporting success. Closing the connection rolls back an aborted txn.
        psql -X --set=ON_ERROR_STOP=1 --dbname="$database" --file="$work/install.sql"
        printf 'Installed %s %s in schema %s.\n' "$package" "$version" "$schema"
    fi
}

main "$@"
