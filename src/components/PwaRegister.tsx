'use client';

import { useEffect } from 'react';
import { BRANDING, BRANDING_VERSION } from '@/lib/branding';

export default function PwaRegister() {
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    // `updateViaCache: 'none'` → the browser re-fetches sw.js on every check
    // instead of trusting the HTTP cache, so a fixed worker reaches phones
    // that are still running a broken one.
    // The branding fingerprint + short name travel in the query string: the
    // worker reads them (push title fallback) and any change of the Vercel
    // branding variables yields a new URL → fresh install, old cache dropped.
    const swUrl = `/sw.js?b=${encodeURIComponent(BRANDING_VERSION)}&n=${encodeURIComponent(BRANDING.shortName)}`;
    navigator.serviceWorker
      .register(swUrl, { updateViaCache: 'none' })
      .then((reg) => { reg.update().catch(() => {}); })
      .catch(() => {});
  }, []);
  return null;
}
