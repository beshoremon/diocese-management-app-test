# MIGRATION_PLAN.md
## إدارة الإيبارشية — Diocese Management PWA
### Supabase → Neon PostgreSQL · Recommended migration plan

> Companion to `SUPABASE_MIGRATION_AUDIT.md`. Target architecture:
> **Next.js → Vercel → Neon PostgreSQL**, minimum services. No destructive
> action against production at any point.

---

## 0. Confirmed decisions (D1–D5)

- **D1 — RLS:** APPROVED. Keep PostgreSQL RLS in Neon; do not remove/bypass the 409 policies. Replace only the identity mechanism, preserving exact authorization behavior.
- **D2 — Auth/Identity:** APPROVED. No new external auth provider. Extend the existing child/priest token/session mechanism to the server/servant layer. Create `app.uid()` as the PG identity function used by RLS instead of `auth.uid()`; make the change centralized. Security: no plaintext passwords; secrets never on client; HttpOnly cookies; server-side session validation; never trust client-supplied user_id/role/church_id/service_id/class_id; preserve "one person, one code, one password, many accounts" + account switching + all roles.
- **D3 — Storage:** Vercel Blob. **Not** migrated in Phase 1. `backups` must stay private. A storage abstraction keeps the UI off the Blob API directly.
- **D4 — Realtime:** No Pusher/Redis/Ably/WebSockets now. Use the refetch-on-focus fallback.
- **D5 — RPC:** Keep PG functions/RPCs in the database. Don't blindly convert ~250 functions to TypeScript. Move to app code only with a clear technical reason and equivalent behavior.

---

## 1. Identity architecture (how `auth.uid()` → `app.uid()` is realized)

- New `app` schema is the ONE identity authority: `app.uid()`, `app.role()`, `app.set_user(uuid, role)`, `app.clear_user()`.
- `app.uid()` = `current_setting('request.jwt.claim.sub')::uuid`; `app.set_user` does `SET LOCAL` of that GUC inside the request transaction, **after** the server validates the session.
- `auth.uid()` / `auth.role()` become **thin delegates** to `app.*`, so the 308 existing call sites and 261 policies need **zero edits** — the swap is centralized exactly as D2 requires.
- `auth.users` becomes a plain **owned** table (servant login accounts, bcrypt in `encrypted_password`); no Supabase Auth server.
- `servant_sessions` (mirror of `child_sessions`) gives servants the same opaque-token mechanism as child/priest; the server keeps the token in an HttpOnly cookie and resolves it per request to the `servant_enrollments.id` (= the value `auth.uid()` returned) → `app.set_user(...)`.
- Forged request → no valid token → `app.uid()` NULL → RLS denies. Client-supplied scope IDs are never trusted; RLS reads them back from the authenticated person's own rows via `my_church()/can_access()` etc.

---

## 2. Phase sequence (task §37 STEP 4→17)

Each phase: build green → commit → push to GitHub → backup → tests where relevant.

1. **Neon schema** (STEP 4) — `db/neon/00_identity.sql` + application migrations unchanged + `db/neon/20_servant_auth.sql`; verify object counts.
2. **DB access layer** (STEP 5) — `lib/db/` (Neon driver, `query`, `rpc`, `withUser` sets `app.set_user`), server-only.
3. **Query/RPC migration** (STEP 6) — server gateway + client shim so `.from()/.rpc()` run server-side; preserve pagination/indexes/aggregation; no `SELECT *`-then-filter, no N+1.
4. **Authentication** (STEP 7) — `servant_sessions` + HttpOnly cookie; rewrite `src/lib/supabase/*`, `middleware.ts`, `accounts.ts`, `/api/account/*`, `/api/servants/*`. Preserve account-switch UX.
5. **Authorization/RLS** (STEP 8) — `app.uid()` identity + server-side re-checks for scoped writes; document each rule OLD→NEW→TESTED.
6. **Storage** (STEP 9 — Phase 2, not now) — Vercel Blob + signed-upload Route Handler; `backups` private.
7. **Realtime** (STEP 10) — fallback/polling; keep `useDebouncedRealtime` API so ~75 sites don't change.
8. **Notifications/cron** (STEP 11) — Vercel Cron; point routes at new DB/auth. web-push unchanged.
9. **Tests** (STEP 12) + **Security audit** (STEP 13) — role matrix + IDOR/cross-scope.
10. **Remove Supabase** (STEP 14) — delete deps/code/env; re-grep zero active usage.
11. **Build + Vercel** (STEP 15–16) — green build/lint, preview deploy, no DB creds in browser bundle.
12. **Final reports** (STEP 17).

---

## 3. Data migration (task §24 — only AFTER schema validated)
Documented, not auto-copy: export (`pg_dump --data-only` + `auth.users` bcrypt hashes) → transform (map to owned `auth.users`) → import → FK validation → row counts for users/persons/churches/services/classes/families/attendance/points/achievements/events/exams/results/messages/finance/products/orders → duplicate/null/index/sequence checks → app smoke tests.

---

## 4. Safety guarantees (task §1 & §30)
Only the NEW repo (`diocese-management-app-test`) + NEW Vercel/Neon env are modified. No push/modify/delete to original repo; no changes to original Vercel/Supabase; no migrations against or data copy from production. Secrets server-side only.
