'use client';

// ---------- Home widget — today's & upcoming birthdays (7 days) ----------
// Rendered on الرئيسية only when the `birthdays` module is granted to the
// caller. Uses `birthdays_upcoming` (RLS-scoped) anchored on the app working
// date. Tap → /birthdays (month view). Realtime on persons / greetings.

import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Cake, ChevronLeft, Phone } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth-context';
import { useAppDate } from '@/lib/app-date-context';
import { useModuleVisible } from '@/lib/modules-context';
import { useDebouncedRealtime } from '@/lib/realtime';
import { cairoToday } from '@/lib/time';
import { fetchUpcomingBirthdays, type UpcomingBirthday, firstName, waNumber } from '@/lib/birthdays';
import { PersonAvatar, WhatsAppIcon } from './BirthdayBits';

export default function UpcomingBirthdaysWidget() {
  const visible = useModuleVisible('birthdays');
  const { profile } = useAuth();
  const { now } = useAppDate();
  const [supabase] = useState(() => createClient());
  const [rows, setRows] = useState<UpcomingBirthday[] | null>(null);
  const today = cairoToday(now());
  const enabled = visible === true && profile?.status === 'approved';

  const load = useCallback(async () => {
    try { setRows(await fetchUpcomingBirthdays(supabase, 7, today)); }
    catch { setRows([]); }
  }, [supabase, today]);
  useEffect(() => { if (enabled) load(); }, [enabled, load]);
  useDebouncedRealtime(supabase, 'home-birthdays', [{ table: 'persons' }, { table: 'birthday_greetings' }], load, { enabled });

  if (!enabled || rows === null || rows.length === 0) return null;
  const todays = rows.filter((r) => r.days_left === 0);
  const soon = rows.filter((r) => r.days_left > 0);

  return (
    <section id="home-birthdays" className="card mb-5 !p-0 overflow-hidden">
      <Link href="/birthdays" className="flex items-center gap-2 bg-gradient-to-l from-pink-600 to-rose-500 px-4 py-2.5 text-white">
        <Cake className="h-5 w-5" />
        <span className="flex-1 text-sm font-extrabold">
          أعياد الميلاد {todays.length > 0 ? `· اليوم ${todays.length} 🎉` : `· القادمة ${soon.length}`}
        </span>
        <ChevronLeft className="h-4 w-4" />
      </Link>
      <ul className="divide-y divide-pink-50">
        {rows.slice(0, 6).map((r) => (
          <li key={r.person_id} className={`flex items-center gap-3 px-3 py-2 ${r.days_left === 0 ? 'bg-pink-50/60' : ''}`}>
            <PersonAvatar url={r.image_url} name={r.name} size={38} />
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-extrabold">{r.name}</span>
              <span className="block text-[11px] font-bold text-slate-400">
                {r.days_left === 0 ? <span className="text-pink-600">🎂 اليوم</span> : r.days_left === 1 ? 'غداً' : `بعد ${r.days_left} أيام`} · يتمّ {r.turns_age} سنة
              </span>
            </span>
            {r.phone && (
              <span className="flex gap-1">
                <a href={`tel:${r.phone}`} aria-label={`اتصال بـ ${firstName(r.name)}`} className="rounded-xl bg-sky-50 p-2 text-sky-700"><Phone className="h-4 w-4" /></a>
                <a href={`https://wa.me/${waNumber(r.phone)}`} target="_blank" rel="noopener noreferrer" aria-label="واتساب" className="rounded-xl bg-emerald-50 p-2 text-emerald-700"><WhatsAppIcon className="h-4 w-4" /></a>
              </span>
            )}
          </li>
        ))}
      </ul>
      {rows.length > 6 && (
        <Link href="/birthdays" className="block bg-slate-50 py-2 text-center text-xs font-extrabold text-pink-700">و{rows.length - 6} آخرون هذا الأسبوع ←</Link>
      )}
    </section>
  );
}
