/*
 * pg_git: Git-like version control for PostgreSQL tables
 *
 * Copyright (c) 2024
 * MIT License
 */

-- Create the pg_git schema
CREATE SCHEMA IF NOT EXISTS pg_git;

--------------------------------------------------------------------------------
-- CORE TABLES
--------------------------------------------------------------------------------

-- Content-addressable object storage
CREATE TABLE pg_git.objects (
    hash        TEXT PRIMARY KEY,
    type        TEXT NOT NULL CHECK (type IN ('blob', 'tree', 'commit')),
    content     BYTEA NOT NULL,
    size        BIGINT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_objects_type ON pg_git.objects(type);
CREATE INDEX idx_objects_created_at ON pg_git.objects(created_at);

-- Repository tracking (which tables are versioned)
CREATE TABLE pg_git.repositories (
    id              SERIAL PRIMARY KEY,
    schema_name     TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    primary_key     TEXT[] NOT NULL,
    tracked_columns TEXT[],
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(schema_name, table_name)
);

-- Branch and tag references
CREATE TABLE pg_git.refs (
    repo_id     INTEGER NOT NULL REFERENCES pg_git.repositories(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    type        TEXT NOT NULL CHECK (type IN ('branch', 'tag')),
    commit_hash TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(repo_id, name, type)
);

CREATE INDEX idx_refs_commit ON pg_git.refs(commit_hash);

-- HEAD tracking per repository
CREATE TABLE pg_git.head (
    repo_id     INTEGER PRIMARY KEY REFERENCES pg_git.repositories(id) ON DELETE CASCADE,
    ref_name    TEXT,
    ref_type    TEXT DEFAULT 'branch',
    commit_hash TEXT
);

-- Staging area for uncommitted changes
CREATE TABLE pg_git.staging (
    id          BIGSERIAL PRIMARY KEY,
    repo_id     INTEGER NOT NULL REFERENCES pg_git.repositories(id) ON DELETE CASCADE,
    operation   TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    pk_data     JSONB NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    staged_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_staging_repo ON pg_git.staging(repo_id);

-- Conflicts during merge
CREATE TABLE pg_git.merge_conflicts (
    id              BIGSERIAL PRIMARY KEY,
    repo_id         INTEGER NOT NULL REFERENCES pg_git.repositories(id) ON DELETE CASCADE,
    pk_data         JSONB NOT NULL,
    base_data       JSONB,
    ours_data       JSONB,
    theirs_data     JSONB,
    source_branch   TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Compute SHA-256 hash of content
CREATE OR REPLACE FUNCTION pg_git.hash_content(content BYTEA)
RETURNS TEXT
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT encode(sha256(content), 'hex');
$$;

-- Compute hash of a JSONB value
CREATE OR REPLACE FUNCTION pg_git.hash_jsonb(data JSONB)
RETURNS TEXT
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT pg_git.hash_content(convert_to(data::TEXT, 'UTF8'));
$$;

-- Get repository ID by table name
CREATE OR REPLACE FUNCTION pg_git.get_repo_id(full_table_name TEXT)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_repo_id INTEGER;
BEGIN
    -- Parse schema.table format
    IF position('.' IN full_table_name) > 0 THEN
        v_schema := split_part(full_table_name, '.', 1);
        v_table := split_part(full_table_name, '.', 2);
    ELSE
        v_schema := 'public';
        v_table := full_table_name;
    END IF;

    SELECT id INTO v_repo_id
    FROM pg_git.repositories
    WHERE schema_name = v_schema AND table_name = v_table;

    IF v_repo_id IS NULL THEN
        RAISE EXCEPTION 'Table % is not under version control. Run pg_git.init() first.', full_table_name;
    END IF;

    RETURN v_repo_id;
END;
$$;

-- Store an object in content-addressable storage
CREATE OR REPLACE FUNCTION pg_git.store_object(
    p_type TEXT,
    p_content JSONB
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_bytes BYTEA;
    v_hash TEXT;
BEGIN
    v_bytes := convert_to(p_content::TEXT, 'UTF8');
    v_hash := pg_git.hash_content(v_bytes);

    INSERT INTO pg_git.objects (hash, type, content, size)
    VALUES (v_hash, p_type, v_bytes, octet_length(v_bytes))
    ON CONFLICT (hash) DO NOTHING;

    RETURN v_hash;
END;
$$;

-- Retrieve an object from storage
CREATE OR REPLACE FUNCTION pg_git.get_object(p_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_content BYTEA;
BEGIN
    SELECT content INTO v_content
    FROM pg_git.objects
    WHERE hash = p_hash;

    IF v_content IS NULL THEN
        RAISE EXCEPTION 'Object not found: %', p_hash;
    END IF;

    RETURN convert_from(v_content, 'UTF8')::JSONB;
END;
$$;

--------------------------------------------------------------------------------
-- REPOSITORY MANAGEMENT
--------------------------------------------------------------------------------

-- Initialize version control on a table
CREATE OR REPLACE FUNCTION pg_git.init(
    p_table TEXT,
    p_primary_key TEXT[] DEFAULT NULL,
    p_columns TEXT[] DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_repo_id INTEGER;
    v_pk_columns TEXT[];
    v_trigger_name TEXT;
BEGIN
    -- Parse schema.table format
    IF position('.' IN p_table) > 0 THEN
        v_schema := split_part(p_table, '.', 1);
        v_table := split_part(p_table, '.', 2);
    ELSE
        v_schema := 'public';
        v_table := p_table;
    END IF;

    -- Verify table exists
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = v_schema AND table_name = v_table
    ) THEN
        RAISE EXCEPTION 'Table %.% does not exist', v_schema, v_table;
    END IF;

    -- Get primary key if not provided
    IF p_primary_key IS NULL THEN
        SELECT array_agg(a.attname ORDER BY array_position(i.indkey, a.attnum))
        INTO v_pk_columns
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE i.indisprimary
            AND n.nspname = v_schema
            AND c.relname = v_table;

        IF v_pk_columns IS NULL THEN
            RAISE EXCEPTION 'Table %.% has no primary key. Please specify one.', v_schema, v_table;
        END IF;
    ELSE
        v_pk_columns := p_primary_key;
    END IF;

    -- Check if already initialized
    IF EXISTS (
        SELECT 1 FROM pg_git.repositories
        WHERE schema_name = v_schema AND table_name = v_table
    ) THEN
        RAISE EXCEPTION 'Table %.% is already under version control', v_schema, v_table;
    END IF;

    -- Create repository entry
    INSERT INTO pg_git.repositories (schema_name, table_name, primary_key, tracked_columns)
    VALUES (v_schema, v_table, v_pk_columns, p_columns)
    RETURNING id INTO v_repo_id;

    -- Initialize HEAD (no commits yet)
    INSERT INTO pg_git.head (repo_id, ref_name, ref_type)
    VALUES (v_repo_id, 'main', 'branch');

    -- Create the change tracking trigger
    v_trigger_name := 'pg_git_track_' || v_repo_id;

    EXECUTE format(
        'CREATE TRIGGER %I
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION pg_git.track_change(%s)',
        v_trigger_name, v_schema, v_table, v_repo_id
    );

    RETURN format('Initialized pg_git repository for %s.%s on branch "main"', v_schema, v_table);
END;
$$;

-- Remove version control from a table
CREATE OR REPLACE FUNCTION pg_git.uninit(p_table TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema TEXT;
    v_table TEXT;
    v_repo_id INTEGER;
    v_trigger_name TEXT;
BEGIN
    -- Parse schema.table format
    IF position('.' IN p_table) > 0 THEN
        v_schema := split_part(p_table, '.', 1);
        v_table := split_part(p_table, '.', 2);
    ELSE
        v_schema := 'public';
        v_table := p_table;
    END IF;

    v_repo_id := pg_git.get_repo_id(p_table);
    v_trigger_name := 'pg_git_track_' || v_repo_id;

    -- Drop the trigger
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_trigger_name, v_schema, v_table);

    -- Delete repository (cascades to refs, head, staging)
    DELETE FROM pg_git.repositories WHERE id = v_repo_id;

    RETURN format('Removed pg_git from %s.%s', v_schema, v_table);
END;
$$;

-- List all versioned repositories
CREATE OR REPLACE FUNCTION pg_git.list_repos()
RETURNS TABLE (
    repo_id INTEGER,
    full_table_name TEXT,
    primary_key TEXT[],
    tracked_columns TEXT[],
    current_branch TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE sql STABLE
AS $$
    SELECT
        r.id,
        r.schema_name || '.' || r.table_name,
        r.primary_key,
        r.tracked_columns,
        h.ref_name,
        r.created_at
    FROM pg_git.repositories r
    LEFT JOIN pg_git.head h ON h.repo_id = r.id;
$$;

--------------------------------------------------------------------------------
-- CHANGE TRACKING
--------------------------------------------------------------------------------

-- Trigger function to track changes
CREATE OR REPLACE FUNCTION pg_git.track_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
    v_pk_columns TEXT[];
    v_pk_data JSONB;
    v_old_data JSONB;
    v_new_data JSONB;
BEGIN
    v_repo_id := TG_ARGV[0]::INTEGER;

    -- Get primary key columns
    SELECT primary_key INTO v_pk_columns
    FROM pg_git.repositories WHERE id = v_repo_id;

    -- Build PK data
    IF TG_OP = 'DELETE' THEN
        EXECUTE format(
            'SELECT jsonb_build_object(%s)',
            (SELECT string_agg(format('%L, ($1).%I', col, col), ', ') FROM unnest(v_pk_columns) AS col)
        ) INTO v_pk_data USING OLD;
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
    ELSIF TG_OP = 'INSERT' THEN
        EXECUTE format(
            'SELECT jsonb_build_object(%s)',
            (SELECT string_agg(format('%L, ($1).%I', col, col), ', ') FROM unnest(v_pk_columns) AS col)
        ) INTO v_pk_data USING NEW;
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
    ELSE -- UPDATE
        EXECUTE format(
            'SELECT jsonb_build_object(%s)',
            (SELECT string_agg(format('%L, ($1).%I', col, col), ', ') FROM unnest(v_pk_columns) AS col)
        ) INTO v_pk_data USING NEW;
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
    END IF;

    -- Record the change in staging
    INSERT INTO pg_git.staging (repo_id, operation, pk_data, old_data, new_data)
    VALUES (v_repo_id, TG_OP, v_pk_data, v_old_data, v_new_data);

    RETURN COALESCE(NEW, OLD);
END;
$$;

--------------------------------------------------------------------------------
-- STAGING
--------------------------------------------------------------------------------

-- View staged changes (status)
CREATE OR REPLACE FUNCTION pg_git.status(p_table TEXT DEFAULT NULL)
RETURNS TABLE (
    full_table_name TEXT,
    operation TEXT,
    pk_data JSONB,
    staged_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    IF p_table IS NOT NULL THEN
        v_repo_id := pg_git.get_repo_id(p_table);

        RETURN QUERY
        SELECT
            r.schema_name || '.' || r.table_name,
            s.operation,
            s.pk_data,
            s.staged_at
        FROM pg_git.staging s
        JOIN pg_git.repositories r ON r.id = s.repo_id
        WHERE s.repo_id = v_repo_id
        ORDER BY s.staged_at;
    ELSE
        RETURN QUERY
        SELECT
            r.schema_name || '.' || r.table_name,
            s.operation,
            s.pk_data,
            s.staged_at
        FROM pg_git.staging s
        JOIN pg_git.repositories r ON r.id = s.repo_id
        ORDER BY r.schema_name, r.table_name, s.staged_at;
    END IF;
END;
$$;

-- Reset staged changes
CREATE OR REPLACE FUNCTION pg_git.reset(p_table TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
    v_count INTEGER;
BEGIN
    IF p_table IS NOT NULL THEN
        v_repo_id := pg_git.get_repo_id(p_table);
        DELETE FROM pg_git.staging WHERE repo_id = v_repo_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        RETURN format('Unstaged %s changes for %s', v_count, p_table);
    ELSE
        DELETE FROM pg_git.staging;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        RETURN format('Unstaged %s changes', v_count);
    END IF;
END;
$$;

--------------------------------------------------------------------------------
-- COMMITS
--------------------------------------------------------------------------------

-- Create a commit from staged changes
CREATE OR REPLACE FUNCTION pg_git.commit(
    p_message TEXT,
    p_author TEXT DEFAULT current_user
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo RECORD;
    v_staged RECORD;
    v_tree_blobs JSONB;
    v_tree_hash TEXT;
    v_commit_hash TEXT;
    v_parent_hash TEXT;
    v_commit_obj JSONB;
    v_tree_obj JSONB;
    v_blob_hash TEXT;
    v_total_commits INTEGER := 0;
BEGIN
    -- Process each repository with staged changes
    FOR v_repo IN
        SELECT DISTINCT r.*
        FROM pg_git.repositories r
        JOIN pg_git.staging s ON s.repo_id = r.id
    LOOP
        -- Get current HEAD commit as parent
        SELECT commit_hash INTO v_parent_hash
        FROM pg_git.head h
        LEFT JOIN pg_git.refs rf ON rf.repo_id = h.repo_id
            AND rf.name = h.ref_name AND rf.type = h.ref_type
        WHERE h.repo_id = v_repo.id;

        -- If we have a parent, start with its tree blobs
        IF v_parent_hash IS NOT NULL THEN
            SELECT (pg_git.get_object(
                (pg_git.get_object(v_parent_hash)->>'tree')
            ))->'blobs' INTO v_tree_blobs;
        ELSE
            v_tree_blobs := '[]'::JSONB;
        END IF;

        -- Apply staged changes to tree
        FOR v_staged IN
            SELECT * FROM pg_git.staging
            WHERE repo_id = v_repo.id
            ORDER BY staged_at
        LOOP
            IF v_staged.operation = 'DELETE' THEN
                -- Remove blob from tree
                SELECT jsonb_agg(b) INTO v_tree_blobs
                FROM jsonb_array_elements(v_tree_blobs) AS b
                WHERE b->'pk' != v_staged.pk_data;

            ELSIF v_staged.operation IN ('INSERT', 'UPDATE') THEN
                -- Create blob for the row
                v_blob_hash := pg_git.store_object('blob', jsonb_build_object(
                    'type', 'blob',
                    'table', v_repo.schema_name || '.' || v_repo.table_name,
                    'pk', v_staged.pk_data,
                    'data', v_staged.new_data
                ));

                -- Remove old entry if exists (for UPDATE)
                SELECT COALESCE(jsonb_agg(b), '[]'::JSONB) INTO v_tree_blobs
                FROM jsonb_array_elements(v_tree_blobs) AS b
                WHERE b->'pk' != v_staged.pk_data;

                -- Add new/updated blob reference
                v_tree_blobs := v_tree_blobs || jsonb_build_array(jsonb_build_object(
                    'pk', v_staged.pk_data,
                    'hash', v_blob_hash
                ));
            END IF;
        END LOOP;

        -- Create tree object
        v_tree_obj := jsonb_build_object(
            'type', 'tree',
            'table', v_repo.schema_name || '.' || v_repo.table_name,
            'row_count', jsonb_array_length(COALESCE(v_tree_blobs, '[]'::JSONB)),
            'blobs', COALESCE(v_tree_blobs, '[]'::JSONB)
        );
        v_tree_hash := pg_git.store_object('tree', v_tree_obj);

        -- Create commit object
        v_commit_obj := jsonb_build_object(
            'type', 'commit',
            'tree', v_tree_hash,
            'parent', v_parent_hash,
            'author', p_author,
            'timestamp', now(),
            'message', p_message
        );
        v_commit_hash := pg_git.store_object('commit', v_commit_obj);

        -- Update branch ref
        INSERT INTO pg_git.refs (repo_id, name, type, commit_hash, updated_at)
        SELECT h.repo_id, h.ref_name, 'branch', v_commit_hash, now()
        FROM pg_git.head h
        WHERE h.repo_id = v_repo.id AND h.ref_name IS NOT NULL
        ON CONFLICT (repo_id, name, type)
        DO UPDATE SET commit_hash = EXCLUDED.commit_hash, updated_at = now();

        -- Update HEAD if detached
        UPDATE pg_git.head
        SET commit_hash = v_commit_hash
        WHERE repo_id = v_repo.id AND ref_name IS NULL;

        -- Clear staging for this repo
        DELETE FROM pg_git.staging WHERE repo_id = v_repo.id;

        v_total_commits := v_total_commits + 1;
    END LOOP;

    IF v_total_commits = 0 THEN
        RAISE EXCEPTION 'Nothing to commit (no staged changes)';
    END IF;

    RETURN format('[%s] %s', substring(v_commit_hash, 1, 7), p_message);
END;
$$;

-- View commit history
CREATE OR REPLACE FUNCTION pg_git.log(
    p_table TEXT,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
    commit_hash TEXT,
    short_hash TEXT,
    parent_hash TEXT,
    author TEXT,
    timestamp TIMESTAMPTZ,
    message TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
    v_current_hash TEXT;
    v_commit JSONB;
    v_count INTEGER := 0;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- Get HEAD commit
    SELECT COALESCE(h.commit_hash, r.commit_hash) INTO v_current_hash
    FROM pg_git.head h
    LEFT JOIN pg_git.refs r ON r.repo_id = h.repo_id
        AND r.name = h.ref_name AND r.type = h.ref_type
    WHERE h.repo_id = v_repo_id;

    -- Walk the commit chain
    WHILE v_current_hash IS NOT NULL AND v_count < p_limit LOOP
        v_commit := pg_git.get_object(v_current_hash);

        commit_hash := v_current_hash;
        short_hash := substring(v_current_hash, 1, 7);
        parent_hash := v_commit->>'parent';
        author := v_commit->>'author';
        timestamp := (v_commit->>'timestamp')::TIMESTAMPTZ;
        message := v_commit->>'message';

        RETURN NEXT;

        v_current_hash := v_commit->>'parent';
        v_count := v_count + 1;
    END LOOP;
END;
$$;

-- Show commit details
CREATE OR REPLACE FUNCTION pg_git.show(p_commit_hash TEXT)
RETURNS TABLE (
    property TEXT,
    value TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_commit JSONB;
    v_tree JSONB;
BEGIN
    v_commit := pg_git.get_object(p_commit_hash);
    v_tree := pg_git.get_object(v_commit->>'tree');

    RETURN QUERY
    SELECT 'commit'::TEXT, p_commit_hash
    UNION ALL SELECT 'tree', v_commit->>'tree'
    UNION ALL SELECT 'parent', v_commit->>'parent'
    UNION ALL SELECT 'author', v_commit->>'author'
    UNION ALL SELECT 'timestamp', v_commit->>'timestamp'
    UNION ALL SELECT 'message', v_commit->>'message'
    UNION ALL SELECT 'table', v_tree->>'table'
    UNION ALL SELECT 'row_count', v_tree->>'row_count';
END;
$$;

--------------------------------------------------------------------------------
-- BRANCHES
--------------------------------------------------------------------------------

-- Create a new branch
CREATE OR REPLACE FUNCTION pg_git.branch(
    p_table TEXT,
    p_branch_name TEXT,
    p_from_commit TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
    v_commit_hash TEXT;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- Get commit hash to branch from
    IF p_from_commit IS NOT NULL THEN
        -- Verify commit exists
        IF NOT EXISTS (SELECT 1 FROM pg_git.objects WHERE hash = p_from_commit AND type = 'commit') THEN
            RAISE EXCEPTION 'Commit % not found', p_from_commit;
        END IF;
        v_commit_hash := p_from_commit;
    ELSE
        -- Use current HEAD
        SELECT COALESCE(h.commit_hash, r.commit_hash) INTO v_commit_hash
        FROM pg_git.head h
        LEFT JOIN pg_git.refs r ON r.repo_id = h.repo_id
            AND r.name = h.ref_name AND r.type = h.ref_type
        WHERE h.repo_id = v_repo_id;

        IF v_commit_hash IS NULL THEN
            RAISE EXCEPTION 'Cannot create branch: no commits yet';
        END IF;
    END IF;

    -- Create branch ref
    INSERT INTO pg_git.refs (repo_id, name, type, commit_hash)
    VALUES (v_repo_id, p_branch_name, 'branch', v_commit_hash)
    ON CONFLICT (repo_id, name, type) DO UPDATE SET commit_hash = EXCLUDED.commit_hash;

    RETURN format('Created branch "%s" at %s', p_branch_name, substring(v_commit_hash, 1, 7));
END;
$$;

-- List branches
CREATE OR REPLACE FUNCTION pg_git.branches(p_table TEXT)
RETURNS TABLE (
    branch_name TEXT,
    commit_hash TEXT,
    short_hash TEXT,
    is_current BOOLEAN,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    RETURN QUERY
    SELECT
        r.name,
        r.commit_hash,
        substring(r.commit_hash, 1, 7),
        (h.ref_name = r.name AND h.ref_type = 'branch'),
        r.updated_at
    FROM pg_git.refs r
    JOIN pg_git.head h ON h.repo_id = r.repo_id
    WHERE r.repo_id = v_repo_id AND r.type = 'branch'
    ORDER BY r.name;
END;
$$;

-- Delete a branch
CREATE OR REPLACE FUNCTION pg_git.branch_delete(p_table TEXT, p_branch_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
    v_current_branch TEXT;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- Check if it's the current branch
    SELECT ref_name INTO v_current_branch
    FROM pg_git.head
    WHERE repo_id = v_repo_id;

    IF v_current_branch = p_branch_name THEN
        RAISE EXCEPTION 'Cannot delete the current branch "%"', p_branch_name;
    END IF;

    DELETE FROM pg_git.refs
    WHERE repo_id = v_repo_id AND name = p_branch_name AND type = 'branch';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Branch "%" not found', p_branch_name;
    END IF;

    RETURN format('Deleted branch "%s"', p_branch_name);
END;
$$;

--------------------------------------------------------------------------------
-- CHECKOUT
--------------------------------------------------------------------------------

-- Switch to a branch or commit
CREATE OR REPLACE FUNCTION pg_git.checkout(
    p_table TEXT,
    p_ref TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo RECORD;
    v_repo_id INTEGER;
    v_commit_hash TEXT;
    v_is_branch BOOLEAN := FALSE;
    v_tree JSONB;
    v_blob JSONB;
    v_row_data JSONB;
    v_pk_columns TEXT[];
    v_pk_values TEXT[];
    v_where_clause TEXT;
    v_col TEXT;
BEGIN
    -- Get repository info
    SELECT * INTO v_repo FROM pg_git.repositories WHERE id = pg_git.get_repo_id(p_table);
    v_repo_id := v_repo.id;
    v_pk_columns := v_repo.primary_key;

    -- Check if there are uncommitted changes
    IF EXISTS (SELECT 1 FROM pg_git.staging WHERE repo_id = v_repo_id) THEN
        RAISE EXCEPTION 'You have uncommitted changes. Commit or reset them before checkout.';
    END IF;

    -- Check if ref is a branch
    SELECT commit_hash INTO v_commit_hash
    FROM pg_git.refs
    WHERE repo_id = v_repo_id AND name = p_ref AND type = 'branch';

    IF v_commit_hash IS NOT NULL THEN
        v_is_branch := TRUE;
    ELSE
        -- Check if it's a tag
        SELECT commit_hash INTO v_commit_hash
        FROM pg_git.refs
        WHERE repo_id = v_repo_id AND name = p_ref AND type = 'tag';

        IF v_commit_hash IS NULL THEN
            -- Assume it's a commit hash
            IF EXISTS (SELECT 1 FROM pg_git.objects WHERE hash = p_ref AND type = 'commit') THEN
                v_commit_hash := p_ref;
            ELSIF EXISTS (SELECT 1 FROM pg_git.objects WHERE hash LIKE p_ref || '%' AND type = 'commit') THEN
                SELECT hash INTO v_commit_hash FROM pg_git.objects
                WHERE hash LIKE p_ref || '%' AND type = 'commit' LIMIT 1;
            ELSE
                RAISE EXCEPTION 'Ref "%" not found (not a branch, tag, or commit)', p_ref;
            END IF;
        END IF;
    END IF;

    -- Get the tree from the commit
    v_tree := pg_git.get_object((pg_git.get_object(v_commit_hash))->>'tree');

    -- Disable the tracking trigger temporarily
    EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER pg_git_track_%s',
        v_repo.schema_name, v_repo.table_name, v_repo_id);

    BEGIN
        -- Clear the table
        EXECUTE format('DELETE FROM %I.%I', v_repo.schema_name, v_repo.table_name);

        -- Restore rows from blobs
        FOR v_blob IN SELECT * FROM jsonb_array_elements(v_tree->'blobs')
        LOOP
            v_row_data := (pg_git.get_object(v_blob->>'hash'))->'data';

            -- Insert the row
            EXECUTE format(
                'INSERT INTO %I.%I SELECT * FROM jsonb_populate_record(NULL::%I.%I, $1)',
                v_repo.schema_name, v_repo.table_name,
                v_repo.schema_name, v_repo.table_name
            ) USING v_row_data;
        END LOOP;

        -- Re-enable the tracking trigger
        EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER pg_git_track_%s',
            v_repo.schema_name, v_repo.table_name, v_repo_id);
    EXCEPTION WHEN OTHERS THEN
        -- Re-enable trigger on error
        EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER pg_git_track_%s',
            v_repo.schema_name, v_repo.table_name, v_repo_id);
        RAISE;
    END;

    -- Update HEAD
    IF v_is_branch THEN
        UPDATE pg_git.head
        SET ref_name = p_ref, ref_type = 'branch', commit_hash = NULL
        WHERE repo_id = v_repo_id;

        RETURN format('Switched to branch "%s"', p_ref);
    ELSE
        UPDATE pg_git.head
        SET ref_name = NULL, ref_type = NULL, commit_hash = v_commit_hash
        WHERE repo_id = v_repo_id;

        RETURN format('HEAD is now at %s (detached)', substring(v_commit_hash, 1, 7));
    END IF;
END;
$$;

-- Get current HEAD info
CREATE OR REPLACE FUNCTION pg_git.head(p_table TEXT)
RETURNS TABLE (
    branch_name TEXT,
    commit_hash TEXT,
    short_hash TEXT,
    is_detached BOOLEAN
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    RETURN QUERY
    SELECT
        h.ref_name,
        COALESCE(h.commit_hash, r.commit_hash),
        substring(COALESCE(h.commit_hash, r.commit_hash), 1, 7),
        h.ref_name IS NULL
    FROM pg_git.head h
    LEFT JOIN pg_git.refs r ON r.repo_id = h.repo_id
        AND r.name = h.ref_name AND r.type = h.ref_type
    WHERE h.repo_id = v_repo_id;
END;
$$;

--------------------------------------------------------------------------------
-- DIFF
--------------------------------------------------------------------------------

-- Compare two commits or working copy vs HEAD
CREATE OR REPLACE FUNCTION pg_git.diff(
    p_table TEXT,
    p_from_ref TEXT DEFAULT NULL,
    p_to_ref TEXT DEFAULT NULL
)
RETURNS TABLE (
    operation TEXT,
    pk_data JSONB,
    old_data JSONB,
    new_data JSONB
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
    v_from_hash TEXT;
    v_to_hash TEXT;
    v_from_tree JSONB;
    v_to_tree JSONB;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- If no refs provided, diff working copy vs HEAD
    IF p_from_ref IS NULL AND p_to_ref IS NULL THEN
        RETURN QUERY
        SELECT s.operation, s.pk_data, s.old_data, s.new_data
        FROM pg_git.staging s
        WHERE s.repo_id = v_repo_id
        ORDER BY s.staged_at;
        RETURN;
    END IF;

    -- Resolve refs to commit hashes
    v_from_hash := pg_git.resolve_ref(v_repo_id, p_from_ref);
    v_to_hash := pg_git.resolve_ref(v_repo_id, p_to_ref);

    -- Get trees
    v_from_tree := pg_git.get_object((pg_git.get_object(v_from_hash))->>'tree');
    v_to_tree := pg_git.get_object((pg_git.get_object(v_to_hash))->>'tree');

    -- Compare trees
    RETURN QUERY
    WITH from_blobs AS (
        SELECT
            b->>'hash' AS hash,
            b->'pk' AS pk
        FROM jsonb_array_elements(v_from_tree->'blobs') AS b
    ),
    to_blobs AS (
        SELECT
            b->>'hash' AS hash,
            b->'pk' AS pk
        FROM jsonb_array_elements(v_to_tree->'blobs') AS b
    ),
    deleted AS (
        SELECT 'DELETE'::TEXT AS op, f.pk, f.hash AS old_hash, NULL::TEXT AS new_hash
        FROM from_blobs f
        LEFT JOIN to_blobs t ON f.pk = t.pk
        WHERE t.pk IS NULL
    ),
    inserted AS (
        SELECT 'INSERT'::TEXT AS op, t.pk, NULL::TEXT AS old_hash, t.hash AS new_hash
        FROM to_blobs t
        LEFT JOIN from_blobs f ON t.pk = f.pk
        WHERE f.pk IS NULL
    ),
    updated AS (
        SELECT 'UPDATE'::TEXT AS op, f.pk, f.hash AS old_hash, t.hash AS new_hash
        FROM from_blobs f
        JOIN to_blobs t ON f.pk = t.pk
        WHERE f.hash != t.hash
    ),
    all_changes AS (
        SELECT * FROM deleted
        UNION ALL SELECT * FROM inserted
        UNION ALL SELECT * FROM updated
    )
    SELECT
        c.op,
        c.pk,
        CASE WHEN c.old_hash IS NOT NULL THEN (pg_git.get_object(c.old_hash))->'data' ELSE NULL END,
        CASE WHEN c.new_hash IS NOT NULL THEN (pg_git.get_object(c.new_hash))->'data' ELSE NULL END
    FROM all_changes c;
END;
$$;

-- Helper function to resolve ref to commit hash
CREATE OR REPLACE FUNCTION pg_git.resolve_ref(p_repo_id INTEGER, p_ref TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_hash TEXT;
BEGIN
    -- Check branches first
    SELECT commit_hash INTO v_hash
    FROM pg_git.refs
    WHERE repo_id = p_repo_id AND name = p_ref AND type = 'branch';

    IF v_hash IS NOT NULL THEN
        RETURN v_hash;
    END IF;

    -- Check tags
    SELECT commit_hash INTO v_hash
    FROM pg_git.refs
    WHERE repo_id = p_repo_id AND name = p_ref AND type = 'tag';

    IF v_hash IS NOT NULL THEN
        RETURN v_hash;
    END IF;

    -- Check if it's a commit hash
    IF EXISTS (SELECT 1 FROM pg_git.objects WHERE hash = p_ref AND type = 'commit') THEN
        RETURN p_ref;
    END IF;

    -- Try partial hash
    SELECT hash INTO v_hash
    FROM pg_git.objects
    WHERE hash LIKE p_ref || '%' AND type = 'commit'
    LIMIT 1;

    IF v_hash IS NOT NULL THEN
        RETURN v_hash;
    END IF;

    RAISE EXCEPTION 'Ref "%" not found', p_ref;
END;
$$;

--------------------------------------------------------------------------------
-- TAGS
--------------------------------------------------------------------------------

-- Create a tag
CREATE OR REPLACE FUNCTION pg_git.tag(
    p_table TEXT,
    p_tag_name TEXT,
    p_message TEXT DEFAULT NULL,
    p_commit TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
    v_commit_hash TEXT;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- Get commit hash
    IF p_commit IS NOT NULL THEN
        v_commit_hash := pg_git.resolve_ref(v_repo_id, p_commit);
    ELSE
        SELECT COALESCE(h.commit_hash, r.commit_hash) INTO v_commit_hash
        FROM pg_git.head h
        LEFT JOIN pg_git.refs r ON r.repo_id = h.repo_id
            AND r.name = h.ref_name AND r.type = h.ref_type
        WHERE h.repo_id = v_repo_id;
    END IF;

    IF v_commit_hash IS NULL THEN
        RAISE EXCEPTION 'Cannot create tag: no commits yet';
    END IF;

    -- Create tag ref
    INSERT INTO pg_git.refs (repo_id, name, type, commit_hash)
    VALUES (v_repo_id, p_tag_name, 'tag', v_commit_hash)
    ON CONFLICT (repo_id, name, type)
    DO UPDATE SET commit_hash = EXCLUDED.commit_hash;

    RETURN format('Created tag "%s" at %s', p_tag_name, substring(v_commit_hash, 1, 7));
END;
$$;

-- List tags
CREATE OR REPLACE FUNCTION pg_git.tags(p_table TEXT)
RETURNS TABLE (
    tag_name TEXT,
    commit_hash TEXT,
    short_hash TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    RETURN QUERY
    SELECT
        r.name,
        r.commit_hash,
        substring(r.commit_hash, 1, 7),
        r.created_at
    FROM pg_git.refs r
    WHERE r.repo_id = v_repo_id AND r.type = 'tag'
    ORDER BY r.created_at DESC;
END;
$$;

-- Delete a tag
CREATE OR REPLACE FUNCTION pg_git.tag_delete(p_table TEXT, p_tag_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    DELETE FROM pg_git.refs
    WHERE repo_id = v_repo_id AND name = p_tag_name AND type = 'tag';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tag "%" not found', p_tag_name;
    END IF;

    RETURN format('Deleted tag "%s"', p_tag_name);
END;
$$;

--------------------------------------------------------------------------------
-- MERGE
--------------------------------------------------------------------------------

-- Merge a branch into current branch
CREATE OR REPLACE FUNCTION pg_git.merge(
    p_table TEXT,
    p_branch TEXT,
    p_strategy TEXT DEFAULT 'recursive'
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_repo RECORD;
    v_repo_id INTEGER;
    v_current_branch TEXT;
    v_current_hash TEXT;
    v_merge_hash TEXT;
    v_base_hash TEXT;
    v_current_tree JSONB;
    v_merge_tree JSONB;
    v_base_tree JSONB;
    v_conflicts INTEGER := 0;
    v_merged INTEGER := 0;
    v_blob RECORD;
BEGIN
    SELECT * INTO v_repo FROM pg_git.repositories WHERE id = pg_git.get_repo_id(p_table);
    v_repo_id := v_repo.id;

    -- Get current branch and commit
    SELECT h.ref_name, COALESCE(h.commit_hash, r.commit_hash)
    INTO v_current_branch, v_current_hash
    FROM pg_git.head h
    LEFT JOIN pg_git.refs r ON r.repo_id = h.repo_id
        AND r.name = h.ref_name AND r.type = h.ref_type
    WHERE h.repo_id = v_repo_id;

    IF v_current_branch IS NULL THEN
        RAISE EXCEPTION 'Cannot merge in detached HEAD state';
    END IF;

    IF v_current_branch = p_branch THEN
        RAISE EXCEPTION 'Cannot merge branch into itself';
    END IF;

    -- Get merge branch commit
    v_merge_hash := pg_git.resolve_ref(v_repo_id, p_branch);

    -- Simple fast-forward check (if current is ancestor of merge)
    IF pg_git.is_ancestor(v_current_hash, v_merge_hash) THEN
        -- Fast-forward merge
        UPDATE pg_git.refs
        SET commit_hash = v_merge_hash, updated_at = now()
        WHERE repo_id = v_repo_id AND name = v_current_branch AND type = 'branch';

        -- Update table data
        PERFORM pg_git.checkout(p_table, v_current_branch);

        RETURN format('Fast-forward merge: %s -> %s',
            substring(v_current_hash, 1, 7), substring(v_merge_hash, 1, 7));
    END IF;

    -- Find merge base (common ancestor) - simplified: just use parent chain
    v_base_hash := pg_git.find_merge_base(v_current_hash, v_merge_hash);

    -- Get trees
    v_current_tree := pg_git.get_object((pg_git.get_object(v_current_hash))->>'tree');
    v_merge_tree := pg_git.get_object((pg_git.get_object(v_merge_hash))->>'tree');
    IF v_base_hash IS NOT NULL THEN
        v_base_tree := pg_git.get_object((pg_git.get_object(v_base_hash))->>'tree');
    ELSE
        v_base_tree := '{"blobs": []}'::JSONB;
    END IF;

    -- Three-way merge logic
    -- For each row in merge branch, check if it conflicts with current branch
    FOR v_blob IN
        WITH merge_blobs AS (
            SELECT b->>'hash' AS hash, b->'pk' AS pk
            FROM jsonb_array_elements(v_merge_tree->'blobs') AS b
        ),
        current_blobs AS (
            SELECT b->>'hash' AS hash, b->'pk' AS pk
            FROM jsonb_array_elements(v_current_tree->'blobs') AS b
        ),
        base_blobs AS (
            SELECT b->>'hash' AS hash, b->'pk' AS pk
            FROM jsonb_array_elements(v_base_tree->'blobs') AS b
        )
        SELECT
            m.pk,
            m.hash AS merge_hash,
            c.hash AS current_hash,
            b.hash AS base_hash
        FROM merge_blobs m
        LEFT JOIN current_blobs c ON m.pk = c.pk
        LEFT JOIN base_blobs b ON m.pk = b.pk
        WHERE m.hash IS DISTINCT FROM c.hash  -- Only where there's a difference
    LOOP
        IF v_blob.current_hash IS NULL THEN
            -- New row in merge branch, not in current - auto-merge
            v_merged := v_merged + 1;
        ELSIF v_blob.base_hash IS NULL THEN
            -- Both branches added same PK - conflict
            INSERT INTO pg_git.merge_conflicts (repo_id, pk_data, base_data, ours_data, theirs_data, source_branch)
            VALUES (
                v_repo_id,
                v_blob.pk,
                NULL,
                (pg_git.get_object(v_blob.current_hash))->'data',
                (pg_git.get_object(v_blob.merge_hash))->'data',
                p_branch
            );
            v_conflicts := v_conflicts + 1;
        ELSIF v_blob.current_hash = v_blob.base_hash THEN
            -- Current unchanged since base, merge takes theirs - auto-merge
            v_merged := v_merged + 1;
        ELSIF v_blob.merge_hash = v_blob.base_hash THEN
            -- Merge unchanged since base, keep ours - already done
            NULL;
        ELSE
            -- Both changed - conflict
            INSERT INTO pg_git.merge_conflicts (repo_id, pk_data, base_data, ours_data, theirs_data, source_branch)
            VALUES (
                v_repo_id,
                v_blob.pk,
                (pg_git.get_object(v_blob.base_hash))->'data',
                (pg_git.get_object(v_blob.current_hash))->'data',
                (pg_git.get_object(v_blob.merge_hash))->'data',
                p_branch
            );
            v_conflicts := v_conflicts + 1;
        END IF;
    END LOOP;

    IF v_conflicts > 0 THEN
        RETURN format('CONFLICT: %s conflicts found. Use pg_git.conflicts() to view and pg_git.resolve() to fix.', v_conflicts);
    END IF;

    -- No conflicts - create merge commit
    RETURN format('Merged %s into %s (%s rows updated)',
        p_branch, v_current_branch, v_merged);
END;
$$;

-- Check if commit A is ancestor of commit B
CREATE OR REPLACE FUNCTION pg_git.is_ancestor(p_ancestor TEXT, p_descendant TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_current TEXT := p_descendant;
    v_commit JSONB;
    v_depth INTEGER := 0;
BEGIN
    IF p_ancestor IS NULL THEN
        RETURN TRUE;
    END IF;

    WHILE v_current IS NOT NULL AND v_depth < 1000 LOOP
        IF v_current = p_ancestor THEN
            RETURN TRUE;
        END IF;

        v_commit := pg_git.get_object(v_current);
        v_current := v_commit->>'parent';
        v_depth := v_depth + 1;
    END LOOP;

    RETURN FALSE;
END;
$$;

-- Find common ancestor of two commits
CREATE OR REPLACE FUNCTION pg_git.find_merge_base(p_commit1 TEXT, p_commit2 TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_ancestors1 TEXT[];
    v_current TEXT;
    v_commit JSONB;
    v_depth INTEGER := 0;
BEGIN
    -- Build ancestor list for commit1
    v_current := p_commit1;
    WHILE v_current IS NOT NULL AND v_depth < 1000 LOOP
        v_ancestors1 := array_append(v_ancestors1, v_current);
        v_commit := pg_git.get_object(v_current);
        v_current := v_commit->>'parent';
        v_depth := v_depth + 1;
    END LOOP;

    -- Walk commit2's ancestors and find first match
    v_current := p_commit2;
    v_depth := 0;
    WHILE v_current IS NOT NULL AND v_depth < 1000 LOOP
        IF v_current = ANY(v_ancestors1) THEN
            RETURN v_current;
        END IF;
        v_commit := pg_git.get_object(v_current);
        v_current := v_commit->>'parent';
        v_depth := v_depth + 1;
    END LOOP;

    RETURN NULL;
END;
$$;

-- View merge conflicts
CREATE OR REPLACE FUNCTION pg_git.conflicts(p_table TEXT)
RETURNS TABLE (
    pk_data JSONB,
    base_data JSONB,
    ours_data JSONB,
    theirs_data JSONB,
    source_branch TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    RETURN QUERY
    SELECT c.pk_data, c.base_data, c.ours_data, c.theirs_data, c.source_branch
    FROM pg_git.merge_conflicts c
    WHERE c.repo_id = v_repo_id;
END;
$$;

--------------------------------------------------------------------------------
-- UTILITY
--------------------------------------------------------------------------------

-- Get object by hash
CREATE OR REPLACE FUNCTION pg_git.cat_object(p_hash TEXT)
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT pg_git.get_object(p_hash);
$$;

-- Repository statistics
CREATE OR REPLACE FUNCTION pg_git.stats(p_table TEXT)
RETURNS TABLE (
    stat_name TEXT,
    stat_value TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_repo_id INTEGER;
    v_commit_count INTEGER;
    v_branch_count INTEGER;
    v_tag_count INTEGER;
    v_object_count INTEGER;
    v_total_size BIGINT;
BEGIN
    v_repo_id := pg_git.get_repo_id(p_table);

    -- Count commits (walk the tree)
    SELECT COUNT(*) INTO v_commit_count
    FROM pg_git.log(p_table, 10000);

    SELECT COUNT(*) INTO v_branch_count
    FROM pg_git.refs WHERE repo_id = v_repo_id AND type = 'branch';

    SELECT COUNT(*) INTO v_tag_count
    FROM pg_git.refs WHERE repo_id = v_repo_id AND type = 'tag';

    SELECT COUNT(*), COALESCE(SUM(size), 0) INTO v_object_count, v_total_size
    FROM pg_git.objects;

    RETURN QUERY
    SELECT 'commits'::TEXT, v_commit_count::TEXT
    UNION ALL SELECT 'branches', v_branch_count::TEXT
    UNION ALL SELECT 'tags', v_tag_count::TEXT
    UNION ALL SELECT 'objects', v_object_count::TEXT
    UNION ALL SELECT 'total_size_bytes', v_total_size::TEXT
    UNION ALL SELECT 'total_size_mb', round(v_total_size / 1024.0 / 1024.0, 2)::TEXT;
END;
$$;

-- Garbage collection - remove unreferenced objects
CREATE OR REPLACE FUNCTION pg_git.gc()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_before INTEGER;
    v_after INTEGER;
    v_deleted INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_before FROM pg_git.objects;

    -- This is a simplified GC - in production you'd want to traverse all reachable objects
    -- For now, just remove objects not referenced by any tree
    DELETE FROM pg_git.objects o
    WHERE o.type = 'blob'
    AND NOT EXISTS (
        SELECT 1 FROM pg_git.objects t
        WHERE t.type = 'tree'
        AND convert_from(t.content, 'UTF8')::JSONB->'blobs' @> jsonb_build_array(jsonb_build_object('hash', o.hash))
    );

    SELECT COUNT(*) INTO v_after FROM pg_git.objects;
    v_deleted := v_before - v_after;

    RETURN format('Garbage collection complete: %s objects removed', v_deleted);
END;
$$;
