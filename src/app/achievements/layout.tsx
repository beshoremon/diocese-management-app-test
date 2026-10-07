'use client';

// Achievements module gate (الإنجازات) — every /achievements/* page renders
// only when the `achievements` module is granted to the caller's scope
// (owner always passes). Pages render their own <AppShell>; the gate
// supplies one for the loading / blocked states.

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function AchievementsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="achievements" shell>
      {children}
    </ModuleGate>
  );
}
