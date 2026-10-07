// Web App Manifest — generated at build time from the branding environment
// variables (see src/lib/branding.ts). Served at /branding/manifest.
//
// Deliberately NOT `app/manifest.ts` / `app/manifest.webmanifest`: Next's
// metadata-file convention injects its own un-versioned
// <link rel="manifest" href="/manifest.webmanifest"> and overrides ours,
// whereas we need `?v=<branding hash>` on the URL so browsers re-read the
// manifest (and pick up the new icon) as soon as a branding variable changes.
import { NextResponse } from 'next/server';
import type { MetadataRoute } from 'next';
import { BRANDING, appIcon } from '@/lib/branding';

export const dynamic = 'force-static';

function manifest(): MetadataRoute.Manifest {
  return {
    name: BRANDING.appName,
    short_name: BRANDING.shortName,
    description: BRANDING.description,
    start_url: '/',
    display: 'standalone',
    orientation: 'portrait',
    dir: 'rtl',
    lang: 'ar',
    background_color: BRANDING.backgroundColor,
    theme_color: BRANDING.themeColor,
    icons: [
      { src: appIcon(96), sizes: '96x96', type: 'image/png', purpose: 'any' },
      { src: appIcon(192), sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: appIcon(192), sizes: '192x192', type: 'image/png', purpose: 'maskable' },
      { src: appIcon(512), sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: appIcon(512), sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  };
}

export function GET() {
  return NextResponse.json(manifest(), {
    headers: {
      'Content-Type': 'application/manifest+json; charset=utf-8',
      // the URL is versioned (?v=hash) — force revalidation on the bare path anyway
      'Cache-Control': 'public, max-age=0, must-revalidate',
    },
  });
}
