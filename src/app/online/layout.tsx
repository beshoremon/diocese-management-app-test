'use client';

// Online classes module gate (الفصول الأونلاين) — every /online/* page renders
// only when the `online` module is granted to the caller's scope (owner always passes).

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function OnlineModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="online" shell>
      {children}
    </ModuleGate>
  );
}
