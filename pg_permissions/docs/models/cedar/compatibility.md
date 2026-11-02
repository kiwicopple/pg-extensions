# Cedar compatibility

The extension targets Cedar 4.14 and checks its behavior against Cedar's integration tests. It runs inside Postgres, so storage, errors and some limits differ from the Cedar libraries. Schema validation and partial evaluation are outside its scope.

## The tested release

| Item | Value |
| --- | --- |
| Cedar release | 4.14.0 |
| Test suite | [cedar-integration-tests](https://github.com/cedar-policy/cedar-integration-tests) at commit `b157547fb8856911b293b7214768922c731878de`, tag `v4.14.0` |
| Corpus archive | `corpus-tests.tar.gz`, SHA-256 `67a3698263d2a4530464b88c3094e5930570862c7123362bd7e848b305ad20ec` |
| Corpus source | cedar `bcb8bd93a292b59ae8f1dcf53b9b4176a2d3405d` and cedar-spec `4748ff0980c4b5a14daaf5b9e74035a234c186b5` |
| Policy translation | `cedar-policy-cli` 4.14.0 |
| License | Apache-2.0. Copyright Cedar Contributors. |

The suite has 5,701 tests and 45,494 requests. A test has policies, entities and requests, and each request has an expected decision, reasons and errors. The test files are in [`test/cedar/`](../../../test/cedar/README.md). The extension reads policies from Cedar text and from Cedar JSON, so the suite runs in both forms.

## Pass rates

The recorded runs pass all requests selected for each mode below. The JSON run covers the full corpus; the other modes exercise subsets or transformed cases. The harness substitutes U+E000 for U+0000 because Postgres cannot store U+0000. These results establish compatibility with the tested corpus, rather than every possible policy.

| Run | Requests | Result |
| --- | --- | --- |
| Policies as JSON, entities stored | 45,494 (the whole corpus) | All pass |
| Policies as JSON, entities in the request (overlay) | 31,872 | All pass |
| Policies as JSON, entities with direct parents only | 11,976 | All pass |
| Policies as Cedar text, entities stored | 45,492, and the JSON of 5,708 stored policies | All pass |
| The parser on every policy of the corpus | 5,708 policies and 5 policy sets | All pass. Each text gives exactly the JSON that the Cedar CLI gives. |
| Templates: each policy that names an entity in its scope, as a template and a link | 19,156 | All pass |

- The overlay run covers the tests whose entity JSON is at most 1 KB. The suite writes the entities in the `entities` argument of the request.
- The run with direct parents removes the parent links that Cedar's JSON lists for the closure. The extension computes the closure itself.
- The suite has no tests for templates. The extension generates them from the other tests. In-house tests cover the errors of templates, and the whole API.

The comparison covers the decision and the ids of the policies. It does not compare the text of error messages, as Cedar's own test harness does not.

## Differences from Cedar

| Difference | Reason |
| --- | --- |
| **U+0000.** A string cannot hold the character U+0000. The extension raises `cedar:unsupported`. | Postgres `text` and `jsonb` cannot hold it. In the test suite, the harness uses U+E000 instead. 2,137 tests contain U+0000, and Cedar has no string length or order, so the answers do not change. |
| **No schema.** The extension reads no Cedar schema. It does not validate a policy or a request, and it does not add the action entities of a schema. | Schema validation is out of scope (see below). |
| **Explicit forms in data.** Write `__extn` for an extension value and `__entity` for an entity reference. Cedar accepts a bare string with a schema. Store the action entities with `cedar_put_entities`. | There is no schema to say what a value is. |
| **Reserved keys.** A record with the only key `__entity` or `__extn` is read as an entity or an extension value. In a policy, such a record literal is `cedar:unsupported`. | Cedar's JSON has the same ambiguity. |
| **Long as `1e3`.** A JSON number such as `1e3` is accepted as the Long `1000`. Cedar rejects it. `1.0` is rejected, as in Cedar. | `jsonb` does not keep the text of a number. |
| **Cycles that only the request overlay makes** are not rejected. The test `in` still ends, and treats the entities of the cycle as ancestors of each other. | A check of every overlay would cost every request a walk. Stored entities are checked: a put that makes a cycle is an error. |
| **Two concurrent puts** can make a cycle that neither put sees. The test `in` still ends. Two concurrent puts can also give a static policy and a template the same id. | The extension takes no global lock. |
| **Fail-closed helpers.** `cedar_is_authorized_current` returns `false`, and `cedar_list_resources_current` leaves out a resource, when a `forbid` that applies gives an error. | The helpers feed access control. A skipped `forbid` must not allow access. `cedar_is_authorized` follows Cedar and reports the error. |
| **`resource_attrs` replaces.** The attributes that `cedar_is_authorized_current` gets in `resource_attrs` replace the stored attributes of the resource. They do not merge. The parents and the tags still come from the stored entity. | The call describes a row. A merge would let a stale stored attribute stay. |
| **The list is for stored entities.** `cedar_list_resources_current` returns stored entities only. A resource named in a policy but absent from storage is not listed. `cedar_is_authorized_current` can still allow it if the policies permit it. | The function finds candidates in the entity table. |
| **The `@id` rule.** The argument `policy_id` names a policy. An `@id` annotation stays an annotation. | The JSON format has no id field. A text and a JSON put name a policy in the same way. |
| **No policy-set loader.** No function takes a whole policy set. Put each policy with its own id. | A loader that names policies by position changes the ids when the file changes. |
| **Links replace.** `cedar_link_template` with the id of a link that exists replaces that link. Cedar's `link` rejects a duplicate id. | Every put in this API replaces by id. |
| **Principal type.** The principal of a check for the current subject is the subject type as it is, such as `user::"alice"`. The extension does not change it to `User`. | One name for a subject type in every model. See [the overview](overview.md#the-subject-is-the-principal). |
| **Canonical output.** `cedar_read_entities` writes an extension value in canonical text (`"1.5000"` for the decimal `1.5`). | One text for each value. The Cedar 4.14 CLI reads the output back to the same values. |
| **Bad extension values in data.** A value that Cedar cannot build raises `cedar:invalid_entity` or `cedar:invalid_context` at the put or at the request. | Cedar also rejects the entities or the context. |
| **Messages.** The text of an error message differs from Cedar's. The code at its start follows Cedar's evaluation errors. | Only the ids of the policies are compared. |
| **Limits.** A policy, an entity array and a value have size limits. See [Limits](../../reference/limits.md#cedar-limits). | The size of the work in PL/pgSQL. The limits are well above the corpus maximum. |

## Out of scope

- **Schema validation.** The extension does not check policies against a schema. A policy with a type error is stored, and gives an evaluation error when a request reaches it.
- **Partial evaluation.** A request cannot have unknown values. The extension also does not compile policies to SQL predicates.
- **Request context from clients in the RLS functions.** `cedar_is_authorized_current` has no `context`, because a client could write it. A server can pass any context to `cedar_is_authorized`.
- **Cedar tools.** The extension does not format or analyze policies. Use the Cedar CLI for this.

Cedar releases after 4.14 can add language features. The extension supports only the release in the table above.

## Related

- [The Cedar model](overview.md) describes the supported language.
- [Extension types](extensions.md) lists the points where Cedar's extension types behave in a way you might not expect.
- [The design record](../../../research/designs/e-cedar.md) has the measurements and the reasons for each decision.
