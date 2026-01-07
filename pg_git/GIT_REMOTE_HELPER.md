# Git Remote Helper for pg_git

This document explores how to implement a Git remote helper that allows Git to push/pull directly to pg_git repositories.

## What is a Git Remote Helper?

A Git remote helper is an executable that Git invokes to communicate with remote repositories using custom protocols. When you run:

```bash
git remote add pg postgresql://localhost/mydb/public.users
git push pg main
```

Git looks for an executable named `git-remote-postgresql` in your PATH and invokes it to handle the communication.

## How Git Remote Helpers Work

### Discovery

When Git needs to communicate with a remote, it:

1. Parses the URL scheme (e.g., `postgresql://`)
2. Looks for `git-remote-<scheme>` executable
3. Invokes it with: `git-remote-postgresql <remote-name> <url>`

### Protocol

Git communicates with the helper via stdin/stdout using a line-based text protocol:

```
┌─────────┐                      ┌──────────────────┐
│   Git   │ ──── stdin ────────> │  Remote Helper   │
│         │ <─── stdout ──────── │  (our program)   │
└─────────┘                      └──────────────────┘
```

### Command Flow

```
Git                              Remote Helper
 │                                    │
 │──── "capabilities\n" ────────────>│
 │<─── "fetch\npush\n\n" ────────────│
 │                                    │
 │──── "list\n" ────────────────────>│
 │<─── "@refs/heads/main HEAD\n" ────│
 │<─── "abc123 refs/heads/main\n" ───│
 │<─── "\n" ─────────────────────────│
 │                                    │
 │──── "fetch abc123 refs/heads/main"│
 │<─── (object data) ────────────────│
 │                                    │
 │──── "push refs/heads/main:..." ──>│
 │<─── "ok refs/heads/main\n" ───────│
 │                                    │
 │──── "\n" (done) ─────────────────>│
 └────────────────────────────────────┘
```

## Implementation Design

### File Structure

```
pg_git-cli/
├── Cargo.toml
├── src/
│   ├── main.rs              # CLI entry point
│   ├── lib.rs
│   ├── commands/
│   │   ├── mod.rs
│   │   ├── init.rs
│   │   ├── commit.rs
│   │   └── ...
│   ├── remote_helper/
│   │   ├── mod.rs
│   │   ├── protocol.rs      # Git protocol parsing
│   │   ├── capabilities.rs  # Supported operations
│   │   ├── fetch.rs         # Fetch implementation
│   │   ├── push.rs          # Push implementation
│   │   └── refs.rs          # Ref management
│   └── db/
│       ├── mod.rs
│       ├── connection.rs
│       └── queries.rs
└── bin/
    └── git-remote-postgresql  # Symlink or wrapper
```

### URL Format

```
postgresql://[user[:password]@]host[:port]/database/schema.table

Examples:
postgresql://localhost/mydb/public.users
postgresql://user:pass@db.example.com:5432/prod/app.config
postgresql:///localdb/public.files  (Unix socket)
```

### Capabilities

Our remote helper will support:

```rust
const CAPABILITIES: &[&str] = &[
    "fetch",      // Download objects
    "push",       // Upload objects
    "option",     // Accept options from Git
];
```

## Protocol Implementation

### 1. Capabilities Command

```rust
// Git sends: "capabilities\n"
// We respond with our supported capabilities

fn handle_capabilities() -> String {
    let caps = [
        "fetch",
        "push",
        "option",
        "",  // Empty line terminates
    ];
    caps.join("\n")
}
```

### 2. List Command

```rust
// Git sends: "list\n" or "list for-push\n"
// We respond with refs from pg_git

async fn handle_list(db: &PgConnection, table: &str) -> Result<String> {
    let refs = sqlx::query!(
        r#"
        SELECT
            name,
            type,
            commit_hash
        FROM pg_git.refs r
        JOIN pg_git.repositories repo ON r.repo_id = repo.id
        WHERE repo.schema_name || '.' || repo.table_name = $1
        "#,
        table
    )
    .fetch_all(db)
    .await?;

    let mut output = String::new();

    // Find HEAD
    let head = sqlx::query_scalar!(
        "SELECT ref_name FROM pg_git.head h
         JOIN pg_git.repositories r ON h.repo_id = r.id
         WHERE r.schema_name || '.' || r.table_name = $1",
        table
    )
    .fetch_optional(db)
    .await?;

    if let Some(head_ref) = head {
        output.push_str(&format!("@refs/heads/{} HEAD\n", head_ref));
    }

    for r in refs {
        let ref_path = match r.r#type.as_str() {
            "branch" => format!("refs/heads/{}", r.name),
            "tag" => format!("refs/tags/{}", r.name),
            _ => continue,
        };
        output.push_str(&format!("{} {}\n", r.commit_hash, ref_path));
    }

    output.push('\n');  // Terminate with empty line
    Ok(output)
}
```

