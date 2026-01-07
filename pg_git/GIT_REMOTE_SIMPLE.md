# git-remote-postgres: Simple Git Storage in PostgreSQL

A minimal Git remote helper that stores Git objects directly in PostgreSQL. No translation, no interpretation - just storage.

## Concept

```
┌─────────────────┐         ┌─────────────────┐
│   Git Client    │ ──────> │   PostgreSQL    │
│                 │         │                 │
│  - git push     │         │  - objects      │
│  - git pull     │         │  - refs         │
│  - git clone    │         │                 │
└─────────────────┘         └─────────────────┘
```

Git objects are stored **as-is** - no conversion, no mapping. PostgreSQL is just a key-value store.

## Database Schema

```sql
-- One schema per "remote repository"
CREATE SCHEMA git_storage;

-- Store raw Git objects (blobs, trees, commits, tags)
CREATE TABLE git_storage.objects (
    hash    TEXT PRIMARY KEY,      -- SHA-1 hash (40 hex chars)
    type    TEXT NOT NULL,         -- 'blob', 'tree', 'commit', 'tag'
    size    INTEGER NOT NULL,      -- Uncompressed size
    data    BYTEA NOT NULL         -- Compressed object data (zlib)
);

-- Store refs (branches, tags, HEAD)
CREATE TABLE git_storage.refs (
    name    TEXT PRIMARY KEY,      -- 'refs/heads/main', 'HEAD'
    target  TEXT NOT NULL          -- SHA-1 hash or ref name (for symbolic)
);

-- Optional: track which objects are in which pack (for optimization)
CREATE INDEX idx_objects_type ON git_storage.objects(type);
```

That's it. Two tables.

## Remote Helper Implementation

### Bash Prototype (Proof of Concept)

