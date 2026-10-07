// =====================================================================
// lib/db/auth-actions — Neon auth server actions (Phase 1)
// =====================================================================
// Server-side replacements for the Supabase Auth flows. These run on the
// server, validate everything in the DB, and manage the HttpOnly servant
// cookie. The child/priest portals keep returning their tokens to the client
// (localStorage) exactly as before; only the SERVANT branch changed (token in
// a secure cookie instead of a Supabase JWT + magiclink).
//
// Preserves (task D2): "one person · one code · one password · many accounts",
// account switching without logout, all roles/permissions. Passwords are
// bcrypt-verified in the DB (account_login); no plaintext, no client secret.
import 'server-only';
import { withService } from './client';
import { setServantCookie, clearServantCookie, getServantToken } from './session';

export type AccountKind = 'servant' | 'child' | 'priest';

export interface PersonAccount {
  kind: AccountKind;
  id: string;
  enrollment_id: string;
  status: string;
  label: string;
  label2?: string;
  church_id?: string | null;
  service_id?: string | null;
  class_id?: string | null;
  [k: string]: unknown;
}

export interface LoginResult {
  grant: string;
  person: { id: string; name: string; code: string; image_url: string | null };
  accounts: PersonAccount[];
}

/** Step 1: code + the one password → short-lived grant + the person's accounts. */
export async function login(code: string, password: string, remember: boolean): Promise<LoginResult> {
  return withService((db) =>
    db.rpc<LoginResult>('account_login', {
      p_code: code.trim(),
      p_password: password,
      p_remember: remember,
    })
  );
}

export interface MintResult {
  kind: AccountKind;
  token?: string;            // servant/child/priest all return a token on Neon
  expires_at?: string;
  person_id?: string;
  servant_id?: string;
  priest_id?: string;
  enrollment_id?: string | null;
}

/**
 * Step 2: exchange the grant for a session of the chosen account.
 * SERVANT → token stored in the HttpOnly cookie (server-side); the caller
 * navigates to '/'. CHILD/PRIEST → token returned to the caller to store
 * client-side (unchanged behavior), caller navigates to '/child' | '/priest'.
 */
export async function sessionFromLogin(
  grant: string,
  acc: Pick<PersonAccount, 'kind' | 'enrollment_id' | 'church_id' | 'service_id' | 'class_id'>,
  remember: boolean,
  userAgent?: string | null
): Promise<MintResult> {
  const res = await withService((db) =>
    db.rpc<MintResult>('account_session_from_login', {
      p_grant: grant,
      p_kind: acc.kind,
      p_enrollment: acc.kind === 'child' ? acc.enrollment_id : null,
      p_church: acc.kind === 'servant' ? acc.church_id ?? null : null,
      p_service: acc.kind === 'servant' ? acc.service_id ?? null : null,
      p_class: acc.kind === 'servant' ? acc.class_id ?? null : null,
      p_user_agent: userAgent ?? null,
    })
  );
  if (res.kind === 'servant' && res.token) setServantCookie(res.token, remember);
  return res;
}

/**
 * Switch to another account of the SAME person WITHOUT logout.
 * from = the current kind; fromToken = child/priest localStorage token (null
 * for servant — the server reads its cookie). Servant target → new cookie.
 */
export async function switchAccount(
  from: AccountKind,
  fromToken: string | null,
  target: Pick<PersonAccount, 'kind' | 'enrollment_id' | 'church_id' | 'service_id' | 'class_id'>,
  remember: boolean
): Promise<MintResult> {
  const fromTok = from === 'servant' ? getServantToken() : fromToken;
  const res = await withService((db) =>
    db.rpc<MintResult>('account_switch', {
      p_from_kind: from,
      p_from_token: fromTok,
      p_to_kind: target.kind,
      p_remember: remember,
      p_enrollment: target.kind === 'child' ? target.enrollment_id ?? null : null,
      p_church: target.kind === 'servant' ? target.church_id ?? null : null,
      p_service: target.kind === 'servant' ? target.service_id ?? null : null,
      p_class: target.kind === 'servant' ? target.class_id ?? null : null,
    })
  );
  if (res.kind === 'servant' && res.token) setServantCookie(res.token, remember);
  return res;
}

/** Log the servant out: delete the DB session + clear the cookie. */
export async function logoutServant(): Promise<void> {
  const token = getServantToken();
  if (token) {
    try {
      await withService((db) => db.rpc('servant_session_logout', { p_token: token }));
    } catch { /* ignore */ }
  }
  clearServantCookie();
}

/** List the current person's accounts (for the switcher UI). */
export async function myAccounts(kind: AccountKind, token: string | null): Promise<unknown> {
  const tok = kind === 'servant' ? getServantToken() : token;
  return withService((db) => db.rpc('my_accounts', { p_kind: kind, p_token: tok }));
}
