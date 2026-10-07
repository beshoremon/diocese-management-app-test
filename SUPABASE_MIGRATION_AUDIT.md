# SUPABASE_MIGRATION_AUDIT.md
## إدارة الإيبارشية — Diocese Management PWA
### Supabase → Neon PostgreSQL · Phase 0 Audit (read-only — no code changed)

> **Scope of this document:** a factual inventory of **how the application
> actually uses Supabase today**, derived by reading the real repository
> (`src/` = 341 `.ts/.tsx` files, `supabase/` = 130 SQL files, 31,384 lines of
> consolidated schema). Nothing in the application or in either database was
> modified to produce this audit. No production system was touched.

---

## 0. Executive summary

| Area | Verdict | Risk |
|------|---------|------|
| **Database engine** | Pure PostgreSQL (112 tables, 2 enums, ~250 RPC functions, 150 triggers, 409 RLS policies, `pgcrypto` + `pg_trgm`). **100 % portable to Neon.** | LOW (engine) |
| **Database identity** | Entire security model keys off **`auth.uid()`** (308 uses) and the **`auth.users`** table (17 uses). Neon has neither. **This is the heart of the migration.** | **CRITICAL** |
| **Authentication** | *Hybrid*: **servant** = Supabase Auth (JWT cookies, OTP magiclink); **child** & **priest** = custom session-token tables already living in our own DB. | **CRITICAL** (servant half) |
| **Admin Auth API** | `auth.admin.createUser / deleteUser / generateLink / getUserById / updateUserById` drive servant creation + account-switch + backup restore. | **CRITICAL** |
| **Storage** | 2 buckets (`photos` public, `backups` private) via `supabase.storage`. | HIGH |
| **Realtime** | A single *broadcast bus* for live refresh. **Has a built-in no-realtime fallback (refetch on focus).** Not required for correctness. | MEDIUM |
| **RPC** | ~250 `SECURITY DEFINER` functions carry virtually all business logic + authorization. **Stay in Postgres → run on Neon almost unchanged** once `auth.uid()` is replaced. | HIGH (volume), LOW (portability) |
| **Push notifications** | `web-push` (VAPID) — **not a Supabase feature**, unaffected. | LOW |
| **Cron** | 2 daily jobs (backups 02:30, notifications 03:00) via Vercel Cron / Cloudflare triggers. | LOW |

**Bottom line:** The database (the 95 % of the system) is plain PostgreSQL and
moves to Neon cleanly. The migration is **not** a database rewrite — it is an
**identity-layer swap**: replace Supabase Auth's `auth.uid()` / `auth.users`
with our own session mechanism, replace `supabase.storage` with an S3-compatible
store, and neutralise `supabase.*` SDK calls on the client. Target architecture
**Next.js → Vercel → Neon** is achievable; the only genuinely new infrastructure
question is **object storage for the `photos` bucket** (§D, §21 of the task).

---

## A. Database

**Source of truth:** `supabase/migrations/` (73 ordered migrations, `0001` →
`20261016120000`) and the consolidated `supabase/full_schema.sql` (31,384 lines).
Counts across all migration SQL: **114 `create table`, 150 `create trigger`,
409 `create policy`, ~720 `create function` statements (≈250 unique functions
after replacements), 2 enums, 2 extensions.** Verified load on plain PostgreSQL
17: **107 tables, 1 view, 623 routines, 126 triggers, 261 live policies, 2
enums** (final state — several `_new` rebuild tables are dropped by later
migrations).

### A.1 Extensions
| Extension | Purpose | Neon support |
|-----------|---------|--------------|
| `pgcrypto` | `crypt()` / `gen_salt('bf')` bcrypt password hashing, `gen_random_bytes` for QR/codes/tokens | ✅ Available on Neon |
| `pg_trgm` | trigram indexes for Arabic name search | ✅ Available on Neon |

