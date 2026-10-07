// GET /api/notifications/vapid → { publicKey } — the VAPID public key the
// browser needs to subscribe (public by nature).
import { NextResponse } from 'next/server';
import { vapidPublicKey } from '@/lib/server/push-dispatch';

export const dynamic = 'force-dynamic';

export async function GET() {
  const publicKey = vapidPublicKey();
  return NextResponse.json({ publicKey, configured: !!publicKey && !!process.env.VAPID_PRIVATE_KEY });
}