### 3. Fetch Command

```rust
// Git sends: "fetch <sha> <ref>\n" (possibly multiple)
// We need to send back the objects

async fn handle_fetch(
    db: &PgConnection,
    requests: Vec<FetchRequest>
) -> Result<()> {
    // Collect all objects needed
    let mut objects_to_send = HashSet::new();

    for req in requests {
        collect_objects_recursive(db, &req.sha, &mut objects_to_send).await?;
    }

    // Send objects in Git pack format or loose object format
    for hash in objects_to_send {
        let obj = get_pg_git_object(db, &hash).await?;
        let git_obj = convert_to_git_object(&obj)?;
        write_git_object(&git_obj)?;
    }

    println!("");  // Empty line signals completion
    Ok(())
}

async fn collect_objects_recursive(
    db: &PgConnection,
    hash: &str,
    objects: &mut HashSet<String>
) -> Result<()> {
    if objects.contains(hash) {
        return Ok(());
    }

    let obj = sqlx::query!(
        "SELECT type, content FROM pg_git.objects WHERE hash = $1",
        hash
    )
    .fetch_one(db)
    .await?;

    objects.insert(hash.to_string());

    let content: serde_json::Value = serde_json::from_slice(&obj.content)?;

    match obj.r#type.as_str() {
        "commit" => {
            // Fetch tree and parent
            if let Some(tree) = content.get("tree").and_then(|v| v.as_str()) {
                collect_objects_recursive(db, tree, objects).await?;
            }
            if let Some(parent) = content.get("parent").and_then(|v| v.as_str()) {
                collect_objects_recursive(db, parent, objects).await?;
            }
        }
        "tree" => {
            // Fetch all blobs
            if let Some(blobs) = content.get("blobs").and_then(|v| v.as_array()) {
                for blob in blobs {
                    if let Some(h) = blob.get("hash").and_then(|v| v.as_str()) {
                        collect_objects_recursive(db, h, objects).await?;
                    }
                }
            }
        }
        "blob" => {
            // Leaf node, nothing more to fetch
        }
        _ => {}
    }

    Ok(())
}
```

### 4. Push Command

```rust
// Git sends: "push <src>:<dst>\n" or "push +<src>:<dst>\n" (force)
// We receive objects and update refs

async fn handle_push(
    db: &PgConnection,
    table: &str,
    pushes: Vec<PushRequest>
) -> Result<String> {
    let mut output = String::new();

    for push in pushes {
        // Receive objects from Git
        let objects = receive_git_objects()?;

        // Convert and store in pg_git
        for obj in objects {
            let pg_obj = convert_from_git_object(&obj)?;
            store_object(db, &pg_obj).await?;
        }

        // Update ref
        let result = update_ref(db, table, &push.dst, &push.new_sha).await;

        match result {
            Ok(_) => output.push_str(&format!("ok {}\n", push.dst)),
            Err(e) => output.push_str(&format!("error {} {}\n", push.dst, e)),
        }
    }

    output.push('\n');
    Ok(output)
}
```

## Object Format Translation

pg_git and Git use different object formats. We need bidirectional conversion:

### pg_git Commit → Git Commit

```rust
// pg_git format:
{
  "type": "commit",
  "tree": "abc123...",
  "parent": "def456...",
  "author": "alice@example.com",
  "timestamp": "2024-01-15T10:30:00Z",
  "message": "Update users"
}

// Git format:
tree abc123...
parent def456...
author Alice <alice@example.com> 1705315800 +0000
committer Alice <alice@example.com> 1705315800 +0000

Update users
```

