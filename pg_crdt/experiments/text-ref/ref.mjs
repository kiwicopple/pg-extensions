// Reference YjsMod sequence CRDT for pg_crdt text experiments.
//
// The code moved to ../../client/src/doc.js in session 8, so that the client library
// and the reference that the extension is tested against are one implementation.
// This file re-exports it: the experiments, fixtures and trace converter import
// './ref.mjs' as before. API and validation rules: README.md.
export * from '../../client/src/doc.js';
