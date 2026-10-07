# Neon migration — SQL test results

Environment: local PostgreSQL 17.11 (Neon-equivalent; Neon runs PG 17).
Build: `db/neon/00_identity.sql` + all 73 app migrations + `10_grants.sql` +
`20_servant_auth.sql` (+ `30_bootstrap.sql` for the app DB).

## Summary
- **36 passed** (35 of the project's own `supabase/tests/*` + the new
  `neon_authz_test.sql`).
- **7 "failed"** — every one is either **pre-existing** (fails identically on
  the ORIGINAL Supabase `local_shim.sql`) or an **intended behavior change**
  from the migration. **None is an authorization/identity/RLS regression.**

## The 7, categorized (compared against the original Supabase shim)

| Test | Original Supabase shim | Neon build | Category |
|------|------------------------|------------|----------|
| `backup_restore_e2e_test` | FAIL "seed the database first (only 8 rows)" | FAIL (same) | **Pre-existing** — needs seed data |
| `owner_persons_test` | FAIL "expected 1 unenrolled child, got 0" | FAIL (same) | **Pre-existing** — seed/data shape |
| `scope_sort_order_single_confession_father_test` | FAIL "person_not_found" | FAIL (same) | **Pre-existing** — seed |
| `servant_scope_requests_test` | FAIL "unenrolled filter: 0 expected, got 1" | FAIL (same) | **Pre-existing** — seed/data shape |
| `person_kinds_merge_test` | FAIL (perm denied earlier) | FAIL "priest mirror hash…" | **Pre-existing** — password-mirror/seed; gets *further* on Neon |
| `single_login_invites_test` | PASS (expects servant **ticket**) | FAIL "servant ticket expected" | **Expected change** — servant now returns a **token** (Supabase removed) |
| `unified_person_accounts_test` | PASS (expects servant **ticket**) | FAIL "servant ticket wrong {token…}" | **Expected change** — same; new token flow re-verified in `neon_authz_test §7` |

## neon_authz_test.sql (the Phase-1 acceptance test) — PASS
Proves on the `app.uid()` identity + RLS:
1. identity sanity (`app.uid()==auth.uid()`, owner role);
2. owner sees all churches; church manager → own church only;
3. **cross-church** read blocked (service + class);
4. **cross-service** blocked; **cross-class** blocked;
5. **forged/unknown uid** → NULL role, not owner, 0 rows; **anon** → 0 rows;
6. **forged scope** (passing another church's id to `can_access`) → rejected
   (RLS reads scope from the DB, never from client input);
7. **new servant session**: `account_mint('servant')` returns a 64-char
   **token** (not a Supabase ticket), resolves to the right servant; bogus
   token → `session_expired`.

## How to reproduce
```
bash db/neon/local_pg_setup.sh            # local PG17 (dev/testing only)
PSQL_SUPER="sudo -u postgres psql -p 5432" DB=neon_test bash db/neon/run_tests.sh
```
