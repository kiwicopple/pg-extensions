-- ---------------------------------------------------------------------------
-- Cedar: the text policy parser (phase 3 of research/plan-cedar.md)
-- ---------------------------------------------------------------------------
-- Standalone work in progress. It loads into a database that already has the
-- 0.1.0 extension installed (it uses permissions._did_you_mean) and moves into
-- pg_permissions--0.1.0.sql once the Cedar evaluator (phase 2) has landed.
--
-- The parser turns Cedar policy text into Cedar's JSON policy format (the EST,
-- research/designs/e-cedar.md section 2), exactly as cedar-policy-cli 4.14.0
-- `translate-policy --direction cedar-to-json` writes it. jsonb equality with
-- the CLI's output is the oracle (wip/check_parser.sh).
--
-- API (internal):
--
--   permissions._cedar_parse_policy(src text) returns jsonb
--     Exactly one policy or template. Returns its EST object:
--       {"effect", "principal", "action", "resource", "conditions",
--        "annotations"?}
--     "annotations" is present only when the policy has some. A template is a
--     policy whose principal or resource scope holds a slot
--     ({"slot": "?principal"}, or "in": {"slot": ...} under "is"); the caller
--     (cedar_put_policy, cedar_put_template) checks which one it wants.
--
--   permissions._cedar_parse_policies(src text) returns jsonb
--     A policy set (zero or more policies), in the CLI's policy-set shape:
--       {"staticPolicies": {id: EST, ...}, "templates": {id: EST, ...},
--        "templateLinks": []}
--     Policy ids follow the CLI: the value of an @id annotation when the
--     policy has one (a bare @id gives ""), else "policy<i>", where i counts
--     every policy and template of the text from 0 in source order. A
--     duplicate id is a parse error.
--
-- Functions (all internal, all in schema permissions): _cedar_parse_raise
-- (the one raise site), _cedar_token_text, _cedar_syntax_error,
-- _cedar_parse_fail, _cedar_tokens, _cedar_unescape, _cedar_parse_expr,
-- _cedar_parse_ref, _cedar_parse_text, _cedar_parse_policy,
-- _cedar_parse_policies. Toolkit dependency: _did_you_mean (and through it
-- _edit_distance). No tables, no settings.
--
-- Both return null for a null src. Errors raise:
--   cedar:parse_error line=<n> column=<n>      SQLSTATE 42601
--   cedar:limit_exceeded limit='<name>'         SQLSTATE 54000
--   cedar:unsupported feature='U+0000'          SQLSTATE 0A000
-- with a MESSAGE that names the token found and what was expected, and a HINT.
--
-- Limits (e-cedar.md section 6): the text of one policy 64 KiB
-- (policy_text), 4,096 expression nodes in one policy (policy_nodes), and an
-- expression nesting depth of 64 (expression_depth: the depth of the EST, and
-- of brackets in the text).
--
-- CLI quirks the EST reproduces (and the evaluator must accept):
--   - A negative integer literal folds into Value (-5 is {"Value": -5}); a
--     minus before anything else is neg. --5 is neg(Value -5).
--     -9223372036854775808 is valid only this way.
--   - action in [A] with one entity is {"op": "in", "entity": A}; with
--     zero or two or more it is {"op": "in", "entities": [...]}.
--   - e has a.b.c (several attributes) is {"has": {"left", "attr": ["a",
--     "b", "c"]}}: attr is an array. One attribute gives a string.
--   - like patterns are one {"Literal": "c"} per character, and "Wildcard"
--     for each *; a * written as an escape (\u{2a}, \x2a) is a wildcard too,
--     only \* is a literal star.
--   - A bare annotation @foo has the value null.
--   - !x applied n times nests n "!" nodes (no folding).

-- Every parse error goes through here: one raise site.
create function permissions._cedar_parse_raise(p_code text, p_detail text, p_message text, hint text)
returns void
language plpgsql
as $$
begin
    raise exception using
        message = p_message,
        errcode = case p_code when 'parse_error' then '42601'
                              when 'limit_exceeded' then '54000'
                              when 'unsupported' then '0A000'
                              else '22023' end,
        detail = 'cedar:' || p_code || coalesce(' ' || p_detail, ''),
        hint = _cedar_parse_raise.hint;
end;
$$;

-- A token for an error message.
create function permissions._cedar_token_text(p_kind text, p_value text)
returns text
language sql
immutable
as $$
    select case p_kind
        when 'eof' then 'end of input'
        when 'str' then format('string literal "%s"', case when length(p_value) > 30 then left(p_value, 27) || '...' else p_value end)
        when 'int' then format('number %s', p_value)
        when 'id' then format('''%s''', p_value)
        when 'slot' then format('slot %s', p_value)
        else format('''%s''', p_kind) end
$$;