### A.2 Enums
- `public.app_role` = `('owner','church_manager','service_manager','class_servant')`
- `public.approval_status` = `('pending','approved','rejected','suspended')` (`suspended` added in 0005)

### A.3 Tables (107 final; 112 created across history)
Grouped by module — core hierarchy (`churches/services/classes/profiles/persons/
person_credentials/enrollments/servant_enrollments/servant_scopes/...`), people &
families, attendance & points, access control, events & occasions, achievements,
exams & results, finance, messaging & notifications, store, priest portal, child
portal, online classes, library, cards/printing, customization/reports/backup.
Session tables: `child_sessions`, `priest_sessions`, `login_grants`,
`account_switch_tickets`, `person_credentials`.

### A.4–A.8 PKs/FKs/constraints/indexes/triggers/functions
- uuid PKs (`gen_random_uuid()`); dense FK graph, mostly `on delete cascade`.
- **`profiles.id` and `servant_enrollments.id` are FKs to `auth.users(id)`** — Supabase coupling.
- Extensive per-scope btree indexes + `pg_trgm` GIN for search + stats composites — **preserve verbatim (§19)**.
- 150 triggers: auto-fill scope, points recompute, family-code gen, activity log, realtime bus `send()`, signup guards (`app.in_servant_signup`).
- See **§G** for the function/RPC layer.

---

## B. RLS

- **409 `CREATE POLICY`** across 52 files; every `public` table `ENABLE ROW LEVEL SECURITY`.
- Expressed through `SECURITY DEFINER` helpers to avoid recursion: `my_profile()`, `my_role()`, `my_church()`, `my_service()`, `my_class()`, `is_owner()`, `can_access(church,service,class)` — **all call `auth.uid()`**.
- Boundaries: role-based (owner→all, church_manager→church, service_manager→service, class_servant→class); church/service/class isolation via `can_access`; personal rows keyed to the user id; realtime join gated by `rt_gates` + RLS on `realtime.messages`.
- **Migration consequence:** RLS is standard PostgreSQL → runs on Neon. The only blocker is `auth.uid()`/`auth.role()`. Plan: provide a Neon identity (`app.uid()`) set per-request by the server after validating our own session — **keep RLS, swap the identity source.**

---

## C. Authentication

Identity rule: **"one person · one code · one password · many accounts"** (migrations `20261003/04120000`).

- **Servant** = Supabase Auth (JWT cookies via `@supabase/ssr`; `signInWithPassword/signUp/signOut/getUser/getSession/refreshSession/updateUser/verifyOtp/onAuthStateChange`). `profiles.id`/`servant_enrollments.id` = `auth.users.id`. Switch→servant uses `auth.admin.generateLink` magiclink + `verifyOtp`. Create uses `auth.admin.createUser`.
- **Child** = custom `child_sessions` (opaque token, sha256-hashed, 12h/90d), bcrypt in `person_credentials`; identity from `p_token`, not `auth.uid()`.
- **Priest** = custom `priest_sessions`, same pattern.
- Middleware `src/middleware.ts`: `getSession()` route gate; `/child`,`/priest` public (guarded in RPCs).
- Password: bcrypt in `person_credentials`; mirrored between Supabase Auth and our DB.

> **Key finding:** child & priest auth are **already independent of Supabase**. Only the servant half depends on it → migration = extend the existing token mechanism to servants.

---

## D. Storage

| Bucket | Visibility | Contents |
|--------|-----------|----------|
| `photos` | public | compressed 512px WebP person/child/service/class/card/store/exam/message/achievement/occasion/notification/priest images; `child-requests` anon-writable |
| `backups` | private | scheduled DB backup archives (service role only) |
| `church-logos` | public | church logos (4 call sites) |

Storage RLS in `storage.objects`/`storage.buckets` (22 SQL refs). Upload path `<folder>/<timestamp>-<name>` immutable, 1-year cache, `images.unoptimized`.

> **Target (D3): Vercel Blob.** Files must not go into Postgres. Access control moves to server-side signed uploads.

---

## E. Realtime

