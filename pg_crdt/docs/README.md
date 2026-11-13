# pg_crdt documentation

Choose the feature you want to build. Both keep their state in your own Postgres tables; the text column is experimental and has significant storage and sync limits.

| Journey | First steps | Build your application |
| --- | --- | --- |
| Counters | [Install](install.md), then [your first counter](get-started/quickstart.md) | [Sync counts](guides/sync-counts.md), [identify writers](guides/replicas-and-identity.md), [accept client updates](guides/security.md), [store and query large counters](guides/storage-and-performance.md) |
| Collaborative text | [Read the limitations](text/limits.md), [install](install.md), then [your first shared document](get-started/text.md) | [Save forms](text/forms.md), [control access](text/access.md), [connect a live editor](text/live-editor.md), [search](text/search.md) |

## Operate and troubleshoot

[Back up and restore](operations/backups.md), [maintain storage](operations/maintenance.md), [handle transaction retries](guides/safe-updates.md), [troubleshoot symptoms](operations/troubleshooting.md), or [uninstall](operations/uninstall.md).

## Understand or look up behavior

- Explanations: [How counters merge](types/pn-counter.md), [How text merges](types/collaborative-text.md).
- Reference: [Counter functions](reference/pn.md), [text column functions](reference/yseq.md), [identity settings](reference/shared.md), [errors](reference/errors.md), [limits](reference/limits.md).
- Project: [Changelog](../CHANGELOG.md), [tests](../test/README.md), [writing conventions](../STYLE.md), [research](../research/README.md).

## Example conventions

Run a page's examples in order unless it says otherwise. Each task states its setup. SQL runs in psql; JavaScript uses a connected node-postgres `client`, as shown in the [counter quickstart](get-started/quickstart.md#before-you-start). On the website, language tabs show alternatives; GitHub and Markdown exports show both.

Sample role names are placeholders for your own roles. Statements marked with an `-- ERROR:` comment intentionally fail. API reference examples include their own small setup and can be read independently.

## Earlier table-backed documents

The `ydoc_` implementation and its JavaScript client are [archived research](../research/ydoc/README.md). They are not part of the current extension. Read the [scope decision](../research/scope.md) before changing an existing installation.