```bash
#!/bin/bash
# git-remote-pg - Minimal Git remote helper for PostgreSQL
# Usage: git remote add pg "pg://localhost/mydb/myrepo"

set -e

REMOTE="$1"
URL="$2"

# Parse URL: pg://host/database/schema
# Example: pg://localhost/mydb/myrepo -> host=localhost, db=mydb, schema=myrepo
parse_url() {
    local url="${1#pg://}"
    HOST="${url%%/*}"
    url="${url#*/}"
    DB="${url%%/*}"
    SCHEMA="${url#*/}"

    export PGHOST="$HOST"
    export PGDATABASE="$DB"
}

parse_url "$URL"

psql_query() {
    psql -qtAX -c "$1"
}

# Ensure schema exists
init_schema() {
    psql_query "CREATE SCHEMA IF NOT EXISTS $SCHEMA"
    psql_query "CREATE TABLE IF NOT EXISTS $SCHEMA.objects (
        hash TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        size INTEGER NOT NULL,
        data BYTEA NOT NULL
    )"
    psql_query "CREATE TABLE IF NOT EXISTS $SCHEMA.refs (
        name TEXT PRIMARY KEY,
        target TEXT NOT NULL
    )"
}

# Handle capabilities command
cmd_capabilities() {
    echo "fetch"
    echo "push"
    echo ""
}

# Handle list command
cmd_list() {
    # Get HEAD
    local head=$(psql_query "SELECT target FROM $SCHEMA.refs WHERE name = 'HEAD'" 2>/dev/null || echo "")
    if [ -n "$head" ]; then
        echo "@$head HEAD"
    fi

    # Get all refs
    psql_query "SELECT target || ' ' || name FROM $SCHEMA.refs WHERE name != 'HEAD'" 2>/dev/null || true
    echo ""
}

# Handle fetch command
cmd_fetch() {
    local sha="$1"
    local ref="$2"

    # Download object and its dependencies
    fetch_object "$sha"
    echo ""
}

fetch_object() {
    local sha="$1"

    # Check if we already have it locally
    if git cat-file -e "$sha" 2>/dev/null; then
        return
    fi

    # Get from PostgreSQL
    local tmpfile=$(mktemp)
    psql_query "SELECT encode(data, 'hex') FROM $SCHEMA.objects WHERE hash = '$sha'" | xxd -r -p > "$tmpfile"

    if [ -s "$tmpfile" ]; then
        # Get object type and decompress
        local type=$(psql_query "SELECT type FROM $SCHEMA.objects WHERE hash = '$sha'")
        local size=$(psql_query "SELECT size FROM $SCHEMA.objects WHERE hash = '$sha'")

        # Decompress and store in Git
        zlib-flate -uncompress < "$tmpfile" | git hash-object -t "$type" -w --stdin > /dev/null

        # Recursively fetch dependencies
        case "$type" in
            commit)
                # Fetch tree and parents
                local tree=$(git cat-file -p "$sha" | grep "^tree " | cut -d' ' -f2)
                fetch_object "$tree"
                git cat-file -p "$sha" | grep "^parent " | cut -d' ' -f2 | while read parent; do
                    fetch_object "$parent"
                done
                ;;
            tree)
                # Fetch all entries
                git ls-tree "$sha" | while read mode type hash name; do
                    fetch_object "$hash"
                done
                ;;
        esac
    fi

    rm -f "$tmpfile"
}

# Handle push command
cmd_push() {
    local src="$1"
    local dst="$2"

    # Get the commit SHA
    local sha=$(git rev-parse "$src")

    # Push all objects
    push_object "$sha"

    # Update ref
    psql_query "INSERT INTO $SCHEMA.refs (name, target) VALUES ('$dst', '$sha')
                ON CONFLICT (name) DO UPDATE SET target = '$sha'"

    # Update HEAD if pushing to main/master
    if [ "$dst" = "refs/heads/main" ] || [ "$dst" = "refs/heads/master" ]; then
        psql_query "INSERT INTO $SCHEMA.refs (name, target) VALUES ('HEAD', '$dst')
                    ON CONFLICT (name) DO UPDATE SET target = '$dst'"
    fi

    echo "ok $dst"
}

push_object() {
    local sha="$1"

    # Check if already exists in remote
    local exists=$(psql_query "SELECT 1 FROM $SCHEMA.objects WHERE hash = '$sha'" 2>/dev/null)
    if [ "$exists" = "1" ]; then
        return
    fi

    # Get object info
    local type=$(git cat-file -t "$sha")
    local size=$(git cat-file -s "$sha")

    # Compress and upload
    local compressed=$(git cat-file "$type" "$sha" | zlib-flate -compress | xxd -p | tr -d '\n')

    psql_query "INSERT INTO $SCHEMA.objects (hash, type, size, data)
                VALUES ('$sha', '$type', $size, decode('$compressed', 'hex'))
                ON CONFLICT (hash) DO NOTHING"

    # Recursively push dependencies
    case "$type" in
        commit)
            local tree=$(git cat-file -p "$sha" | grep "^tree " | cut -d' ' -f2)
            push_object "$tree"
            git cat-file -p "$sha" | grep "^parent " | cut -d' ' -f2 | while read parent; do
                push_object "$parent"
            done
            ;;
        tree)
            git ls-tree "$sha" | while read mode type hash name; do
                push_object "$hash"
            done
            ;;
    esac
}

# Main protocol loop
init_schema

while read cmd arg1 arg2; do
    case "$cmd" in
        capabilities)
            cmd_capabilities
            ;;
        list)
            cmd_list
            ;;
        fetch)
            cmd_fetch "$arg1" "$arg2"
            ;;
        push)
            # Parse "push src:dst"
            src="${arg1%%:*}"
            dst="${arg1#*:}"
            cmd_push "$src" "$dst"
            ;;
        "")
            exit 0
            ;;
        *)
            echo "error unknown command $cmd" >&2
            ;;
    esac
done
```

### Go Implementation (Production)

