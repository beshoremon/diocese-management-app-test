'use client';

// Notifications module gate (الإشعارات) — every /notifications/* page renders
// only when the `notifications` module is granted to the caller's scope
// (owner always passes). Pages render their own <AppShell>; the gate
// supplies one for the loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function NotificationsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="notifications" shell>
      {children}
    </ModuleGate>
  );
}
