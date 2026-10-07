// =====================================================================
// middleware (Neon version) — route gate without Supabase  (Phase 1)
// =====================================================================
// Drop-in replacement for src/middleware.ts. The ORIGINAL used
// supabase.auth.getSession() (a local JWT check). This version gates routes by
// the PRESENCE of the servant session cookie — a cheap, Edge-safe check. The
// REAL authorization still happens server-side: every data path runs through
// lib/db.withUser(), which validates the cookie against servant_sessions and
// applies RLS. A forged/edited cookie passes the gate but gets a null identity
// and RLS returns nothing (identical to the original design, which also noted
// "a forged cookie gets nothing but a redirect-free 401").
//
// Wiring (P1.7): replace src/middleware.ts with this file's body once the
// Supabase middleware is retired. Kept separate now so no Supabase code is
// deleted yet (task: "do not delete Supabase code yet").
import { NextResponse, type NextRequest } from 'next/server';

// NOTE: cannot import from '@/lib/db/session' here — that module is
// `server-only` (pulls in pg). The cookie name is a stable constant; keep it
// in sync with SERVANT_COOKIE in src/lib/db/session.ts.
const SERVANT_COOKIE = 'dma_servant_session';

// /child and /priest are their own portals (token in localStorage, validated
// inside their RPCs) — public at the middleware layer, as before.
const PUBLIC_PATHS = ['/login', '/signup', '/pending', '/child', '/priest'];

export function middleware(request: NextRequest) {
  const path = request.nextUrl.pathname;
  const isPublic = PUBLIC_PATHS.some((p) => path.startsWith(p));
  const hasSession = Boolean(request.cookies.get(SERVANT_COOKIE)?.value);

  if (!hasSession && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';
    return NextResponse.redirect(url);
  }
  if (hasSession && (path.startsWith('/login') || path.startsWith('/signup'))) {
    const url = request.nextUrl.clone();
    url.pathname = '/';
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|favicon-16.png|favicon-32.png|manifest.json|manifest.webmanifest|sw.js|offline|branding|icons|api).*)',
  ],
};
