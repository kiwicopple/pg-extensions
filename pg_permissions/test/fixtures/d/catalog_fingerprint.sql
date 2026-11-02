-- The catalog of schema `permissions` in the current database, as two text
-- arrays in psql variables (\gset with the prefix in :fp_prefix):
--
--   <prefix>funcs   one entry per function: signature, md5 of
--                   pg_get_functiondef (body, language, volatility, strict,
--                   security definer, settings, defaults), ACL, comment
--   <prefix>rels    one entry per table, view, sequence, composite type, index,
--                   constraint, policy, trigger and other type: name, kind,
--                   definition, ACL. Columns are listed by name, not position.
--
-- Two databases with equal arrays have the same extension objects. Used by
-- spec/d/05_upgrade.sql to compare an upgraded install with a fresh one.
select
    coalesce((
        select array_agg(format('%s(%s) returns %s | def %s | acl %s | comment %s',
                                p.proname, pg_get_function_identity_arguments(p.oid),
                                pg_get_function_result(p.oid), md5(pg_get_functiondef(p.oid)),
                                coalesce(p.proacl::text, '-'), coalesce(md5(obj_description(p.oid, 'pg_proc')), '-'))
                         order by 1)
        from pg_proc p
        where p.pronamespace = 'permissions'::regnamespace
    ), '{}') as funcs,
    coalesce((
        select array_agg(e order by e) from (
            -- tables, views, sequences, composite types, indexes: kind, ACL, options, columns
            select format('rel %s kind %s rls %s/%s acl %s opts %s cols %s',
                          c.relname, c.relkind, c.relrowsecurity, c.relforcerowsecurity,
                          coalesce(c.relacl::text, '-'), coalesce(c.reloptions::text, '-'),
                          (select string_agg(format('%s %s%s%s', a.attname, format_type(a.atttypid, a.atttypmod),
                                                    case when a.attnotnull then ' not null' else '' end,
                                                    coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')),
                                             ', ' order by a.attname)
                           from pg_attribute a
                           left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                           where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)) as e
            from pg_class c
            where c.relnamespace = 'permissions'::regnamespace
            union all
            select format('index %s', pg_get_indexdef(i.indexrelid))
            from pg_index i join pg_class c on c.oid = i.indexrelid
            where c.relnamespace = 'permissions'::regnamespace
            union all
            select format('constraint %s on %s: %s', co.conname, co.conrelid::regclass, pg_get_constraintdef(co.oid))
            from pg_constraint co
            where co.connamespace = 'permissions'::regnamespace
            union all
            select format('policy %s on %s: %s %s %s using %s check %s', po.polname, po.polrelid::regclass,
                          po.polcmd, po.polpermissive, po.polroles::regrole[],
                          pg_get_expr(po.polqual, po.polrelid), pg_get_expr(po.polwithcheck, po.polrelid))
            from pg_policy po join pg_class c on c.oid = po.polrelid
            where c.relnamespace = 'permissions'::regnamespace
            union all
            select format('trigger %s', pg_get_triggerdef(t.oid))
            from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where c.relnamespace = 'permissions'::regnamespace and not t.tgisinternal
            union all
            select format('type %s kind %s acl %s', t.typname, t.typtype, coalesce(t.typacl::text, '-'))
            from pg_type t
            where t.typnamespace = 'permissions'::regnamespace
            union all
            select format('schema acl %s', coalesce(n.nspacl::text, '-'))
            from pg_namespace n
            where n.nspname = 'permissions'
        ) x
    ), '{}') as rels
\gset :fp_prefix