-- "unexpected <token> at line L, column C: expected <what>"
create function permissions._cedar_syntax_error(k text[], v text[], ln int[], cl int[], q int, p_expected text, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_parse_raise('parse_error', format('line=%s column=%s', ln[q], cl[q]),
        format('unexpected %s at line %s, column %s: expected %s',
               permissions._cedar_token_text(k[q], v[q]), ln[q], cl[q], p_expected),
        coalesce(hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html'));
end;
$$;

-- Any other parse error, at a position.
create function permissions._cedar_parse_fail(p_message text, p_line int, p_col int, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_parse_raise('parse_error', format('line=%s column=%s', p_line, p_col),
        format('%s at line %s, column %s', p_message, p_line, p_col), hint);
end;
$$;

-- ---------------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------------
-- One regular expression splits the whole text (the scan runs in C, and each
-- match is a token, white space or a comment; the last branch takes any other
-- character, so the matches cover the text). Kinds: id (identifiers and
-- keywords, v is the text), int (v is the digits), str (v is the body between
-- the quotes, still escaped: like patterns read the escapes differently),
-- slot (v is ?name), the punctuators themselves (:: == != <= >= && || ( ) [ ]
-- { } , ; . < > + - * ! : @), and eof (three of them, so a lookahead never
-- leaves the arrays). ln and cl are the line and column (1-based,
-- characters) of each token, off its character offset.
create function permissions._cedar_tokens(p_src text, out k text[], out v text[], out ln int[], out cl int[], out off int[])
language plpgsql
immutable strict
as $$
declare
    m text;
    c text;
    len int;
    nl int;
    line int := 1;
    col int := 1;
    o int := 1;
begin
    k := '{}'; v := '{}'; ln := '{}'; cl := '{}'; off := '{}';
    for m in
        select t[1]
        from regexp_matches(p_src,
            '\s+|//[^\n\r]*|"(?:[^"\\]|\\[^\n])*"|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|\?[A-Za-z_][A-Za-z0-9_]*|::|==|!=|<=|>=|&&|\|\||[\s\S]',
            'g') t
    loop
        c := left(m, 1);
        len := length(m);
        if c ~ '\s' or left(m, 2) = '//' then
            null;
        elsif c = '"' then
            if len = 1 then
                perform permissions._cedar_parse_fail('unterminated string literal', line, col,
                    'Close the string with ". A backslash cannot continue a string on the next line; Cedar strings may contain the line break itself.');
            end if;
            k := k || 'str'::text; v := v || substr(m, 2, len - 2);
        elsif c ~ '[A-Za-z_]' then
            k := k || 'id'::text; v := v || m;
        elsif c ~ '[0-9]' then
            k := k || 'int'::text; v := v || m;
        elsif c = '?' and len > 1 then
            k := k || 'slot'::text; v := v || m;
        elsif m in ('::', '==', '!=', '<=', '>=', '&&', '||', '(', ')', '[', ']', '{', '}', ',', ';', '.', '<', '>', '+', '-', '*', '!', ':', '@') then
            k := k || m; v := v || m;
        else
            perform permissions._cedar_parse_fail(format('invalid character %L', m), line, col,
                case when m in ('=', '&', '|') then format('Cedar has no single %L operator: use %L.', m, m || m)
                     when m = '''' then 'Cedar strings use double quotes: "text".'
                     else 'Outside string literals Cedar uses ASCII letters, digits, _ and its operators. Put other text in a string literal ("...").' end);
        end if;
        if c !~ '\s' and left(m, 2) <> '//' then
            ln := ln || line; cl := cl || col; off := off || o;
        end if;
        nl := len - length(replace(m, E'\n', ''));
        if nl > 0 then
            line := line + nl;
            col := strpos(reverse(m), E'\n');
        else
            col := col + len;
        end if;
        o := o + len;
    end loop;
    k := k || '{eof,eof,eof}'::text[]; v := v || '{"","",""}'::text[];
    ln := ln || array[line, line, line]; cl := cl || array[col, col, col]; off := off || array[o, o, o];
end;
$$;

-- ---------------------------------------------------------------------------
-- String literals
-- ---------------------------------------------------------------------------
-- Cedar reads escapes as Rust does (rustc_lexer): \n \r \t \\ \0 \' \", \xHH
-- up to \x7f, and \u{H...} with 1 to 6 hex digits (underscores allowed, not
-- first), no surrogates, at most 10FFFF. A bare carriage return is an error.
-- U+0000 cannot be held by Postgres text: cedar:unsupported.
--
-- p_pattern false: the decoded text, as a jsonb string.
-- p_pattern true: a like pattern, a jsonb array of "Wildcard" for each * and
-- {"Literal": c} for every other character. \* is a literal star, and a star
-- from any other escape (\u{2a}) is a wildcard, as in Cedar.
create function permissions._cedar_unescape(p_raw text, p_pattern boolean, p_line int, p_col int)
returns jsonb
language plpgsql
immutable
as $$
declare
    m text;
    e text;
    h text;
    cp int;
    ch text;
    s text := '';
    pat jsonb := '[]';
    bad text;
begin
    if strpos(p_raw, '\') = 0 and strpos(p_raw, E'\r') = 0 then
        if not p_pattern then
            return to_jsonb(p_raw);
        end if;
        if p_raw = '' then
            return '[]';
        end if;
        return (select coalesce(jsonb_agg(case when c = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', c) end order by o), '[]')
                from regexp_split_to_table(p_raw, '') with ordinality t(c, o));
    end if;
    for m in
        select t[1] from regexp_matches(p_raw, '[^\\\r]+|\\u\{[0-9A-Fa-f_]*\}|\\x[0-9A-Fa-f]{2}|\\[\s\S]?|\r', 'g') t
    loop
        if left(m, 1) <> '\' and m <> E'\r' then
            if p_pattern then
                pat := pat || (select jsonb_agg(case when c = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', c) end order by o)
                               from regexp_split_to_table(m, '') with ordinality t(c, o));
            else
                s := s || m;
            end if;
            continue;
        end if;
        e := substr(m, 2, 1);
        ch := null;
        bad := null;
        if m = E'\r' then
            bad := 'a bare carriage return';
        elsif e in ('n', 'r', 't', '\', '"', '''') then
            ch := case e when 'n' then E'\n' when 'r' then E'\r' when 't' then E'\t' else e end;
        elsif e = '0' then
            cp := 0;
        elsif e = '*' and p_pattern then
            pat := pat || jsonb_build_array(jsonb_build_object('Literal', '*'));
            continue;
        elsif e = 'x' and length(m) = 4 then
            cp := ('x' || lpad(substr(m, 3), 8, '0'))::bit(32)::int;
            if cp > 127 then
                bad := m;
            end if;
        elsif e = 'u' and length(m) > 3 then
            h := substr(m, 4, length(m) - 4);
            if left(h, 1) = '_' or replace(h, '_', '') = '' or length(replace(h, '_', '')) > 6 then
                bad := m;
            else
                cp := ('x' || lpad(replace(h, '_', ''), 8, '0'))::bit(32)::int;
                if cp > 1114111 or cp between 55296 and 57343 then
                    bad := m;
                end if;
            end if;
        else
            bad := m;
        end if;
        if bad is not null then
            perform permissions._cedar_parse_fail(
                case when left(bad, 1) = '\' then format('invalid escape %s in a string literal', bad)
                     else format('%s in a string literal', bad) end, p_line, p_col,
                case when bad = '\*' then 'Only a like pattern can escape a star (\*). In other strings write * as it is.'
                     when bad = 'a bare carriage return' then 'Write a carriage return in a string as \r.'
                     else 'The escapes are \n, \r, \t, \\, \0, \'', \", \x00 to \x7f, and \u{...} with 1 to 6 hex digits (a Unicode scalar value).' end);
        end if;
        if ch is null then
            if cp = 0 then
                perform permissions._cedar_parse_raise('unsupported', 'feature=''U+0000''',
                    format('a string literal at line %s, column %s contains U+0000, which Postgres text cannot hold', p_line, p_col),
                    'Remove the U+0000 character (\0, \x00 or \u{0}) from the string.');
            end if;
            ch := chr(cp);
        end if;
        if p_pattern then
            pat := pat || jsonb_build_array(case when ch = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', ch) end);
        else
            s := s || ch;
        end if;
    end loop;
    if p_pattern then
        return pat;
    end if;
    return to_jsonb(s);
end;
$$;

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------
--   Expr     = "if" Expr "then" Expr "else" Expr | Or
--   Or       = And { "||" And }                                   prec 1
--   And      = Relation { "&&" Relation }                         prec 2
--   Relation = Add [ RelOp Add ] | Add "has" (Ident {"." Ident} | Str)
--            | Add "like" Str | Add "is" Path [ "in" Add ]       prec 3, one per operand
--   RelOp    = "<" | "<=" | ">" | ">=" | "==" | "!=" | "in"
--   Add      = Mult { ("+" | "-") Mult }                          prec 4
--   Mult     = Unary { "*" Unary }                                prec 5
--   Unary    = ("!" | "-"){0,4} Member      (one kind of operator per run)
--   Member   = Primary { "." Ident [ "(" [Exprs] ")" ] | "[" Str "]" }
--   Primary  = Int | Str | "true" | "false" | Var | Path "::" Str
--            | Path "(" [Exprs] ")" | "(" Expr ")" | "[" [Exprs] "]"
--            | "{" [ (Ident | Str) ":" Expr {"," ...} ] "}"
-- (lists may end with a comma). One function: the binary operators are
-- reduced with an operator stack (precedence climbing without one call per
-- level), and the function calls itself only for a nested expression, so the
-- PL/pgSQL recursion is about the bracket nesting of the text. minprec 4
-- parses an Add (the right side of "is ... in"). lvl is the bracket nesting.
-- Returns the EST node, the next token, the node's depth and its node count.
create function permissions._cedar_parse_expr(k text[], v text[], ln int[], cl int[], p int, lvl int, minprec int,
                                              out node jsonb, out np int, out dep int, out cnt int)
language plpgsql
immutable
as $$
declare
    q int := p;
    r record;
    nodes jsonb[] := '{}';
    deps int[] := '{}';
    nn int := 0;
    ops text[] := '{}';
    opp int[] := '{}';
    no int := 0;
    relq int := 0;
    x jsonb;
    xd int;
    y jsonb;
    a jsonb;
    ad int;
    op text;
    pr int;
    unop text;
    unn int;
    unq int;
    name text;
    nq int;
    key text;
    ty text;
    seg text;
    lit numeric;
    reserved constant text[] := '{true,false,if,then,else,in,is,like,has,__cedar}';
    vars constant text[] := '{principal,action,resource,context}';
    ext_fns constant text[] := '{decimal,ip,datetime,duration}';
    ext_methods constant text[] := '{lessThan,lessThanOrEqual,greaterThan,greaterThanOrEqual,isIpv4,isIpv6,isLoopback,isMulticast,isInRange,offset,durationSince,toDate,toTime,toDays,toHours,toMinutes,toSeconds,toMilliseconds}';
    bin_methods constant text[] := '{contains,containsAll,containsAny,getTag,hasTag}';
    reserved_hint constant text := 'true, false, if, then, else, in, is, like, has and __cedar are reserved. Use a string instead: e["if"], e has "if", {"if": 1}.';
begin
    cnt := 0;
    if lvl > 64 then
        perform permissions._cedar_parse_raise('limit_exceeded', 'limit=''expression_depth''',
            format('the expression at line %s, column %s is nested more than 64 levels deep', ln[p], cl[p]),
            'Split the condition into simpler parts, for example several when clauses.');
    end if;

    if minprec = 0 and k[q] = 'id' and v[q] = 'if' then
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        x := r.node; xd := r.dep; cnt := r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'then' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''then''', 'An if expression is: if <condition> then <value> else <value>.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        y := r.node; xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'else' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''else''', 'An if expression is: if <condition> then <value> else <value>. The else branch is required.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        node := jsonb_build_object('if-then-else', jsonb_build_object('if', x, 'then', y, 'else', r.node));
        dep := 1 + greatest(xd, r.dep); cnt := cnt + r.cnt + 1; np := r.np;
        return;
    end if;

    <<operands>>
    loop
        -- unary operators: a run of one kind, at most 4
        unop := null; unn := 0; unq := q;
        if k[q] in ('!', '-') then
            unop := k[q];
            while k[q] = unop loop
                unn := unn + 1;
                q := q + 1;
            end loop;
            if unn > 4 then
                perform permissions._cedar_parse_fail(format('too many occurrences of ''%s'' (%s)', unop, unn), ln[unq], cl[unq],
                    'Cedar allows at most 4 unary operators in a row. Use parentheses, or remove pairs that cancel.');
            end if;
            if k[q] in ('!', '-') then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                    format('Put the operand of ''%s'' in parentheses: %s(%s...).', unop, unop, k[q]));
            end if;
        end if;

        -- primary
        if k[q] = 'int' then
            lit := v[q]::numeric;
            if unop = '-' and k[q + 1] not in ('.', '[') then
                lit := -lit;                    -- a negative literal: Cedar folds the minus
                unn := unn - 1;
            end if;
            if lit > 9223372036854775807 or lit < -9223372036854775808 then
                perform permissions._cedar_parse_fail(format('integer literal %s is too large', v[q]), ln[q], cl[q],
                    'A Cedar Long is from -9223372036854775808 to 9223372036854775807.');
            end if;
            x := jsonb_build_object('Value', lit);
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'str' then
            x := jsonb_build_object('Value', permissions._cedar_unescape(v[q], false, ln[q], cl[q]));
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = '(' then
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
            x := r.node; xd := r.dep; cnt := cnt + r.cnt; q := r.np;
            if k[q] <> ')' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')'' or an operator', null);
            end if;
            q := q + 1;
        elsif k[q] in ('[', '{') then
            op := k[q];
            a := case op when '[' then '[]' else '{}' end::jsonb;
            ad := 0;
            seg := case op when '[' then ']' else '}' end;
            q := q + 1;
            while k[q] <> seg loop
                if op = '{' then
                    if k[q] = 'id' then
                        key := v[q];
                        if key = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be a record key: %s', key), ln[q], cl[q], reserved_hint);
                        end if;
                    elsif k[q] = 'str' then
                        key := permissions._cedar_unescape(v[q], false, ln[q], cl[q]) #>> '{}';
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a record key (an identifier or a string literal)', null);
                    end if;
                    if a ? key then
                        perform permissions._cedar_parse_fail(format('duplicate key %L in a record literal', key), ln[q], cl[q],
                            'Each key of a record literal must be different.');
                    end if;
                    if k[q + 1] <> ':' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, ''':''', 'A record literal is {key: value, ...}.');
                    end if;
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, lvl + 1, 0);
                    a := a || jsonb_build_object(key, r.node);
                else
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    a := a || jsonb_build_array(r.node);
                end if;
                ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                if k[q] = ',' then
                    q := q + 1;
                elsif k[q] <> seg then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, format(''','' or ''%s''', seg), null);
                end if;
            end loop;
            x := jsonb_build_object(case op when '[' then 'Set' else 'Record' end, a);
            xd := ad + 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'slot' then
            perform permissions._cedar_parse_fail(format('found template slot %s in a condition', v[q]), ln[q], cl[q],
                'Slots (?principal, ?resource) can appear only in the policy scope, not in when or unless clauses.');
        elsif k[q] = 'id' and v[q] in ('true', 'false') then
            x := jsonb_build_object('Value', v[q] = 'true');
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'id' and v[q] in ('if', 'then', 'else', 'in', 'is', 'like', 'has') then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                case when v[q] = 'if' then 'Put an if expression in parentheses here: (if c then a else b).' end);
        elsif k[q] = 'id' then
            nq := q;
            name := v[q];
            q := q + 1;
            while k[q] = '::' and k[q + 1] = 'id' loop
                name := name || '::' || v[q + 1];
                q := q + 2;
            end loop;
            if k[q] = '::' or k[q] = '(' or nq + 1 < q then
                foreach seg in array string_to_array(name, '::') loop
                    if seg = any (reserved) then
                        perform permissions._cedar_parse_fail(
                            case when seg = '__cedar' then format('the name %s contains __cedar, which is reserved', name)
                                 else format('this identifier is reserved and cannot be used in a name: %s', seg) end,
                            ln[nq], cl[nq], 'Rename the entity type or namespace.');
                    end if;
                end loop;
            end if;
            if k[q] = '::' and k[q + 1] = 'str' then
                x := jsonb_build_object('Value', jsonb_build_object('__entity',
                        jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]))));
                xd := 1; cnt := cnt + 1; q := q + 2;
            elsif k[q] = '::' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an identifier or a quoted entity id',
                    'An entity is written Type::"id", for example User::"alice".');
            elsif k[q] = '(' then
                if name = any (vars) then
                    perform permissions._cedar_parse_fail(format('%s(...) is not a valid function call', name), ln[nq], cl[nq],
                        'Variables cannot be called as functions.');
                elsif name = any (ext_methods || bin_methods || '{isEmpty}'::text[]) then
                    perform permissions._cedar_parse_fail(format('%s is a method, not a function', name), ln[nq], cl[nq],
                        format('Use a method call: e.%s(...).', name));
                elsif name <> all (ext_fns) then
                    perform permissions._cedar_parse_fail(format('%s is not a valid function', name), ln[nq], cl[nq],
                        permissions._did_you_mean(name, ext_fns, 'The extension functions are'));
                end if;
                a := '[]'; ad := 0;
                q := q + 1;
                while k[q] <> ')' loop
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    a := a || jsonb_build_array(r.node);
                    ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                    if k[q] = ',' then
                        q := q + 1;
                    elsif k[q] <> ')' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                    end if;
                end loop;
                x := jsonb_build_object(name, a);
                xd := ad + 1; cnt := cnt + 1; q := q + 1;
            elsif nq + 1 = q and name = any (vars) then
                x := jsonb_build_object('Var', name);
                xd := 1; cnt := cnt + 1;
            else
                perform permissions._cedar_parse_fail(format('invalid variable: %s', name), ln[nq], cl[nq],
                    coalesce(permissions._did_you_mean(name, vars, 'The Cedar variables are') || ' ', '')
                    || format('For a string write "%s"; for an entity write %s::"id".', name, name));
            end if;
        else
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression', null);
        end if;

        -- member access and method calls
        loop
            if k[q] = '.' then
                if k[q + 1] <> 'id' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an attribute or method name', null);
                end if;
                name := v[q + 1];
                if name = any (reserved) then
                    perform permissions._cedar_parse_fail(
                        case when name = '__cedar' then 'the name __cedar is reserved'
                             else format('this identifier is reserved and cannot be used: %s', name) end,
                        ln[q + 1], cl[q + 1], reserved_hint);
                end if;
                if k[q + 2] = '(' then
                    nq := q + 1;
                    a := '[]'; ad := 0;
                    q := q + 3;
                    while k[q] <> ')' loop
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                        a := a || jsonb_build_array(r.node);
                        ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                        if k[q] = ',' then
                            q := q + 1;
                        elsif k[q] <> ')' then
                            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                        end if;
                    end loop;
                    q := q + 1;
                    if name = any (bin_methods) or name = 'isEmpty' then
                        if jsonb_array_length(a) <> (case when name = 'isEmpty' then 0 else 1 end) then
                            perform permissions._cedar_parse_fail(
                                format('call to %s requires exactly %s, but got %s', name,
                                       case when name = 'isEmpty' then '0 arguments' else '1 argument' end,
                                       jsonb_array_length(a) || case when jsonb_array_length(a) = 1 then ' argument' else ' arguments' end),
                                ln[nq], cl[nq],
                                case when name = 'isEmpty' then 'Write s.isEmpty().' else format('Write e.%s(x) with one argument.', name) end);
                        end if;
                        x := case when name = 'isEmpty' then jsonb_build_object(name, jsonb_build_object('arg', x))
                                  else jsonb_build_object(name, jsonb_build_object('left', x, 'right', a -> 0)) end;
                    elsif name = any (ext_methods) then
                        x := jsonb_build_object(name, jsonb_build_array(x) || a);
                    elsif name = any (ext_fns) then
                        perform permissions._cedar_parse_fail(format('%s is a function, not a method', name), ln[nq], cl[nq],
                            format('Use a function call: %s(...).', name));
                    else
                        perform permissions._cedar_parse_fail(format('%s is not a valid method', name), ln[nq], cl[nq],
                            permissions._did_you_mean(name, bin_methods || ext_methods || '{isEmpty}'::text[], 'The methods are'));
                    end if;
                    xd := 1 + greatest(xd, ad); cnt := cnt + 1;
                else
                    x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', name));
                    xd := xd + 1; cnt := cnt + 1; q := q + 2;
                end if;
            elsif k[q] = '[' then
                if k[q + 1] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'a string literal',
                        'Only an attribute name in a string literal can follow [ : e["name"].');
                end if;
                if k[q + 2] <> ']' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 2, ''']''', null);
                end if;
                x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1])));
                xd := xd + 1; cnt := cnt + 1; q := q + 3;
            elsif k[q] = '(' then
                perform permissions._cedar_parse_fail('function calls must be of the form name(arg1, arg2, ...)', ln[q], cl[q],
                    'Only extension functions (decimal, ip, datetime, duration) and methods (e.name(...)) can be called.');
            else
                exit;
            end if;
        end loop;

        for i in 1..unn loop
            x := jsonb_build_object(case unop when '!' then '!' else 'neg' end, jsonb_build_object('arg', x));
            xd := xd + 1; cnt := cnt + 1;
        end loop;
        nn := nn + 1; nodes[nn] := x; deps[nn] := xd;

        -- binary operators, and the has / like / is relations
        <<binops>>
        loop
            op := null; pr := null;
            if k[q] = '||' then op := '||'; pr := 1;
            elsif k[q] = '&&' then op := '&&'; pr := 2;
            elsif k[q] in ('<', '<=', '>', '>=', '==', '!=') then op := k[q]; pr := 3;
            elsif k[q] = 'id' and v[q] in ('in', 'has', 'like', 'is') then op := v[q]; pr := 3;
            elsif k[q] in ('+', '-') then op := k[q]; pr := 4;
            elsif k[q] = '*' then op := '*'; pr := 5;
            end if;
            if pr is null or pr < minprec then
                exit operands;
            end if;
            while no > 0 and (opp[no] > pr or (opp[no] = pr and pr <> 3)) loop
                nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
                deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
                nn := nn - 1; no := no - 1; cnt := cnt + 1;
            end loop;
            if pr = 3 then
                if relq > 0 then
                    perform permissions._cedar_parse_fail(
                        format('multiple relational operators (%s at line %s, column %s, then %s)', v[relq], ln[relq], cl[relq], v[q]),
                        ln[q], cl[q], 'Use parentheses to make the order explicit, for example (a == b) == c.');
                end if;
                relq := q;
            elsif pr < 3 then
                relq := 0;
            end if;
            if op in ('has', 'like', 'is') then
                x := nodes[nn]; xd := deps[nn];
                nq := q;
                q := q + 1;
                if op = 'has' then
                    if k[q] = 'str' then
                        x := jsonb_build_object('has', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q], false, ln[q], cl[q])));
                        q := q + 1;
                    elsif k[q] = 'id' then
                        a := '[]';
                        loop
                            if v[q] = any (reserved) then
                                perform permissions._cedar_parse_fail(
                                    case when v[q] = '__cedar' then 'the name __cedar is reserved'
                                         else format('this identifier is reserved and cannot be used: %s', v[q]) end,
                                    ln[q], cl[q], reserved_hint);
                            end if;
                            a := a || to_jsonb(v[q]);
                            q := q + 1;
                            exit when k[q] <> '.' or k[q + 1] <> 'id';
                            q := q + 1;
                        end loop;
                        x := jsonb_build_object('has', jsonb_build_object('left', x,
                                'attr', case when jsonb_array_length(a) = 1 then a -> 0 else a end));
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an attribute name (identifiers separated by ''.'', or a string literal)', null);
                    end if;
                elsif op = 'like' then
                    if k[q] <> 'str' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a pattern string literal',
                            'The right side of like is a string literal, where * matches any text and \* is a literal star.');
                    end if;
                    x := jsonb_build_object('like', jsonb_build_object('left', x, 'pattern', permissions._cedar_unescape(v[q], true, ln[q], cl[q])));
                    q := q + 1;
                else
                    if k[q] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity type name',
                            case when k[q] = 'str' then format('Remove the quotes: is %s.', v[q]) end);
                    end if;
                    ty := v[q];
                    nq := q;
                    q := q + 1;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    foreach seg in array string_to_array(ty, '::') loop
                        if seg = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                                ln[nq], cl[nq], 'Rename the entity type or namespace.');
                        end if;
                    end loop;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''in'', an operator or the end of the expression',
                            'The right side of is is an entity type, such as User or App::User, not an entity.');
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 4);
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty, 'in', r.node));
                        xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
                    else
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty));
                    end if;
                end if;
                if k[q] in ('+', '-', '*', '.', '[', '(', '::') then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''&&'', ''||'' or the end of the expression',
                        format('The right side of %s must stand alone. Use parentheses around the whole %s expression.', op, op));
                end if;
                nodes[nn] := x; deps[nn] := xd + 1; cnt := cnt + 1;
                continue binops;
            end if;
            no := no + 1; ops[no] := op; opp[no] := pr;
            q := q + 1;
            exit binops;
        end loop;
    end loop;

    while no > 0 loop
        nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
        deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
        nn := nn - 1; no := no - 1; cnt := cnt + 1;
    end loop;
    node := nodes[1]; dep := deps[1]; np := q;
