'use client';

// Card module gate — every /settings/cards/* page renders only when the
// `cards` module is granted to the caller's scope (owner always passes).
// The pages below render their own <AppShell>; the gate supplies one for
// the loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function CardsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="cards" shell>
      {children}
    </ModuleGate>
  );
}
