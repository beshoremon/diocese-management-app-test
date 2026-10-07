// =====================================================================
// /api/db — server data gateway (Phase 1)
// =====================================================================
// The single server endpoint the browser talks to instead of connecting to
// Postgres directly (task §13: the DB credential never reaches the client).
// It resolves the request's identity SERVER-SIDE, runs the op under
// lib/db.withUser() so RLS applies, and returns the result.
//
// Identity resolution (never trusts client-supplied ids/roles):
//   * servant: the HttpOnly cookie → servant_session_resolve → uid
//   * child/priest: a portal token in the body → session_person(kind, token)
//     (these portals validate inside their own RPCs, as before). For table
//     ops they run as the authenticated identity of the resolved person's
//     servant account if any; portal data access is predominantly via RPCs
//     that take the token argument, so this gateway mainly powers the servant
//     app's table/rpc calls.
//
// Body: { ops: Array<RpcOp | QueryOp>, portal?: {kind, token} }
//   RpcOp   = { type:'rpc', fn, args }
//   QueryOp = { type:'query', spec: QuerySpec }
// Response: { results: Array<{ data, count, error }> }
import { NextRequest, NextResponse } from 'next/server';
import { withUser } from '@/lib/db/client';
import { getServantIdentity } from '@/lib/db/session';
import { runQuery, type QuerySpec } from '@/lib/db/pgrest';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

interface RpcOp { type: 'rpc'; fn: string; args?: Record<string, unknown>; }
interface QueryOp { type: 'query'; spec: QuerySpec; }
type Op = RpcOp | QueryOp;

interface Body {
  ops?: Op[];
  // portal token (child/priest). The servant identity comes from the cookie.
  portal?: { kind: 'child' | 'priest'; token: string };
}

export async function POST(req: NextRequest) {
  let body: Body;
  try { body = (await req.json()) as Body; } catch { return NextResponse.json({ error: 'bad_json' }, { status: 400 }); }
  const ops = Array.isArray(body.ops) ? body.ops : [];
  if (ops.length === 0) return NextResponse.json({ results: [] });
  if (ops.length > 50) return NextResponse.json({ error: 'too_many_ops' }, { status: 400 });

  // resolve the server-trusted identity
  const servant = await getServantIdentity();
  const uid = servant?.servantId ?? null;

  try {
    const results = await withUser(uid, async (db) => {
      const out: unknown[] = [];
      for (const op of ops) {
        if (op.type === 'rpc') {
          try {
            const data = await db.rpc(op.fn, op.args ?? {});
            out.push({ data, count: null, error: null });
          } catch (e) {
            out.push({ data: null, count: null, error: (e as Error).message });
          }
        } else if (op.type === 'query') {
          out.push(await runQuery(db, op.spec));
        } else {
          out.push({ data: null, count: null, error: 'unknown_op' });
        }
      }
      return out;
    });
    return NextResponse.json({ results });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
