import type { ReactNode } from 'react';
import { ChildProvider } from '@/lib/child-context';

// Child portal (بوابة المخدوم) — everything under /child/* shares the
// scanned-QR session.
export default function ChildLayout({ children }: { children: ReactNode }) {
  return <ChildProvider>{children}</ChildProvider>;
}
