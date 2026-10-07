// =====================================================================
// lib/db/neon-client — browser client shim (Phase 1)
// =====================================================================
// A drop-in for the Supabase browser client's data API. It implements the
// chainable query-builder subset the app uses and the .rpc() call, but instead
// of talking to Postgres it POSTs to /api/db, where the server resolves
// identity and runs under RLS. This lets the ~155 existing `.from()/.rpc()`
// call sites keep their code while the data flows through Neon.
//
// Returns the same `{ data, error }` shape Supabase returns, so call sites that
// destructure `{ data, error }` keep working. Realtime (.channel) is a no-op
// stub here (D4 — refetch-on-focus fallback); it is provided so imports don't
// break and is replaced by the realtime fallback module in Phase 7.
'use client';

import type { QuerySpec, Filter, OrderSpec, FilterOp } from './pgrest';

type Json = Record<string, unknown>;
interface GatewayResult { data: unknown; count: number | null; error: string | null; }

async function callGateway(op: Json, portal?: { kind: 'child' | 'priest'; token: string } | null): Promise<GatewayResult> {
  const res = await fetch('/api/db', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ops: [op], portal: portal ?? undefined }),
  });
  const body = (await res.json().catch(() => ({}))) as { results?: GatewayResult[]; error?: string };
  if (!res.ok || !body.results) return { data: null, count: null, error: body.error ?? `http_${res.status}` };
  return body.results[0];
}

type PortalRef = { kind: 'child' | 'priest'; token: string } | null;

class QueryBuilder implements PromiseLike<{ data: unknown; error: { message: string } | null; count: number | null }> {
  private spec: QuerySpec;
  private portal: PortalRef;
  constructor(table: string, portal: PortalRef) {
    this.spec = { table, action: 'select', filters: [], order: [] };
    this.portal = portal;
  }
  select(columns = '*', opts?: { count?: 'exact' }) {
    if (this.spec.action === 'select') { this.spec.columns = columns; if (opts?.count === 'exact') this.spec.count = true; }
    else this.spec.returning = columns; // insert/update/delete .select()
    return this;
  }
  insert(values: Json | Json[]) { this.spec.action = 'insert'; this.spec.values = values; return this; }
  upsert(values: Json | Json[], opts?: { onConflict?: string }) { this.spec.action = 'upsert'; this.spec.values = values; if (opts?.onConflict) this.spec.onConflict = opts.onConflict; return this; }
  update(values: Json) { this.spec.action = 'update'; this.spec.values = values; return this; }
  delete() { this.spec.action = 'delete'; return this; }

  private addFilter(col: string, op: FilterOp, value: unknown) { (this.spec.filters ??= []).push({ col, op, value } as Filter); return this; }
  eq(c: string, v: unknown) { return this.addFilter(c, 'eq', v); }
  neq(c: string, v: unknown) { return this.addFilter(c, 'neq', v); }
  gt(c: string, v: unknown) { return this.addFilter(c, 'gt', v); }
  gte(c: string, v: unknown) { return this.addFilter(c, 'gte', v); }
  lt(c: string, v: unknown) { return this.addFilter(c, 'lt', v); }
  lte(c: string, v: unknown) { return this.addFilter(c, 'lte', v); }
  like(c: string, v: unknown) { return this.addFilter(c, 'like', v); }
  ilike(c: string, v: unknown) { return this.addFilter(c, 'ilike', v); }
  is(c: string, v: unknown) { return this.addFilter(c, 'is', v); }
  in(c: string, v: unknown[]) { return this.addFilter(c, 'in', v); }
  match(obj: Json) { for (const k of Object.keys(obj)) this.addFilter(k, 'eq', obj[k]); return this; }
  order(col: string, opts?: { ascending?: boolean; nullsFirst?: boolean }) {
    (this.spec.order ??= []).push({ col, ascending: opts?.ascending ?? true, nullsFirst: opts?.nullsFirst } as OrderSpec); return this;
  }
  limit(n: number) { this.spec.limit = n; return this; }
  range(from: number, to: number) { this.spec.offset = from; this.spec.rangeTo = to; return this; }
  single() { this.spec.single = true; return this; }
  maybeSingle() { this.spec.maybeSingle = true; return this; }

  private async run() {
    const r = await callGateway({ type: 'query', spec: this.spec }, this.portal);
    return { data: r.data, error: r.error ? { message: r.error } : null, count: r.count };
  }
  then<TResult1 = { data: unknown; error: { message: string } | null; count: number | null }, TResult2 = never>(
    onfulfilled?: ((value: { data: unknown; error: { message: string } | null; count: number | null }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null
  ): PromiseLike<TResult1 | TResult2> {
    return this.run().then(onfulfilled, onrejected);
  }
}

// no-op realtime channel (D4 — replaced by the refetch-on-focus fallback)
function noopChannel() {
  const ch = {
    on() { return ch; },
    subscribe() { return ch; },
    unsubscribe() { return Promise.resolve('ok'); },
  };
  return ch;
}

export interface NeonClient {
  from(table: string): QueryBuilder;
  rpc<T = unknown>(fn: string, args?: Json): Promise<{ data: T | null; error: { message: string } | null }>;
  channel(name: string): ReturnType<typeof noopChannel>;
  removeChannel(): Promise<string>;
}

/**
 * Create a Neon-backed client with the Supabase data-API surface.
 * `portal` identifies a child/priest session (token) when used from those
 * portals; the servant app passes null and relies on the HttpOnly cookie.
 */
export function createNeonClient(portal: PortalRef = null): NeonClient {
  return {
    from: (table: string) => new QueryBuilder(table, portal),
    rpc: async <T = unknown>(fn: string, args: Json = {}) => {
      const r = await callGateway({ type: 'rpc', fn, args }, portal);
      return { data: (r.data as T) ?? null, error: r.error ? { message: r.error } : null };
    },
    channel: () => noopChannel(),
    removeChannel: () => Promise.resolve('ok'),
  };
}
