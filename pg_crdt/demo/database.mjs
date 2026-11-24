// A provider CA can be supplied as PEM text (or with escaped newlines) in a
// server-only environment variable, so deployment needs no local cert paths.
export function databaseOptions(env) {
  if (!env.CRDT_DEMO_DATABASE_CA) return { connectionString: env.CRDT_DEMO_DATABASE_URL };
  const url = new URL(env.CRDT_DEMO_DATABASE_URL);
  // node-postgres replaces the ssl object when these URL options are present.
  // The explicit CA configuration always verifies both chain and hostname.
  for (const key of ['ssl', 'sslmode', 'sslrootcert', 'sslcert', 'sslkey']) url.searchParams.delete(key);
  return {
    connectionString: url.toString(),
    ssl: { ca: env.CRDT_DEMO_DATABASE_CA.replace(/\\n/g, '\n'), rejectUnauthorized: true },
  };
}
