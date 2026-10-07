'use client';

// Shepherds module gate (الأشابين) — every /shepherds/* page renders only
// when the `shepherds` module is granted to the caller's scope (owner
// always passes). Pages render their own <AppShell>; the gate supplies one
// for the loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function ShepherdsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="shepherds" shell>
      {children}
    </ModuleGate>
  );
}
