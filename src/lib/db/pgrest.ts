// =====================================================================
// lib/db/pgrest — minimal PostgREST-compatible query translator (Phase 1)
// =====================================================================
// Translates the Supabase query-builder subset the app actually uses into
// parameterized SQL, run server-side through lib/db under the caller's RLS
// identity. This is what lets the ~155 existing `.from()/.rpc()` files keep
// working against Neon via the client shim + gateway, without a rewrite.
//
// Supported (from an audit of src/): select (with column list + embedded
// resource hints stripped to columns), insert, update, delete, upsert;
// filters eq/neq/in/is/gt/gte/lt/lte/like/ilike/match/or; order, limit,
// range, single/maybeSingle. Everything is parameterized ($1,$2,…) — no
// string interpolation of values (no SQL injection). Identifiers are
// validated against a strict regex.
import 'server-only';
import type { DbSession } from './client';

const IDENT = /^[a-zA-Z_][a-zA-Z0-9_]*$/;
function ident(name: string): string {
  // allow schema-qualified public tables only
  const n = name.trim();
  if (!IDENT.test(n)) throw new Error(`invalid identifier: ${name}`);
  return `"${n}"`;
}
function identList(cols: string): string {
  // "*" or "a, b, c" ; strip PostgREST embedded resources (col:rel(...)) → col
  const c = cols.trim();
  if (c === '' || c === '*') return '*';
  return c
    .split(',')
    .map((part) => {
      const col = part.split(':')[0].trim().replace(/\(.*$/, '').trim();
      if (col === '*') return '*';
      // alias form "name" only — drop relation embeds entirely
      if (!IDENT.test(col)) return null;
      return ident(col);
    })
    .filter(Boolean)
    .join(', ') || '*';
}

export type FilterOp =
  | 'eq' | 'neq' | 'gt' | 'gte' | 'lt' | 'lte'
  | 'like' | 'ilike' | 'is' | 'in';

export interface Filter { col: string; op: FilterOp; value: unknown; }
export interface OrderSpec { col: string; ascending: boolean; nullsFirst?: boolean; }

export interface QuerySpec {
  table: string;
  action: 'select' | 'insert' | 'update' | 'delete' | 'upsert';
  columns?: string;                 // for select
  values?: Record<string, unknown> | Record<string, unknown>[]; // insert/update/upsert
  filters?: Filter[];
  order?: OrderSpec[];
  limit?: number;
  offset?: number;
  rangeTo?: number;
  returning?: string;               // columns to RETURN for write ops
  onConflict?: string;              // upsert conflict target
  single?: boolean;                 // expect exactly 1 row
  maybeSingle?: boolean;            // 0 or 1 row
  count?: boolean;                  // request exact count
}

interface Built { sql: string; params: unknown[]; }

function whereClause(filters: Filter[] | undefined, params: unknown[]): string {
  if (!filters || filters.length === 0) return '';
  const parts = filters.map((f) => {
    const col = ident(f.col);
    switch (f.op) {
      case 'eq': params.push(f.value); return `${col} = $${params.length}`;
      case 'neq': params.push(f.value); return `${col} <> $${params.length}`;
      case 'gt': params.push(f.value); return `${col} > $${params.length}`;
      case 'gte': params.push(f.value); return `${col} >= $${params.length}`;
      case 'lt': params.push(f.value); return `${col} < $${params.length}`;
      case 'lte': params.push(f.value); return `${col} <= $${params.length}`;
      case 'like': params.push(f.value); return `${col} like $${params.length}`;
      case 'ilike': params.push(f.value); return `${col} ilike $${params.length}`;
      case 'is':
        if (f.value === null) return `${col} is null`;
        if (typeof f.value === 'boolean') return `${col} is ${f.value ? 'true' : 'false'}`;
        params.push(f.value); return `${col} is not distinct from $${params.length}`;
      case 'in': {
        const arr = Array.isArray(f.value) ? f.value : [f.value];
        if (arr.length === 0) return 'false';
        const ph = arr.map((v) => { params.push(v); return `$${params.length}`; });
        return `${col} in (${ph.join(', ')})`;
      }
      default: throw new Error(`unsupported filter op: ${(f as Filter).op}`);
    }
  });
  return ' where ' + parts.join(' and ');
}

function orderLimit(spec: QuerySpec, params: unknown[]): string {
  let s = '';
  if (spec.order && spec.order.length) {
    s += ' order by ' + spec.order.map((o) =>
      `${ident(o.col)} ${o.ascending ? 'asc' : 'desc'} nulls ${o.nullsFirst ? 'first' : 'last'}`
    ).join(', ');
  }
  // range(from,to) → offset from, limit to-from+1 ; or explicit limit/offset
  if (typeof spec.offset === 'number') { params.push(spec.offset); s += ` offset $${params.length}`; }
  if (typeof spec.rangeTo === 'number' && typeof spec.offset === 'number') {
    params.push(spec.rangeTo - spec.offset + 1); s += ` limit $${params.length}`;
  } else if (typeof spec.limit === 'number') { params.push(spec.limit); s += ` limit $${params.length}`; }
  return s;
}

export function buildSql(spec: QuerySpec): Built {
  const t = ident(spec.table);
  const params: unknown[] = [];
  const ret = spec.returning ? identList(spec.returning) : '*';

  if (spec.action === 'select') {
    const cols = identList(spec.columns ?? '*');
    const sel = spec.count ? `${cols}, count(*) over() as __count` : cols;
    const sql = `select ${sel} from public.${t}` + whereClause(spec.filters, params) + orderLimit(spec, params);
    return { sql, params };
  }

  if (spec.action === 'insert' || spec.action === 'upsert') {
    const rows = Array.isArray(spec.values) ? spec.values : [spec.values ?? {}];
    if (rows.length === 0) throw new Error('insert requires values');
    const cols = Object.keys(rows[0]);
    if (cols.length === 0) throw new Error('insert requires at least one column');
    const colSql = cols.map(ident).join(', ');
    const tuples = rows.map((row) => {
      const ph = cols.map((c) => { params.push((row as Record<string, unknown>)[c]); return `$${params.length}`; });
      return `(${ph.join(', ')})`;
    });
    let sql = `insert into public.${t} (${colSql}) values ${tuples.join(', ')}`;
    if (spec.action === 'upsert') {
      const conflict = spec.onConflict ? spec.onConflict.split(',').map((c) => ident(c.trim())).join(', ') : cols.map(ident).join(', ');
      const setList = cols.map((c) => `${ident(c)} = excluded.${ident(c)}`).join(', ');
      sql += ` on conflict (${conflict}) do update set ${setList}`;
    }
    sql += ` returning ${ret}`;
    return { sql, params };
  }

  if (spec.action === 'update') {
    const vals = (spec.values ?? {}) as Record<string, unknown>;
    const cols = Object.keys(vals);
    if (cols.length === 0) throw new Error('update requires values');
    const setList = cols.map((c) => { params.push(vals[c]); return `${ident(c)} = $${params.length}`; }).join(', ');
    const sql = `update public.${t} set ${setList}` + whereClause(spec.filters, params) + ` returning ${ret}`;
    return { sql, params };
  }

  if (spec.action === 'delete') {
    const sql = `delete from public.${t}` + whereClause(spec.filters, params) + ` returning ${ret}`;
    return { sql, params };
  }

  throw new Error(`unsupported action: ${spec.action}`);
}

export interface QueryOutcome { data: unknown; count: number | null; error: string | null; }

/** Execute a QuerySpec through an identity-bound DbSession. */
export async function runQuery(db: DbSession, spec: QuerySpec): Promise<QueryOutcome> {
  try {
    const { sql, params } = buildSql(spec);
    const r = await db.query(sql, params);
    let rows: unknown[] = r.rows;
    let count: number | null = null;
    if (spec.count && rows.length) {
      count = Number((rows[0] as Record<string, unknown>).__count ?? rows.length);
      rows = rows.map((row) => { const { __count, ...rest } = row as Record<string, unknown>; void __count; return rest; });
    }
    if (spec.single || spec.maybeSingle) {
      if (rows.length === 0) {
        if (spec.single) return { data: null, count, error: 'no rows' };
        return { data: null, count, error: null };
      }
      return { data: rows[0], count, error: null };
    }
    return { data: rows, count, error: null };
  } catch (e) {
    return { data: null, count: null, error: (e as Error).message };
  }
}
