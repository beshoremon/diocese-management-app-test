'use client';

// Exams module gate (الامتحانات) — every /exams/* page renders only when
// the `exams` module is granted to the caller's scope (owner always passes).

import { type ReactNode } from 'react';
import { ModuleGate } from '@/components/ModuleGate';

export default function ExamsModuleLayout({ children }: { children: ReactNode }) {
  return (
    <ModuleGate module="exams" shell>
      {children}
    </ModuleGate>
  );
}
