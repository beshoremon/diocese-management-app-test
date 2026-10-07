'use client';

// Points store module gate (إستبدال النقاط) — every /store/* page renders
// only when the `store` module is granted to the caller's scope (owner
// always passes). Pages render their own <AppShell>; the gate supplies one
// for the loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function StoreModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="store" shell>
      {children}
    </ModuleGate>
  );
}
