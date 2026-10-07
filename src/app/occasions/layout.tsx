'use client';

// Occasions module gate (الفعاليات) — every /occasions/* page renders only
// when the `occasions` module is granted to the caller's scope (owner always
// passes). Pages render their own <AppShell>; the gate supplies one for the
// loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function OccasionsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="occasions" shell>
      {children}
    </ModuleGate>
  );
}