```rust
fn pg_commit_to_git(pg_commit: &PgGitCommit) -> GitCommit {
    let timestamp = pg_commit.timestamp.timestamp();

    let mut content = format!("tree {}\n", pg_commit.tree);

    if let Some(parent) = &pg_commit.parent {
        content.push_str(&format!("parent {}\n", parent));
    }

    content.push_str(&format!(
        "author {} <{}> {} +0000\n",
        pg_commit.author, pg_commit.author, timestamp
    ));
    content.push_str(&format!(
        "committer {} <{}> {} +0000\n",
        pg_commit.author, pg_commit.author, timestamp
    ));
    content.push_str(&format!("\n{}", pg_commit.message));

    GitCommit {
        content,
        hash: sha1_hash(&content),  // Git uses SHA-1
    }
}
```

### pg_git Tree → Git Tree

```rust
// pg_git format (table rows):
{
  "type": "tree",
  "table": "public.users",
  "blobs": [
    {"pk": {"id": 1}, "hash": "abc..."},
    {"pk": {"id": 2}, "hash": "def..."}
  ]
}

// Git format (files):
100644 blob abc123... row_1.json
100644 blob def456... row_2.json
```

```rust
fn pg_tree_to_git(pg_tree: &PgGitTree) -> GitTree {
    let mut entries = Vec::new();

    for blob_ref in &pg_tree.blobs {
        // Convert PK to filename
        let filename = pk_to_filename(&blob_ref.pk);

        entries.push(GitTreeEntry {
            mode: "100644",
            name: filename,
            hash: blob_ref.hash.clone(),
        });
    }

    // Git tree format is binary
    let content = encode_git_tree(&entries);

    GitTree {
        content,
        hash: sha1_hash(&content),
    }
}

fn pk_to_filename(pk: &serde_json::Value) -> String {
    // {"id": 1} -> "id=1.json"
    // {"a": 1, "b": 2} -> "a=1_b=2.json"
    let parts: Vec<String> = pk.as_object()
        .map(|obj| {
            obj.iter()
                .map(|(k, v)| format!("{}={}", k, v))
                .collect()
        })
        .unwrap_or_default();

    format!("{}.json", parts.join("_"))
}
```

### pg_git Blob → Git Blob

```rust
// pg_git format:
{
  "type": "blob",
  "table": "public.users",
  "pk": {"id": 1},
  "data": {"id": 1, "name": "Alice", "email": "alice@example.com"}
}

// Git format (just the data as JSON):
{"id": 1, "name": "Alice", "email": "alice@example.com"}
```

```rust
fn pg_blob_to_git(pg_blob: &PgGitBlob) -> GitBlob {
    // Just extract the data field as pretty JSON
    let content = serde_json::to_string_pretty(&pg_blob.data).unwrap();

    GitBlob {
        content,
        hash: sha1_hash(&content),
    }
}
```

## Hash Translation

Git uses SHA-1, pg_git uses SHA-256. We need a mapping:

```sql
-- Add hash mapping table
CREATE TABLE pg_git.hash_mapping (
    git_sha1    TEXT PRIMARY KEY,
    pg_sha256   TEXT NOT NULL REFERENCES pg_git.objects(hash)
);

CREATE INDEX idx_hash_mapping_pg ON pg_git.hash_mapping(pg_sha256);
```

```rust
async fn get_or_create_git_hash(db: &PgConnection, pg_hash: &str) -> Result<String> {
    // Check if mapping exists
    if let Some(mapping) = sqlx::query_scalar!(
        "SELECT git_sha1 FROM pg_git.hash_mapping WHERE pg_sha256 = $1",
        pg_hash
    )
    .fetch_optional(db)
    .await? {
        return Ok(mapping);
    }

    // Get object and compute Git hash
    let obj = get_object(db, pg_hash).await?;
    let git_obj = convert_to_git_object(&obj)?;
    let git_hash = compute_git_hash(&git_obj);

    // Store mapping
    sqlx::query!(
        "INSERT INTO pg_git.hash_mapping (git_sha1, pg_sha256) VALUES ($1, $2)",
        git_hash, pg_hash
    )
    .execute(db)
    .await?;

    Ok(git_hash)
}
```

## Main Entry Point

