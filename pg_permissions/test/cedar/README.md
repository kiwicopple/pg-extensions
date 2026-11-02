# Cedar oracle: cedar-integration-tests

This directory vendors Cedar's own integration tests and turns them into TAP spec files for the Cedar model (`cedar_*`). The tests are the oracle in the same way that `test/fga_abac/` is the oracle for FGA conditions. The design that the tests check is in [`../../research/designs/e-cedar.md`](../../research/designs/e-cedar.md), and the work plan is in [`../../research/plan-cedar.md`](../../research/plan-cedar.md).

The pinned release is Cedar 4.14.0: [cedar-integration-tests](https://github.com/cedar-policy/cedar-integration-tests) at `b157547` (tag `v4.14.0`). `upstream/SOURCE` records the commit, the corpus hash and the CLI that translated the policies.

## Files

| File | What it is |
| --- | --- |
| `vendor.sh` | Fetches the pinned commit, builds the Cedar CLI of the same release in Docker, translates every policy set and schema to JSON, and runs `convert.py`. Run it only to move to a new Cedar release. |
| `convert.py` | Turns the upstream tree into `cases/`. Its docstring documents the case format. |
| `cases/handwritten.jsonl` | The 24 handwritten tests, one JSON object per line. |
| `cases/corpus-NN.jsonl.gz` | The 5,677 generated corpus tests, in 8 gzip shards (3.3 MB in total). |
| `upstream/` | Verbatim copies of the handwritten `tests/` and `sample-data/`, plus `LICENSE`, `NOTICE` and `SOURCE`. The 188 MB corpus is not committed. |
| `generate.py` | Writes TAP spec files, prints corpus counts, and tallies a test log. |
| `fixture.sql` | `cedar_test.reset()` and `cedar_test.authz(...)`, which every generated file includes. |
| `skip.tsv` | Requests that are not run, each with a reason. |
| `spec/` | The default output of `generate.py`. Git ignores it, and `test/run.sh` does not run it. |

`test/run.sh` runs the oracle: before each run of the extension it calls `generate.py suite`, which writes the runs listed in `SUITE` (in `generate.py`) into `test/spec/d/`. Git ignores those files too (`test/spec/d/.gitignore`). `SUITE` has six runs:

| Run | Files | Assertions |
| --- | --- | --- |
| `--phase 2 --features decimal,ipaddr,datetime,duration` | `70_cedar_oracle` | 45,494 requests: the whole corpus |
| the same, `--mode overlay` | `72_cedar_oracle_overlay` | 31,872 requests |
| the same, `--reduce-parents` | `74_cedar_oracle_reduced` | 11,976 requests |
| `--phase 3 --features decimal,ipaddr,datetime,duration` | `71_cedar_oracle_text` | 45,492 requests and 5,708 stored ESTs |
| `--format text --parse-est` | `77_cedar_oracle_parse` | 5,708 policies and 5 policy sets |
| `--phase 4c --features all` | `76_cedar_oracle_templates` | 19,156 requests, through the links of every case with an entity in a scope |

Since phases 4a and 4b, every run includes the extension types (`--features`), so `70_` alone runs every request of the corpus. The six runs write 190 files and 197 MB in about 9 seconds.

## Commands

Run these commands from the `pg_permissions/` directory. The generator needs only Python 3 and its standard library.

```bash
python3 -I test/cedar/generate.py --stats                  # counts by format, feature, schema use, sizes
python3 -I test/cedar/generate.py --dry-run --phase 2      # list the files a run would write; writes nothing
python3 -I test/cedar/generate.py --phase 2                # write test/cedar/spec/*.sql (not run by test/run.sh)
python3 -I test/cedar/generate.py --suite --phase 2        # write test/spec/d/70_cedar_oracle_NN.sql
python3 -I test/cedar/generate.py suite                    # the SUITE runs, as test/run.sh does
./test/run.sh -v cedar_oracle > /tmp/cedar.out
python3 -I test/cedar/generate.py report /tmp/cedar.out --phase 2
python3 -I test/cedar/generate.py report /tmp/cedar.out --phase 2 --mode overlay
python3 -I test/cedar/generate.py report /tmp/cedar.out --phase 2 --reduce-parents
python3 -I test/cedar/generate.py report /tmp/cedar.out --phase 3
python3 -I test/cedar/generate.py report /tmp/cedar.out --format text --parse-est
python3 -I test/cedar/generate.py report /tmp/cedar.out --phase 4c
```

The `--suite` flag is the only option that writes into `test/spec/d/`. The flag first deletes the files of the same prefix, so a run never leaves stale files behind.

### Selecting cases

| Option | Values | Meaning |
| --- | --- | --- |
| `--phase` | `2`, `3`, `4a`, `4b`, `4c`, `all` | A preset for the options below (see the next table). |
| `--format` | `json`, `text` | How policies are stored. `json` passes each policy as its EST (`policy_json`). `text` passes the Cedar text of the policy (`policy`). |
| `--mode` | `stored`, `overlay` | How entities reach the request. `stored` calls `cedar_put_entities` once for each case. `overlay` stores nothing and passes the entities to every request in the `entities` argument. Overlay runs only cases whose entity JSON is at most 1 KB. |
| `--features` | a comma-separated list of `decimal`, `ipaddr`, `datetime`, `duration` and `template`, or `all` | The gated features that a case may use. A case that needs another gated feature is left out. A left-out case is not a skip. |
| `--check-est` | (flag) | For `--format text` only. Each policy also gets one assertion: the `est` that `cedar_policies()` returns after the text put equals the CLI's translation. It checks the text put end to end, for the policies of the selected cases. |
| `--parse-est` | (flag) | For `--format text` only, and it replaces the requests. Each text policy of every case, whatever its features, gets one assertion: `_cedar_parse_policy` on its text equals the CLI's translation. Each case with several policies also gets one assertion for the policy set (`_cedar_parse_policies` on the joined text, with the CLI's ids `policy0`, `policy1`, ...). This is the parser oracle of phase 3: 5,708 policies and 5 sets. It calls the parser directly because the extension types cannot be put before phases 4a and 4b. |
| `--templatize` | (flag) | For `--format json` only. Derives template tests from static policies, and runs only the cases that get a link. See the next table. |
| `--reduce-parents` | (flag) | For `--mode stored` only. Keeps only each entity's direct parents (the transitive reduction). Cedar's entity JSON lists every ancestor, so without this flag a broken walk up the hierarchy would still pass. Runs only the cases that lose a parent link. |