end;
$$;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
-- An entity in the scope: Path "::" Str. Returns {"type", "id"} and the next
-- token. p_var names the scope variable for the messages.
create function permissions._cedar_parse_ref(k text[], v text[], ln int[], cl int[], p int, p_var text,
                                             out ent jsonb, out np int)
language plpgsql
immutable
as $$
declare
    q int := p;
    name text;
    seg text;
begin
    if k[q] = 'str' then
        perform permissions._cedar_parse_fail(format('expected an entity uid for %s, found a string literal', p_var), ln[q], cl[q],
            format('Include the entity type: %s::"%s".', case p_var when 'action' then 'Action' else 'User' end, v[q]));
    elsif k[q] = '[' then
        perform permissions._cedar_parse_fail(format('expected a single entity uid for %s, found a set', p_var), ln[q], cl[q],
            'Only the action scope takes a list, with in: action in [Action::"a", Action::"b"].');
    elsif k[q] <> 'id' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity uid (Type::"id")', null);
    end if;
    name := v[q];
    q := q + 1;
    while k[q] = '::' and k[q + 1] = 'id' loop
        name := name || '::' || v[q + 1];
        q := q + 2;
    end loop;
    if k[q] <> '::' or k[q + 1] <> 'str' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, case when k[q] = '::' then q + 1 else q end,
            format('''::'' and a quoted entity id after %s', name),
            format('An entity is written Type::"id", for example %s::"alice".', name));
    end if;
    foreach seg in array string_to_array(name, '::') loop
        if seg in ('true', 'false', 'if', 'then', 'else', 'in', 'is', 'like', 'has', '__cedar') then
            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                ln[p], cl[p], 'Rename the entity type or namespace.');
        end if;
    end loop;
    ent := jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]));
    if p_var = 'action' and name <> 'Action' and name not like '%::Action' then
        perform permissions._cedar_parse_fail(format('expected an entity uid with type Action but got %s::"%s"', name, ent ->> 'id'),
            ln[p], cl[p], 'Action entities have the type Action, optionally in a namespace (App::Action).');
    end if;
    np := q + 2;
end;
$$;

-- The policies of a text. p_single: exactly one, returned as its EST; else
-- the policy-set object (see the top of this file).
create function permissions._cedar_parse_text(p_src text, p_single boolean)
returns jsonb
language plpgsql
immutable
as $$
declare
    t record;
    r record;
    k text[];
    v text[];
    ln int[];
    cl int[];
    off int[];
    q int := 1;
    n int := 0;
    start int;
    annos jsonb;
    pid text;
    eff text;
    scope jsonb;
    conds jsonb;
    est jsonb;
    is_template boolean;
    statics jsonb := '{}';
    templates jsonb := '{}';
    nodes int;
    sv text;
    ent jsonb;
    ents jsonb;
    ty text;
    nq int;
    kind text;
    scope_hint constant text := 'A policy scope lists principal, action and resource, in that order: permit (principal, action, resource);';
begin
    if p_single and octet_length(p_src) > 65536 then
        perform permissions._cedar_parse_raise('limit_exceeded', 'limit=''policy_text''',
            format('the policy text is %s bytes, more than the limit of 65536', octet_length(p_src)),
            'Split the policy into several smaller policies.');
    end if;
    t := permissions._cedar_tokens(p_src);
    k := t.k; v := t.v; ln := t.ln; cl := t.cl; off := t.off;

    while k[q] <> 'eof' loop
        start := q;
        annos := '{}';
        pid := null;
        nodes := 0;

        -- annotations
        while k[q] = '@' loop
            if k[q + 1] <> 'id' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an annotation name', 'An annotation is @name("value") or @name.');
            end if;
            if annos ? v[q + 1] then
                perform permissions._cedar_parse_fail(format('duplicate annotation @%s', v[q + 1]), ln[q], cl[q],
                    'Each annotation name may appear once in a policy.');
            end if;
            if k[q + 2] = '(' then
                if k[q + 3] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 3, 'a string literal', 'An annotation is @name("value") or @name.');
                end if;
                if k[q + 4] <> ')' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 4, ''')''', 'An annotation is @name("value") or @name.');
                end if;
                annos := annos || jsonb_build_object(v[q + 1], permissions._cedar_unescape(v[q + 3], false, ln[q + 3], cl[q + 3]));
                q := q + 5;
            else
                annos := annos || jsonb_build_object(v[q + 1], null);
                q := q + 2;
            end if;
        end loop;
        if annos ? 'id' then
            pid := coalesce(annos ->> 'id', '');
        end if;

        -- effect
        if k[q] <> 'id' or v[q] not in ('permit', 'forbid') then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy effect: %s', v[q]), ln[q], cl[q],
                    permissions._did_you_mean(v[q], '{permit,forbid}', 'A policy starts with'));
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''permit'' or ''forbid''',
                'A policy is: [@annotations] permit|forbid (principal, action, resource) [when { ... }] [unless { ... }];');
        end if;
        eff := v[q];
        q := q + 1;
        if k[q] <> '(' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''(''', scope_hint);
        end if;
        q := q + 1;

        -- scope: principal, action, resource
        scope := '{}';
        is_template := false;
        foreach sv in array array['principal', 'action', 'resource'] loop
            if k[q] <> 'id' or v[q] <> sv then
                if k[q] = 'id' and v[q] in ('principal', 'action', 'resource', 'context') then
                    perform permissions._cedar_parse_fail(format('found the variable %s where the variable %s must be', v[q], sv), ln[q], cl[q], scope_hint);
                elsif k[q] = 'id' then
                    perform permissions._cedar_parse_fail(format('found %s where the variable %s must be', v[q], sv), ln[q], cl[q],
                        coalesce(permissions._did_you_mean(v[q], array[sv], 'The scope variable here is') || ' ', '') || scope_hint);
                elsif k[q] = ')' then
                    perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope', sv), ln[q], cl[q], scope_hint);
                end if;
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''%s''', sv), scope_hint);
            end if;
            nq := q;
            q := q + 1;
            if k[q] = ':' then
                perform permissions._cedar_parse_fail('type constraints using : are not supported', ln[q], cl[q],
                    format('Use is instead: %s is User.', sv));
            end if;
            if sv = 'action' then
                if k[q] = '==' then
                    if k[q + 1] = 'slot' then
                        perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                            'Templates have slots for the principal and the resource only.');
                    end if;
                    r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                    scope := scope || jsonb_build_object('action', jsonb_build_object('op', '==', 'entity', r.ent));
                    q := r.np;
                elsif k[q] = 'id' and v[q] = 'in' then
                    if k[q + 1] = '[' then
                        ents := '[]';
                        q := q + 2;
                        while k[q] <> ']' loop
                            r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                            ents := ents || jsonb_build_array(r.ent);
                            q := r.np;
                            if k[q] = ',' then
                                q := q + 1;
                            elsif k[q] <> ']' then
                                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '']''', null);
                            end if;
                        end loop;
                        q := q + 1;
                        scope := scope || jsonb_build_object('action',
                            case when jsonb_array_length(ents) = 1 then jsonb_build_object('op', 'in', 'entity', ents -> 0)
                                 else jsonb_build_object('op', 'in', 'entities', ents) end);
                    else
                        if k[q + 1] = 'slot' then
                            perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                                'Templates have slots for the principal and the resource only.');
                        end if;
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                        scope := scope || jsonb_build_object('action', jsonb_build_object('op', 'in', 'entity', r.ent));
                        q := r.np;
                    end if;
                elsif k[q] = 'id' and v[q] = 'is' then
                    perform permissions._cedar_parse_fail('is cannot appear in the action scope', ln[q], cl[q],
                        'Move action is ... into a when condition.');
                else
                    scope := scope || '{"action": {"op": "All"}}';
                end if;
            else
                kind := null;
                if k[q] = 'id' and v[q] = 'is' then
                    if k[q + 1] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an entity type name',
                            case when k[q + 1] = 'str' then format('Remove the quotes: is %s.', v[q + 1]) end);
                    end if;
                    ty := v[q + 1];
                    q := q + 2;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    if ty ~ '(^|::)(true|false|if|then|else|in|is|like|has|__cedar)(::|$)' then
                        perform permissions._cedar_parse_fail(format('the type name %s uses a reserved identifier', ty), ln[nq], cl[nq],
                            'true, false, if, then, else, in, is, like, has and __cedar are reserved.');
                    end if;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''in'', '','' or '')'' after the type %s', ty),
                            format('is takes an entity type; to name one entity use ==: %s == %s::"id".', sv, ty));
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        kind := 'is_in';
                        q := q + 1;
                    else
                        scope := scope || jsonb_build_object(sv, jsonb_build_object('op', 'is', 'entity_type', ty));
                    end if;
                elsif k[q] = '==' then
                    kind := '==';
                    q := q + 1;
                elsif k[q] = 'id' and v[q] = 'in' then
                    kind := 'in';
                    q := q + 1;
                else
                    scope := scope || jsonb_build_object(sv, '{"op": "All"}'::jsonb);
                end if;
                if kind is not null then
                    if k[q] = 'slot' then
                        if v[q] <> '?' || sv then
                            perform permissions._cedar_parse_fail(format('expected an entity uid or the slot ?%s, found %s', sv, v[q]), ln[q], cl[q],
                                format('The %s scope can hold only the slot ?%s.', sv, sv));
                        end if;
                        ent := jsonb_build_object('slot', v[q]);
                        is_template := true;
                        q := q + 1;
                    else
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                        ent := jsonb_build_object('entity', r.ent);
                        q := r.np;
                    end if;
                    scope := scope || jsonb_build_object(sv,
                        case kind when 'is_in' then jsonb_build_object('op', 'is', 'entity_type', ty, 'in', ent)
                                  else jsonb_build_object('op', kind) || ent end);
                end if;
            end if;
            if sv <> 'resource' then
                if k[q] <> ',' then
                    if k[q] = ')' then
                        perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope',
                            case sv when 'principal' then 'action' else 'resource' end), ln[q], cl[q], scope_hint);
                    end if;
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''',''', scope_hint);
                end if;
                q := q + 1;
            end if;
        end loop;
        if k[q] = ',' and k[q + 1] = ')' then
            q := q + 1;
        end if;
        if k[q] <> ')' then
            if k[q] = ',' and k[q + 1] = 'id' then
                perform permissions._cedar_parse_fail(format('this policy has an extra element in the scope: %s', v[q + 1]), ln[q + 1], cl[q + 1],
                    scope_hint || ' Conditions go in when or unless clauses after the scope.');
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')''', scope_hint);
        end if;
        q := q + 1;

        -- conditions
        conds := '[]';
        while k[q] = 'id' and v[q] in ('when', 'unless') loop
            if k[q + 1] <> '{' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, '''{''', format('A condition is %s { <expression> }.', v[q]));
            end if;
            if k[q + 2] = '}' then
                perform permissions._cedar_parse_fail(format('the %s condition clause is empty', v[q]), ln[q], cl[q],
                    format('Write an expression between the braces, or remove the %s clause.', v[q]));
            end if;
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, 1, 0);
            if k[r.np] <> '}' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, r.np, 'an operator or ''}''', null);
            end if;
            if r.dep > 64 then
                perform permissions._cedar_parse_raise('limit_exceeded', 'limit=''expression_depth''',
                    format('the %s condition at line %s, column %s is %s levels deep, more than the limit of 64', v[q], ln[q], cl[q], r.dep),
                    'Split the condition into simpler parts, for example several when clauses.');
            end if;
            nodes := nodes + r.cnt;
            conds := conds || jsonb_build_array(jsonb_build_object('kind', v[q], 'body', r.node));
            q := r.np + 1;
        end loop;
        if k[q] <> ';' then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy condition: %s', v[q]), ln[q], cl[q],
                    coalesce(permissions._did_you_mean(v[q], '{when,unless}', 'A condition starts with'), '')
                    || case when v[q] in ('permit', 'forbid') then ' Or end the previous policy with '';''.' else '' end);
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''when'', ''unless'' or '';''',
                case when k[q] in ('eof', '@') then 'End each policy with '';''.' end);
        end if;
        if nodes > 4096 then
            perform permissions._cedar_parse_raise('limit_exceeded', 'limit=''policy_nodes''',
                format('the policy at line %s, column %s has %s expression nodes, more than the limit of 4096', ln[start], cl[start], nodes),
                'Split the policy into several smaller policies.');
        end if;
        if not p_single and octet_length(substr(p_src, off[start], off[q] + 1 - off[start])) > 65536 then
            perform permissions._cedar_parse_raise('limit_exceeded', 'limit=''policy_text''',
                format('the policy at line %s, column %s is more than 65536 bytes long', ln[start], cl[start]),
                'Split the policy into several smaller policies.');
        end if;
        q := q + 1;

        est := jsonb_build_object('effect', eff) || scope || jsonb_build_object('conditions', conds);
        if annos <> '{}' then
            est := est || jsonb_build_object('annotations', annos);
        end if;
        if p_single then
            if k[q] <> 'eof' then
                perform permissions._cedar_parse_fail('expected exactly one policy, found more text after the first', ln[q], cl[q],
                    'Put each policy or template in its own call.');
            end if;
            return est;
        end if;
        pid := coalesce(pid, 'policy' || n);
        if statics ? pid or templates ? pid then
            perform permissions._cedar_parse_fail(format('duplicate template or policy id %L', pid), ln[start], cl[start],
                'Policy ids come from @id("...") or are policy0, policy1, ... by position. Give each policy a different @id.');
        end if;
        if is_template then
            templates := templates || jsonb_build_object(pid, est);
        else
            statics := statics || jsonb_build_object(pid, est);
        end if;
        n := n + 1;
    end loop;
    if p_single then
        perform permissions._cedar_parse_fail('expected a policy, found no policy', ln[q], cl[q],
            'Write one policy, for example: permit (principal, action, resource);');
    end if;
    return jsonb_build_object('staticPolicies', statics, 'templates', templates, 'templateLinks', '[]'::jsonb);
end;
$$;

-- Exactly one policy or template: its EST.
create function permissions._cedar_parse_policy(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, true)
$$;

-- A policy set: {"staticPolicies", "templates", "templateLinks": []}.
create function permissions._cedar_parse_policies(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, false)
$$;