```go
// cmd/git-remote-pg/main.go
package main

import (
	"bufio"
	"bytes"
	"compress/zlib"
	"context"
	"database/sql"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	_ "github.com/lib/pq"
)

type Remote struct {
	db     *sql.DB
	schema string
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintf(os.Stderr, "Usage: git-remote-pg <remote> <url>\n")
		os.Exit(1)
	}

	url := os.Args[2]
	remote, err := NewRemote(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer remote.Close()

	if err := remote.InitSchema(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	remote.Run()
}

func NewRemote(url string) (*Remote, error) {
	// Parse: pg://host/database/schema
	url = strings.TrimPrefix(url, "pg://")
	parts := strings.SplitN(url, "/", 3)

	connStr := fmt.Sprintf("host=%s dbname=%s sslmode=disable", parts[0], parts[1])
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		return nil, err
	}

	return &Remote{db: db, schema: parts[2]}, nil
}

func (r *Remote) InitSchema() error {
	queries := []string{
		fmt.Sprintf("CREATE SCHEMA IF NOT EXISTS %s", r.schema),
		fmt.Sprintf(`CREATE TABLE IF NOT EXISTS %s.objects (
			hash TEXT PRIMARY KEY,
			type TEXT NOT NULL,
			size INTEGER NOT NULL,
			data BYTEA NOT NULL
		)`, r.schema),
		fmt.Sprintf(`CREATE TABLE IF NOT EXISTS %s.refs (
			name TEXT PRIMARY KEY,
			target TEXT NOT NULL
		)`, r.schema),
	}

	for _, q := range queries {
		if _, err := r.db.Exec(q); err != nil {
			return err
		}
	}
	return nil
}

func (r *Remote) Run() {
	scanner := bufio.NewScanner(os.Stdin)

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			return
		}

		parts := strings.SplitN(line, " ", 3)
		cmd := parts[0]

		switch cmd {
		case "capabilities":
			fmt.Println("fetch")
			fmt.Println("push")
			fmt.Println("")

		case "list":
			r.cmdList()

		case "fetch":
			r.cmdFetch(parts[1])
			fmt.Println("")

		case "push":
			spec := parts[1]
			idx := strings.Index(spec, ":")
			src, dst := spec[:idx], spec[idx+1:]
			r.cmdPush(src, dst)
		}
	}
}

func (r *Remote) cmdList() {
	// List HEAD
	var head string
	r.db.QueryRow(fmt.Sprintf(
		"SELECT target FROM %s.refs WHERE name = 'HEAD'", r.schema,
	)).Scan(&head)

	if head != "" {
		fmt.Printf("@%s HEAD\n", head)
	}

	// List all refs
	rows, _ := r.db.Query(fmt.Sprintf(
		"SELECT name, target FROM %s.refs WHERE name != 'HEAD'", r.schema,
	))
	defer rows.Close()

	for rows.Next() {
		var name, target string
		rows.Scan(&name, &target)
		fmt.Printf("%s %s\n", target, name)
	}
	fmt.Println("")
}

func (r *Remote) cmdFetch(sha string) {
	r.fetchObject(sha)
}

func (r *Remote) fetchObject(sha string) error {
	// Check if we have it locally
	cmd := exec.Command("git", "cat-file", "-e", sha)
	if cmd.Run() == nil {
		return nil // Already have it
	}

	// Get from PostgreSQL
	var objType string
	var size int
	var data []byte

	err := r.db.QueryRow(fmt.Sprintf(
		"SELECT type, size, data FROM %s.objects WHERE hash = $1", r.schema,
	), sha).Scan(&objType, &size, &data)

	if err != nil {
		return err
	}

	// Decompress
	zr, _ := zlib.NewReader(bytes.NewReader(data))
	defer zr.Close()

	// Store in Git
	cmd = exec.Command("git", "hash-object", "-t", objType, "-w", "--stdin")
	cmd.Stdin = zr
	if err := cmd.Run(); err != nil {
		return err
	}

	// Fetch dependencies
	switch objType {
	case "commit":
		r.fetchCommitDeps(sha)
	case "tree":
		r.fetchTreeDeps(sha)
	}

	return nil
}

func (r *Remote) cmdPush(src, dst string) {
	// Get SHA
	cmd := exec.Command("git", "rev-parse", src)
	out, _ := cmd.Output()
	sha := strings.TrimSpace(string(out))

	// Push objects
	r.pushObject(sha)

	// Update ref
	r.db.Exec(fmt.Sprintf(`
		INSERT INTO %s.refs (name, target) VALUES ($1, $2)
		ON CONFLICT (name) DO UPDATE SET target = $2
	`, r.schema), dst, sha)

	fmt.Printf("ok %s\n", dst)
}

func (r *Remote) pushObject(sha string) error {
	// Check if exists
	var exists bool
	r.db.QueryRow(fmt.Sprintf(
		"SELECT EXISTS(SELECT 1 FROM %s.objects WHERE hash = $1)", r.schema,
	), sha).Scan(&exists)

	if exists {
		return nil
	}

	// Get object type and size
	cmd := exec.Command("git", "cat-file", "-t", sha)
	out, _ := cmd.Output()
	objType := strings.TrimSpace(string(out))

	cmd = exec.Command("git", "cat-file", "-s", sha)
	out, _ = cmd.Output()
	var size int
	fmt.Sscanf(string(out), "%d", &size)

	// Get and compress content
	cmd = exec.Command("git", "cat-file", objType, sha)
	content, _ := cmd.Output()

	var buf bytes.Buffer
	zw := zlib.NewWriter(&buf)
	zw.Write(content)
	zw.Close()

	// Store
	r.db.Exec(fmt.Sprintf(`
		INSERT INTO %s.objects (hash, type, size, data) VALUES ($1, $2, $3, $4)
		ON CONFLICT (hash) DO NOTHING
	`, r.schema), sha, objType, size, buf.Bytes())

	// Push dependencies
	switch objType {
	case "commit":
		r.pushCommitDeps(sha)
	case "tree":
		r.pushTreeDeps(sha)
	}

	return nil
}
```

