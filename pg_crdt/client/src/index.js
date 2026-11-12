// pg-crdt-client: a JavaScript client for pg_crdt collaborative text (ydoc_).
// No dependencies, no build step. Docs: ../../docs/reference/client.md.
export { openYdoc, YdocClient, YdocRejectedError, isRejection } from './client.js';
export { codePointIndex, utf16Index } from './utf16.js';
