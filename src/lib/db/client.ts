// =====================================================================
// lib/db — server-only Neon PostgreSQL access layer  (Phase 1)
// =====================================================================
// Centralizes ALL database access (task §12). The browser never imports this
// module; the DB connection string stays server-side (task §13). RLS is the
// security boundary — this layer sets the server-validated identity per
// transaction via app.set_user() so the 261 policies apply (task D1/D2).
//
// Driver choice (D5): `pg` Pool against the pooled Neon endpoint
// (DATABASE_URL_POOLED). RLS needs a session (SET LOCAL ROLE + app.set_user
// within one tx), so we use a pooled client checked out per unit of work.
//
// CONNECTION ROLE: the app connects as a NON-superuser, NON-BYPASSRLS login
// role (Neon project role granted anon/authenticated/service_role). Per
// request we SET LOCAL ROLE authenticated (or anon/service_role) so RLS
// policies apply against the identity we set. A forged request never calls
// withUser → identity stays anon/null → RLS denies.
import 'server-only';
import { Pool, type PoolClient, type QueryResult, type QueryResultRow } from 'pg';

declare global {
  // reuse the pool across hot reloads / serverless invocations
  // eslint-disable-next-line no-var
  var __diocesePgPool: Pool | undefined;
}

function connectionString(): string {
  const url = process.env.DATABASE_URL_POOLED || process.env.DATABASE_URL || '';
  if (!url) {
    throw new Error(
      'DATABASE_URL(_POOLED) is not set. Configure the Neon connection string ' +
        'as a server-side env var (never expose it to the client).'
    );
  }
  return url;
}

export function getPool(): Pool {
  if (!global.__diocesePgPool) {
    global.__diocesePgPool = new Pool({
      connectionString: connectionString(),
      max: Number(process.env.PGPOOL_MAX ?? 10),
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
      allowExitOnIdle: true,
    });
    global.__diocesePgPool.on('error', (err) => {
      console.error('[lib/db] idle pg client error:', err.message);
    });
  }
  return global.__diocesePgPool;
}

export type SqlParam = unknown;

/**
 * Low-level one-shot query WITHOUT identity. Use only for truly public reads
 * or inside withUser/withService. Prefer withUser()/rpc() for RLS-protected.
 */
export async function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params: SqlParam[] = []
): Promise<QueryResult<T>> {
  return getPool().query<T>(text, params as unknown[]);
}

export type DbRole = 'authenticated' | 'anon' | 'service_role';

export interface DbSession {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    params?: SqlParam[]
  ): Promise<QueryResult<T>>;
  /** call a Postgres function: rpc('account_login', { p_code, p_password }) */
  rpc<T = unknown>(fn: string, args?: Record<string, SqlParam>): Promise<T>;
}

/**
 * Run `cb` inside a transaction with the identity set for RLS — the single
 * trusted entry point that converts a server-validated session into a DB
 * identity:
 *   BEGIN; SET LOCAL ROLE <role>; SELECT app.set_user(<uid>, <role>); … ; COMMIT
 * On error it rolls back. Identity is LOCAL to the tx; it never leaks to
 * another pooled checkout.
 */
export async function withUser<T>(
  uid: string | null,
  cb: (db: DbSession) => Promise<T>,
  opts: { role?: DbRole } = {}
): Promise<T> {
  const role: DbRole = opts.role ?? (uid ? 'authenticated' : 'anon');
  const client: PoolClient = await getPool().connect();
  try {
    await client.query('begin');
    // Set identity FIRST, while still the privileged app connection role that
    // may execute app.set_user (it is revoked from authenticated/anon). The GUC
    // written by set_config(..., true) is transaction-local and survives the
    // subsequent SET LOCAL ROLE.
    await client.query('select app.set_user($1::uuid, $2)', [uid, role]);
    // THEN drop to the RLS role so policies `to authenticated`/`to anon` apply.
    // SET LOCAL ROLE cannot be parameterized → role is a fixed allowlist value.
    await client.query(`set local role ${role}`);

    const session: DbSession = {
      query: (text, params = []) => client.query(text, params as unknown[]),
      rpc: async <R = unknown>(fn: string, args: Record<string, SqlParam> = {}) => {
        const keys = Object.keys(args);
        const placeholders = keys.map((k, i) => `${k} => $${i + 1}`).join(', ');
        const values = keys.map((k) => args[k]);
        const sql = `select public.${sanitizeIdent(fn)}(${placeholders}) as result`;
        const r = await client.query(sql, values as unknown[]);
        return (r.rows[0]?.result ?? null) as R;
      },
    };

    const out = await cb(session);
    await client.query('commit');
    return out;
  } catch (e) {
    try { await client.query('rollback'); } catch { /* ignore */ }
    throw e;
  } finally {
    try { await client.query('reset role'); } catch { /* ignore */ }
    client.release();
  }
}

/**
 * Run `cb` with the service_role (admin) — for server-only operations that
 * legitimately bypass per-user scoping (servant creation, backup, push
 * dispatch, account mint). Replaces the old SUPABASE_SERVICE_ROLE_KEY client,
 * still inside our DB with no external auth server.
 */
export async function withService<T>(cb: (db: DbSession) => Promise<T>): Promise<T> {
  return withUser(null, cb, { role: 'service_role' });
}

const IDENT_RE = /^[a-z_][a-z0-9_]*$/i;
function sanitizeIdent(name: string): string {
  if (!IDENT_RE.test(name)) throw new Error(`invalid function name: ${name}`);
  return name;
}