## Usage

```bash
# Install the helper (must be in PATH as "git-remote-pg")
go build -o /usr/local/bin/git-remote-pg ./cmd/git-remote-pg

# Initialize a new repo in PostgreSQL
git remote add pg pg://localhost/mydb/myrepo

# Push
git push pg main

# Clone from PostgreSQL
git clone pg://localhost/mydb/myrepo ./local-copy

# Pull updates
git pull pg main

# Multiple repos in same database (different schemas)
git remote add pg-config pg://localhost/mydb/config_repo
git remote add pg-data pg://localhost/mydb/data_repo
```

## How It Works

### Push Flow

```
git push pg main
     │
     ▼
┌─────────────────────────────────────────┐
│ 1. Git calls: git-remote-pg pg pg://... │
│ 2. Helper receives "push" command       │
│ 3. Walk commit → tree → blobs           │
│ 4. Compress each object with zlib       │
│ 5. INSERT into objects table            │
│ 6. UPDATE refs table                    │
└─────────────────────────────────────────┘
```

### Fetch/Clone Flow

```
git clone pg://localhost/mydb/myrepo
     │
     ▼
┌─────────────────────────────────────────┐
│ 1. Git calls: git-remote-pg origin ...  │
│ 2. "list" → SELECT from refs            │
│ 3. "fetch <sha>" → SELECT from objects  │
│ 4. Decompress and git hash-object -w    │
│ 5. Recursively fetch tree/blobs         │
│ 6. Git updates local refs               │
└─────────────────────────────────────────┘
```

## Advantages

1. **Simple** - Just two tables, ~200 lines of code
2. **Compatible** - Works with any Git client
3. **No translation** - Objects stored as-is
4. **Queryable** - Can inspect objects with SQL
5. **Transactional** - PostgreSQL ACID guarantees
6. **Shareable** - Multiple users can push/pull
7. **Backupable** - pg_dump includes everything

## SQL Queries for Inspection

```sql
-- Count objects by type
SELECT type, COUNT(*), pg_size_pretty(SUM(size)) as uncompressed
FROM git_storage.objects
GROUP BY type;

-- List branches
SELECT name, target FROM git_storage.refs
WHERE name LIKE 'refs/heads/%';

-- Find large blobs
SELECT hash, size FROM git_storage.objects
WHERE type = 'blob'
ORDER BY size DESC
LIMIT 10;

-- Total storage used
SELECT pg_size_pretty(pg_total_relation_size('git_storage.objects'));
```

## Comparison

| Feature | git-remote-pg | Full pg_git |
|---------|---------------|-------------|
| Complexity | ~200 LOC | ~1000 LOC |
| Storage | Raw Git objects | Translated JSONB |
| Query data | Need to parse Git format | SQL on table rows |
| Use case | Git backup/share | Version control tables |
| Git compatible | 100% | Needs translation |

## Next Steps

1. [ ] Build Go binary
2. [ ] Add authentication (use pgpass or env vars)
3. [ ] Add SSH tunnel support
4. [ ] Optimize with pack files for large repos
5. [ ] Add `git gc` equivalent for PostgreSQL
