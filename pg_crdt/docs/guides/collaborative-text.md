# Build with collaborative text

Store shared plain text in a `crdt.yseq` column. The active extension keeps all state in your table; the table-backed document API is [separate research](../../research/scope.md).

The column is experimental. Every edit rewrites the full state, deleted-character metadata remains, and sync scans the document. Read [Text-column limits and performance](../text/limits.md) before choosing it for large or frequently edited documents.

| Task | Guide |
| --- | --- |
| Try a small SQL example | [Your first shared document](../get-started/text.md) |
| Set up a sample application and permissions | [Control document access](../text/access.md) |
| Save a whole form while preserving other edits | [Save changes from a form](../text/forms.md) |
| Implement an editor adapter and sync | [Connect a live editor](../text/live-editor.md) |
| Add full-text search | [Search documents](../text/search.md) |
| Understand merge behavior and operations | [How text merges](../types/collaborative-text.md) |
| Plan capacity | [Text-column limits and performance](../text/limits.md) |

## Earlier guide links

The former two-part blog tutorial has been split by task. Its table-backed implementation and JavaScript client are archived for research; they are not installed by pg_crdt.

<span id="starlight__on-this-page"></span>

<span id="part-1-the-body-in-a-column-yseq_"></span>

<span id="set-up-the-roles"></span>

<span id="create-the-articles-table"></span>

<span id="write-the-article-wrappers"></span>

<span id="create-and-save-an-article"></span>

<span id="send-ops-from-an-editor"></span>

<span id="search-the-articles"></span>

<span id="delete-an-article-back-up-uninstall"></span>

<span id="checklist-for-the-column"></span>

<span id="part-2-the-body-in-tables-ydoc_"></span>

<span id="set-up-the-roles-and-grants"></span>

<span id="create-the-posts-table"></span>

<span id="write-the-wrappers"></span>

<span id="create-a-post"></span>

<span id="create-a-document-with-a-client-chosen-id"></span>

<span id="save-from-a-form"></span>

<span id="stream-edits-from-an-editor"></span>

<span id="search-the-posts"></span>

<span id="compact-on-a-schedule"></span>

<span id="delete-a-post"></span>

<span id="backups-and-uninstalling"></span>

<span id="checklist-for-the-tables"></span>

<span id="next"></span>