| Phase | Format | Gated features allowed | Also | Cases | Requests |
| --- | --- | --- | --- | --- | --- |
| `2` | json | none | | 3,360 | 26,793 |
| `3` | text | none | `--check-est` | 3,359 | 26,791 |
| `4a` | json | decimal, ipaddr | | 4,442 | 35,422 |
| `4b` | json | datetime, duration | | 4,231 | 33,761 |
| `4c` | json | template | `--templatize` | 1,273 | 10,111 |
| `all` | json | all | | 5,701 | 45,494 |

The corpus has no templates. For phase 4c, `--templatize` derives template tests from the corpus. Each static policy whose principal or resource scope names an entity (`==`, `in`, or `is ... in`) becomes a template with a slot in that place (`<id>_template`). A link fills the slot with the same entity under the original policy id. The answers, reasons and errors are the same, so the expectations still hold. This gives 1,276 links in the 1,273 phase 4c cases. The other cases would only repeat the phase 2 run, so `--templatize` leaves them out (`no-entity-in-scope`). Slot-specific errors, such as a link that fills the wrong slot, still need in-house specs. A phase can combine options, for example `--phase all --format text`, or `--features decimal,ipaddr,datetime,duration` once 4a and 4b are both done.

Spec file prefixes: `70_cedar_oracle` (json, stored), `71_cedar_oracle_text` (text, stored), `72_cedar_oracle_overlay` (json, overlay), `73_cedar_oracle_text_overlay` (text, overlay), `74_cedar_oracle_reduced` (json, stored, `--reduce-parents`) `75_cedar_oracle_text_reduced` (text, stored, `--reduce-parents`), `76_cedar_oracle_templates` (json, stored, `--templatize`) and `77_cedar_oracle_parse` (`--parse-est`). The assertion labels start with the mode: `stored:`, `overlay:`, `reduced:`, `templates:` or `parse:`. Each file has at most 1,000 assertions and 1.5 MB. A case is never split across files. The output is deterministic.

