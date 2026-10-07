// =====================================================================
// lib/db/session — server-side session resolution (Neon, Phase 1)
// =====================================================================
// Converts the incoming request's HttpOnly cookie into a trusted,
// server-validated identity (the servant_enrollments.id that auth.uid() used
// to return). Used by Route Handlers / Server Actions to pick the uid passed
// to lib/db.withUser().
//
// SECURITY (task D2):
//   * the servant session token lives ONLY in an HttpOnly, Secure, SameSite
//     cookie — never readable by client JS, never in a bundle;
//   * the token is validated against servant_sessions server-side on every
//     request (servant_session_resolve → checks hash + expiry + approved);
//   * a missing/forged/expired cookie yields a NULL identity → withUser runs
//     as anon → RLS denies. We never trust a client-supplied id/role.
//
// Child / priest portals keep their existing token mechanism (localStorage +
// RPC token arg); this module is the SERVANT equivalent, moved to a secure
// cookie now that servants no longer use Supabase Auth.
import 'server-only';
import { cookies } from 'next/headers';
import { withService } from './client';

export const SERVANT_COOKIE = 'dma_servant_session';

export interface ServantIdentity {
  servantId: string; // servant_enrollments.id (= legacy auth.uid())
}

/** Cookie options for the servant session token. */
export function servantCookieOptions(maxAgeSeconds: number) {
  return {
    httpOnly: true as const,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax' as const,
    path: '/',
    maxAge: maxAgeSeconds,
  };
}

/** Store a freshly minted servant session token in the HttpOnly cookie. */
export function setServantCookie(token: string, remember: boolean) {
  const maxAge = remember ? 60 * 60 * 24 * 90 : 60 * 60 * 12; // 90d / 12h
  cookies().set(SERVANT_COOKIE, token, servantCookieOptions(maxAge));
}

export function clearServantCookie() {
  cookies().set(SERVANT_COOKIE, '', servantCookieOptions(0));
}

export function getServantToken(): string | null {
  return cookies().get(SERVANT_COOKIE)?.value || null;
}

/**
 * Resolve the current servant identity from the cookie, validated in the DB.
 * Returns null when there is no valid session (→ caller runs as anon).
 */
export async function getServantIdentity(): Promise<ServantIdentity | null> {
  const token = getServantToken();
  if (!token) return null;
  try {
    const servantId = await withService((db) =>
      db.rpc<string>('servant_session_resolve', { p_token: token })
    );
    return servantId ? { servantId } : null;
  } catch {
    // session_expired / account_stopped → treat as unauthenticated
    return null;
  }
}

/**
 * Convenience: the uid to hand to withUser() for the current request, or null.
 */
export async function currentServantUid(): Promise<string | null> {
  const id = await getServantIdentity();
  return id?.servantId ?? null;
}
