# Documentation style

All documentation for `pg_permissions` follows ASD-STE100 Simplified Technical English (STE). This file gives the rules that apply to this project. It does not replace the STE specification.

Exceptions: `research/journal.md` is the raw build record and keeps its original text. The benchmark reports that `bench/run.sh` writes (`bench/baselines/*-<scale>-<shape>*.md`) are generated and keep the format of the harness.

## Words

1. Use only approved STE words, with their approved meaning and part of speech.
2. You can use technical names and technical verbs. In this project these include:
   - Names of Postgres objects and features: table, row, column, schema, index, function, query, policy, role, transaction, trigger, extension, row level security (RLS).
   - SQL keywords, function names, argument names, error codes, file names and commands. Always write these in `code` format.
   - Terms from authorization: permission, relation, tuple, subject, object, model, condition, scope, check, assignment.
   - Product names: Postgres, OpenFGA, Zanzibar, pg_tle, database.dev, Docker, CEL.
3. Use one word for one thing. When a term has a name in this project, use that name every time. Do not use synonyms.
4. Do not use contractions (`don't`, `it's`). Write `do not`, `it is`.
5. Do not use abbreviations such as `e.g.`, `i.e.`, `etc.`, `vs`. Write `for example`, `that is`, or a full list.

### Common replacements

| Do not write | Write |
| --- | --- |
| allow, permit | let, give permission to |
| ensure | make sure |
| utilize | use |
| perform | do |
| obtain, retrieve, fetch | get |
| require | must, is necessary |
| via | through, with |
| since, as (for a reason) | because |
| may, might | can |
| should (for an instruction) | the imperative form of the verb, or `must` |
| in order to | to |
| prior to | before |
| a number of, several | some, or the number |
| currently | now |
| simply, just, easily | (delete the word) |
| set up | install, configure, make |
| find out | find |
| leverage | use |
| additional | more |
| in addition | also |
| however | but |
| therefore | thus, so |

## Verbs

1. Use the active voice. You can use the passive voice in descriptive text only if you do not know who or what does the action.
2. Use only these tenses: simple present, simple past, simple future (`will`).
3. Do not use the `-ing` form of a verb, except in a technical name.
4. Use the past participle only as an adjective (`the stored tuple`) or in a passive sentence that rule 1 permits.
5. Do not use phrasal verbs (`look up`, `carry out`). Use a single approved verb.

## Sentences

1. Procedural sentences (instructions): 20 words maximum.
2. Descriptive sentences: 25 words maximum.
3. Write one instruction in each sentence, unless two actions occur at the same time.
4. Write instructions in the imperative form: "Install the extension."
5. Use the articles `the` and `a`. Do not write in a telegraphic style.
6. Do not use noun clusters of more than three words. Use a preposition to break the cluster.
7. Code, identifiers and values in `code` format count as one word.

## Paragraphs and structure

1. Write one topic in each paragraph.
2. A paragraph has six sentences maximum.
3. Write the most important information first.
4. Use a numbered list for steps in a sequence. Use a bulleted list for items that do not have a sequence.
5. Put a warning or caution before the step it applies to. Start it with a simple command, then give the risk: "Do not drop the schema. You will lose all tuples."
6. Use tables for reference data, for example function arguments and error codes.

## Code examples

1. Each SQL example must run on the current extension file without change, unless the text says it is a fragment.
2. Use named arguments in examples: `permissions.fga_check(subject => 'user:anne', relation => 'viewer', object => 'document:1')`.
3. Show the result when it helps the reader.
4. Keep each line of a code block to 72 characters or less. A line can be longer only if you cannot break it: a long name, a URL, a result, or a psql command such as `\set`.
5. Write SQL keywords in lowercase. Put one clause on each line: `select`, `from`, `where`, `using`, `with check`, `on`, `for`, `to`.
6. Write a call with more than one named argument on many lines. Put one `name => value` on each line, with a two-space indent. Put the `)` on its own line.
7. Write a call that is too long for one line in the same way.
8. Break a long `array[...]` or `'{...}'` value. Put one element on each line, where the syntax lets you.
9. Write JSON in a string with a two-space indent. Keep short JSON on one line if it fits.
10. Break nested calls. Put each level on its own indented line.
11. In `create policy`, put the name, `on`, `for`, `to`, `using (` and `with check (` each on its own line. Indent the expression.
12. Do not change the text of a result or an error message. Put a comment that shows a result on the line after the statement.
13. Break a long shell command with a `\` at the end of the line. Put one group of flags on each line.