### What one generated case does

```sql
-- corpus/000c6ad2c16b5435b6d2c54803153cedfdd4eea7
select cedar_test.reset();
select permissions.cedar_put_policy(policy_id => 'policy0', policy_json => '{...}'::jsonb);
select permissions.cedar_put_entities(entities => '[...]'::jsonb);
select tap.is(
  cedar_test.authz('r::r::r::r::r::""', 'r::r::r::r::Action::"action"', 'r::r::r::r::r::""', '{}'::jsonb, null),
  '{"decision":"allow","errors":[],"reasons":["policy0"]}'::jsonb,
  'stored:json:corpus/000c6ad2c16b5435b6d2c54803153cedfdd4eea7:r0');
```

- UIDs are Cedar text, `Type::"id"`. The id uses Cedar string escapes: `\"`, `\\`, and `\u{..}` for control characters.
- `cedar_test.authz` reduces the result of `cedar_is_authorized` to three parts. The `decision` is lowercase. The `reasons` are a sorted set of policy ids. The `errors` are a sorted set of the `policy_id` values of the errors. Error messages are not compared, because Cedar's own harness compares only policy ids (`ErrorComparisonMode::PolicyIds`).
- If `cedar_is_authorized` raises an exception, the assertion fails and shows the SQLSTATE and the message. The rest of the file still runs.
- Policy ids are those of the upstream policy set. Cedar names the policies of a text file `policy0`, `policy1`, and so on, in source order. `convert.py` splits the text at top-level `;` characters. A check against the CLI confirmed that every split policy parses back to the same EST.

### Data transformations (the expectations never change)

- **Schema-based parsing.** Cedar's harness parses entities and context with the test's schema. The schema adds the action entities and accepts implicit forms: an extension value without `__extn`, or an entity reference without `__entity`. The extension never reads a schema. Instead, `convert.py` adds the action entities and writes the explicit forms, and each case records what changed in `schemaDependent`. All 24 handwritten tests need the action entities, and 10 of them also need explicit entity references. No corpus test depends on the schema.
- **U+0000.** Postgres `text` and `jsonb` cannot hold U+0000. 2,137 cases use it in ids, attribute names, record keys or strings. The generator replaces it with U+E000 in every string of the case, including the `\0`, `\x00` and `\u{0}` escapes in Cedar text. Cedar has no string length or string ordering, so `==`, `like`, `has` and record keys give the same results. A check against the CLI confirmed that the rewritten text parses to the rewritten EST. A case that already contains U+E000 would be skipped as `nul-collision`. No case in this release does.

## Moving to a new Cedar release

1. Update `SHA`, `CEDAR_VERSION`, `TARBALL_SHA256` and, if the minimum Rust version changed, `RUST_IMAGE` in `vendor.sh`.
2. Run `test/cedar/vendor.sh`. It takes about 5 minutes with a fresh CLI build. Set `CEDAR_CLI_DIR` to reuse a built Linux binary.
3. Run `--stats`, regenerate the suite files, and run the suite. Add each new divergence to `skip.tsv` with a reason, and record it in `e-cedar.md`.
