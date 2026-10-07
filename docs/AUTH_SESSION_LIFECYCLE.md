# AUTH_SESSION_LIFECYCLE.md
## Current authentication & session lifecycle (as-built, pre-migration)
### Required reading before the identity migration (task D2)

> Documents the **exact** current behavior, read from `supabase/full_schema.sql`
> and `src/lib/*`. It is the contract the Neon identity layer must reproduce
> functionally unchanged.

---

## 1. Identity model: "one person · one code · one password · many accounts"
- **person** = `public.persons` row, keyed by `national_id` (= login *code* = QR).
- One **password** per person: bcrypt in `public.person_credentials`, verified by `person_password_ok()` / `crypt(pw,hash)=hash`.
- Up to three account kinds:

| kind | account row | session store | identity inside SQL |
|------|-------------|---------------|---------------------|
| **servant** | `servant_enrollments` (`id` = `auth.users.id`) | Supabase Auth JWT cookie | `auth.uid()` |
| **child** | `enrollments (kind='child')` | `child_sessions` (opaque token, sha256) | `session_person('child', token)` |
| **priest** | `priests` | `priest_sessions` (opaque token, sha256) | `session_person('priest', token)` |

Child & priest identity is **already** app-issued-token based (no Supabase). Only servant uses `auth.uid()`.

## 2. Session stores
- `child_sessions` / `priest_sessions`: token = `encode(gen_random_bytes(32),'hex')` returned once; DB stores `sha256(token)` as `token_hash`; expiry 12h or 90d (remember); sliding extension on touch.
- `person_credentials`: one bcrypt password per person; `revoke all from anon,authenticated` (RPC-only).
- `login_grants`: 5-min bridge between password-check and account-choice.
- `account_switch_tickets`: 2-min one-time ticket for the servant Supabase-Auth magiclink exchange.

## 3. Login lifecycle (single login page)
`account_login(code, pw, remember)` → find person, `person_accounts()`, `person_password_ok()` (bcrypt, `pg_sleep(0.25)` on fail), insert `login_grants` → `{grant, person, accounts}`.
Pick account → `account_session_from_login(grant, kind, enrollment, place…)` → consume grant → `account_mint(person, kind, …)`:
- child/priest → insert session row → `{token, expires_at}` stored client-side.
- servant → insert `account_switch_tickets` → `{ticket}` → `POST /api/account/switch` (service role) → `account_switch_redeem` → `auth.admin.generateLink(magiclink)` → browser `verifyOtp` → Supabase Auth cookie.

## 4. Account switching (no logout)
`switchAccount()`: servant→own place = `servant_set_active_place`; any→child/priest = `account_switch`→`account_mint`→token; any→servant = ticket→magiclink. `my_accounts(kind, token)` lists accounts + current.

## 5. Middleware
`src/middleware.ts`: non-public paths require `supabase.auth.getSession()`; `/login /signup /pending /child /priest` public.

## 6. Remember-me
Servant: tab-only via `dma_no_remember`/`dma_tab_alive` markers. Child/priest: expiry encoded in token (12h vs 90d).

## 7. `auth.uid()` / `auth.role()`
`auth.uid()` (308×) = servant's `servant_enrollments.id`. Used by `my_role/my_church/my_service/my_class/is_owner/can_access` + `session_person('servant')` + ~250 RPCs + 409 policies. `auth.role()` = `'authenticated'`/`'service_role'`.

## 8. Target identity design on Neon (what we build)
1. `app` schema: `app.uid()` = `current_setting('request.jwt.claim.sub')::uuid`; `app.role()`; `app.set_user(uuid, role)` = `SET LOCAL` (server-only, after session validation); `app.clear_user()`.
2. **Compat:** `auth.uid()`/`auth.role()` delegate to `app.*` → 308 sites + 261 policies unchanged. "auth.uid() → app.uid()" centralized.
3. `servant_sessions` (mirror of `child_sessions`): opaque token → HttpOnly cookie; server resolves per request → `app.set_user(servant_enrollments.id)`.
4. `auth.users` → plain owned table (servant login accounts; bcrypt in `encrypted_password`).
5. Invariants preserved: no plaintext passwords; token/secret never on client; server-side validation; RLS enforces on server-set `app.uid()`; client-supplied scope IDs never trusted.