```rust
// src/bin/git-remote-postgresql.rs

use std::io::{self, BufRead, Write};
use pg_git_cli::remote_helper::{handle_command, Connection};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage: git-remote-postgresql <remote> <url>");
        std::process::exit(1);
    }

    let _remote_name = &args[1];
    let url = &args[2];

    // Parse URL: postgresql://host/db/schema.table
    let conn_info = parse_pg_url(url)?;
    let db = Connection::connect(&conn_info).await?;

    let stdin = io::stdin();
    let mut stdout = io::stdout();

    // Protocol loop
    for line in stdin.lock().lines() {
        let line = line?;

        if line.is_empty() {
            break;
        }

        let response = handle_command(&db, &conn_info.table, &line).await?;
        stdout.write_all(response.as_bytes())?;
        stdout.flush()?;
    }

    Ok(())
}

async fn handle_command(
    db: &Connection,
    table: &str,
    command: &str
) -> Result<String> {
    let parts: Vec<&str> = command.splitn(2, ' ').collect();

    match parts[0] {
        "capabilities" => Ok(handle_capabilities()),
        "list" => handle_list(db, table).await,
        "fetch" => {
            let requests = parse_fetch_requests(&parts[1..])?;
            handle_fetch(db, requests).await
        }
        "push" => {
            let requests = parse_push_requests(&parts[1..])?;
            handle_push(db, table, requests).await
        }
        "option" => handle_option(&parts[1..]),
        _ => Err(format!("Unknown command: {}", command).into()),
    }
}
```

## Installation & Usage

### Build & Install

```bash
# Clone the repo
git clone https://github.com/pg_git/pg_git-cli
cd pg_git-cli

# Build
cargo build --release

# Install to PATH
sudo cp target/release/git-remote-postgresql /usr/local/bin/

# Or symlink
sudo ln -s $(pwd)/target/release/pg_git /usr/local/bin/git-remote-postgresql
```

### Usage

```bash
# Initialize pg_git on a table (if not already done)
psql -c "SELECT pg_git.init('public.users')"

# Add remote
git remote add pgdb postgresql://localhost/mydb/public.users

# Push current branch
git push pgdb main

# Pull changes
git pull pgdb main

# Clone (creates local Git repo from pg_git)
git clone postgresql://localhost/mydb/public.users ./users-repo

# Fetch and view
git fetch pgdb
git log pgdb/main
```

## Working Directory Format

When you clone or checkout, the working directory contains JSON files:

```
users-repo/
├── .git/
├── id=1.json    # {"id": 1, "name": "Alice", "email": "alice@example.com"}
├── id=2.json    # {"id": 2, "name": "Bob", "email": "bob@example.com"}
└── id=3.json    # {"id": 3, "name": "Carol", "email": "carol@example.com"}
```

Editing these files and pushing will update the PostgreSQL table:

```bash
# Edit a user
echo '{"id": 1, "name": "Alice Smith", "email": "alice@example.com"}' > id=1.json

# Commit and push
git add id=1.json
git commit -m "Update Alice's name"
git push pgdb main
```

## Advanced: Bidirectional Sync

```bash
# Set up both remotes
git remote add origin https://github.com/org/config.git
git remote add pgdb postgresql://localhost/mydb/public.config

# Pull from GitHub, push to PostgreSQL
git pull origin main
git push pgdb main

# Or use a mirror script
#!/bin/bash
git fetch origin
git fetch pgdb
git merge origin/main
git push pgdb main
git push origin main
```

## Limitations & Considerations

1. **File Naming**: PK values must be valid filenames
2. **Binary Data**: BYTEA columns need special handling
3. **Large Tables**: May be slow for tables with millions of rows
4. **Conflicts**: Git's text merge won't understand JSON semantics
5. **Schema**: Column changes require manual handling

## Alternative: Simpler Import/Export

If the full remote helper is too complex, a simpler approach:

```bash
# Export pg_git to a Git repo
pg_git export public.users ./users-repo --format=git

# Import Git repo to pg_git
pg_git import ./config-repo public.config

# Sync script
pg_git sync public.users ./users-repo --bidirectional
```

This avoids implementing the Git protocol but still enables Git workflows.

## Next Steps

1. [ ] Implement basic `capabilities` and `list` commands
2. [ ] Implement `fetch` for read-only cloning
3. [ ] Implement `push` for updates
4. [ ] Add hash translation layer
5. [ ] Test with real Git clients
6. [ ] Handle edge cases (force push, delete refs, etc.)
7. [ ] Add authentication support
8. [ ] Performance optimization for large repos
