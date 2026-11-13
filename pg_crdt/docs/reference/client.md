# JavaScript client moved to research

The former `pg-crdt-client` targets the table-backed `ydoc_` API and now lives in the [research snapshot](../../research/ydoc/README.md). It is not a supported client for the active text-column API.

For current applications, use a Postgres driver directly for counters and [form saves](../text/forms.md). A live text editor needs an adapter implementing the column operation format and sync behavior. See [Connect a live editor](../text/live-editor.md) for that contract and its limitations.

The [scope decision](../../research/scope.md) explains why table-backed documents and their client remain separate.

<span id="starlight__on-this-page"></span>

<span id="open-a-document"></span>

<span id="write-a-transport"></span>

<span id="node-postgres"></span>

<span id="a-browser"></span>

<span id="edit"></span>

<span id="show-remote-changes"></span>

<span id="sync"></span>

<span id="refused-ops"></span>

<span id="api"></span>

<span id="limits"></span>

<span id="how-it-is-tested"></span>
