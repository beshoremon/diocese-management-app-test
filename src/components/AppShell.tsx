'use client';

import { type ReactNode } from 'react';
import { useAuth } from '@/lib/auth-context';
import AppHeader from '@/components/AppHeader';
import BottomNav from '@/components/BottomNav';
import PendingApproval from '@/components/PendingApproval';
import { Loader2 } from 'lucide-react';

/**
 * AppShell — wraps authenticated pages with header + bottom nav.
 * Blocks unapproved accounts behind the PendingApproval screen (realtime-updated).
 */
export default function AppShell({ children }: { children: ReactNode }) {
  const { user, profile, loading } = useAuth();

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <Loader2 className="h-8 w-8 animate-spin text-primary-500" />
      </div>
    );
  }

  // BUG FIX: gate ANY authenticated user without an APPROVED profile.
  // Previously `profile && status !== 'approved'` let the app open right
  // after signup (profile still null until refresh).
  if (user && (!profile || profile.status !== 'approved')) {
    return <PendingApproval />;
  }

  return (
    <div className="flex min-h-screen flex-col">
      <AppHeader />
      <main id="main-content" className="flex-1 max-w-3xl w-full mx-auto px-4 py-4 pb-24">
        {children}
      </main>
      <BottomNav />
    </div>
  );
}
