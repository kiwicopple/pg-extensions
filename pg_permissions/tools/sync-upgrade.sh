#!/usr/bin/env bash
# Copy the marked sections of the install file into the upgrade script.
#
#   tools/sync-upgrade.sh           # rewrite pg_permissions--0.0.1--0.1.0.sql
#   tools/sync-upgrade.sh --check   # exit 1 if the upgrade script is out of date
#
# A section is everything from a line `-- >>> <name> section: begin` to the
# line `-- <<< <name> section: end`, both included. Code that is new in 0.1.0
# (the Cedar model) lives in pg_permissions--0.1.0.sql inside such markers, and
# the upgrade script has the same markers where it creates that code. This
# script replaces each marked region of the upgrade script with the section of
# the same name from the install file, so the two never drift apart.
# test/spec/d/05_upgrade.sql then checks that 0.0.1 plus the upgrade script
# equals a fresh 0.1.0 install. Edit the install file, never the copy.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
SRC="$EXT_DIR/pg_permissions--0.1.0.sql"
DST="$EXT_DIR/pg_permissions--0.0.1--0.1.0.sql"
CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Pass 1 reads the install file's sections; pass 2 copies the upgrade script,
# replacing each marked region by the section of the same name.
awk -v src="$SRC" '
    function marker(line, kind,    m) {
        if (match(line, "^-- " (kind == "begin" ? ">>>" : "<<<") " [a-z0-9_-]+ section: " kind "$")) {
            m = line
            sub("^-- (>>>|<<<) ", "", m)
            sub(" section: " kind "$", "", m)
            return m
        }
        return ""
    }
    FNR == NR {
        if ((name = marker($0, "begin")) != "") { cur = name; body[cur] = ""; nsec++ }
        if (cur != "") body[cur] = body[cur] $0 "\n"
        if ((name = marker($0, "end")) != "") {
            if (name != cur) { printf "%s:%d: end of section %s inside %s\n", src, FNR, name, cur > "/dev/stderr"; bad = 1 }
            cur = ""
        }
        next
    }
    {
        if ((name = marker($0, "begin")) != "") {
            if (!(name in body)) { printf "%s has no section %s\n", src, name > "/dev/stderr"; bad = 1 }
            printf "%s", body[name]; skip = name; used[name] = 1; next
        }
        if (skip != "") {
            if ((name = marker($0, "end")) != "") skip = ""
            next
        }
        print
    }
    END {
        for (n in body) if (!(n in used)) { printf "the upgrade script has no region for section %s\n", n > "/dev/stderr"; bad = 1 }
        if (skip != "") { printf "the upgrade script never ends section %s\n", skip > "/dev/stderr"; bad = 1 }
        exit bad
    }
' "$SRC" "$DST" > "$TMP"

if cmp -s "$TMP" "$DST"; then
    echo "up to date: ${DST#$EXT_DIR/}"
    exit 0
fi
if [ $CHECK = 1 ]; then
    echo "out of date: ${DST#$EXT_DIR/} (run tools/sync-upgrade.sh)" >&2
    exit 1
fi
cat "$TMP" > "$DST"
echo "updated: ${DST#$EXT_DIR/}"
