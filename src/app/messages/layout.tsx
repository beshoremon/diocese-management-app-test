'use client';

// Messages module gate (الرسائل) — every /messages/* page renders only when
// the `messages` module is granted to the caller's scope (owner always
// passes). Pages render their own <AppShell>; the gate supplies one for the
// loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function MessagesModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="messages" shell>
      {children}
    </ModuleGate>
  );
}