- One **broadcast bus** (`0046`, `20261016120000`), `src/lib/realtime.ts` (545 lines), ~75 consumers via `useDebouncedRealtime`.
- Statement-level triggers `realtime.send()` on per-scope topics; browser opens 2–4 channels; join authorized by `rt_gates`.
- **Documented fallback:** if the bus is down, no poll — header shows «غير متصل» and screens refetch on focus/return. → **Realtime is a UX accelerator, not a correctness requirement.**

> **Target (D4): use the fallback; add no realtime provider.**

---

## F. Edge Functions

**None.** No `supabase/functions/`. All server logic is in Postgres RPCs + Next.js Route Handlers.

---

## G. RPC

- **~250 distinct `SECURITY DEFINER` functions** via `supabase.rpc(...)` from 160 files. Groups: auth/accounts, child portal (~45), priest portal (~55), owner admin (~20), stats/reports, store, notifications/chat, backup/restore (~15, touch `auth.users`), signup/invites, config/bootstrap.
- **Target (D5): keep in Postgres on Neon.** Adaptations: `auth.uid()`→via `app.uid()`; backup RPCs reading `auth.users` target the new owned table; `supabase.rpc()` calls become server-side DB calls.

---

## H. Client vs Server execution

| Context | Usage | Count |
|---------|-------|-------|
| Browser (Client Components) | anon-key `.from()/.rpc()/.channel()` (RLS-enforced) | ~155 files |
| Server Components/RSC | cookie-bound anon client | few |
| Route Handlers `/api/*` | service-role admin (auth-admin, backup, push, switch) | 9 |
| Middleware | `getSession()` gate | 1 |
| Cron | backup/cron, notifications/dispatch | 2 |

> **Security consequence:** today the browser talks to Postgres with the anon key and **RLS is the only guard**. On Neon there is no client-safe endpoint — the connection string is full-power and must never reach the browser (§13). **Every browser `.from()/.rpc()` must move behind a server boundary** (~155 files) — the largest edit surface, handled via a thin server gateway + client shim.

---

## I. Environment variables (names only)

**Supabase (remove):** `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.
**Neon (add, server-only):** `DATABASE_URL`, `DATABASE_URL_POOLED`.
**Auth/session (new, server-only):** `SESSION_SECRET`/`AUTH_SECRET`.
**Storage (new, server-only):** `BLOB_READ_WRITE_TOKEN` (Vercel Blob).
**Unchanged:** VAPID keys, `CRON_SECRET`, `NEXT_PUBLIC_APP_*`/`DIOCESE_*`/`THEME_*`, `NEXTJS_ENV`.

---

## J. Migration risk register

| # | Dependency | Risk |
|---|-----------|------|
| 1 | `auth.uid()` (308×) + `auth.users` (17×) | **CRITICAL** |
| 2 | Servant auth = Supabase Auth (JWT, middleware) | **CRITICAL** |
| 3 | Admin Auth API (createUser/deleteUser/generateLink/getUserById/updateUserById) | **CRITICAL** |
| 4 | ~155 browser files relying on anon-key + RLS → move server-side | **HIGH** |
| 5 | Storage (photos/backups/church-logos) + `storage.objects` RLS | **HIGH** |
| 6 | ~250 RPCs | HIGH volume / LOW portability |
| 7 | Backup/restore RPCs touching `auth.users` | HIGH |
| 8 | Realtime bus | MEDIUM (fallback exists) |
| 9 | `@supabase/ssr` cookie plumbing | MEDIUM |
| 10 | Password mirroring → single store + bcrypt import | MEDIUM |
| 11 | Cron (Vercel + Cloudflare) | LOW |
| 12 | web-push/VAPID | LOW |
| 13 | pgcrypto, pg_trgm | LOW (on Neon) |
| 14 | Dual deploy configs (Vercel + OpenNext) | LOW |

See `MIGRATION_PLAN.md` for the replacement strategy, sequencing, and tests.
