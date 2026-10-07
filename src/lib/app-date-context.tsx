'use client';

// ---------- App date override ----------
// A global "working date/time" the servant can change from the header
// date button. When set, EVERY date-based operation (attendance register,
// event availability, "today" checks) uses this date instead of the real
// clock. When null, the app follows the live clock.

import {
  createContext, useContext, useState, useCallback, useMemo, type ReactNode,
} from 'react';

interface AppDateContextValue {
  /** the override instant, or null = live clock */
  appDate: Date | null;
  /** true when the servant picked a custom date/time */
  isOverridden: boolean;
  /** the instant all operations should use (override or real now) */
  now: () => Date;
  setAppDate: (d: Date | null) => void;
}

const AppDateContext = createContext<AppDateContextValue>({
  appDate: null,
  isOverridden: false,
  now: () => new Date(),
  setAppDate: () => {},
});

export function AppDateProvider({ children }: { children: ReactNode }) {
  const [appDate, setAppDateState] = useState<Date | null>(null);

  const setAppDate = useCallback((d: Date | null) => {
    setAppDateState(d && !isNaN(d.getTime()) ? d : null);
  }, []);

  const now = useCallback(() => appDate ?? new Date(), [appDate]);

  const value = useMemo(
    () => ({ appDate, isOverridden: appDate !== null, now, setAppDate }),
    [appDate, now, setAppDate]
  );

  return <AppDateContext.Provider value={value}>{children}</AppDateContext.Provider>;
}

export const useAppDate = () => useContext(AppDateContext);
