'use client';

// ---------- Child portal — الفعاليات (board) ----------
// Upcoming occasions I can see (published, covering one of my enrollments
// where the module is granted) with my registration status on each card,
// plus the ones I took part in recently. Data comes from the shared
// ChildProvider (child_portal_occasions RPC, realtime).

import { useMemo, useState } from 'react';
import { Tent, Loader2, Ticket, Sparkles, History } from 'lucide-react';
import ChildShell, { useChildOccasions } from '@/components/child/ChildShell';
import { OccasionCard, RegStatusBadge } from '@/components/occasions/OccasionBits';
import { occasionPhase, type ChildOccasion } from '@/lib/occasions';

type Filter = 'upcoming' | 'mine' | 'past';

export default function ChildOccasionsPage() {
  return (
    <ChildShell>
      <Content />
    </ChildShell>
  );
}

function Content() {
  const { list, open, withTicket } = useChildOccasions();
  const [filter, setFilter] = useState<Filter>('upcoming');

  const groups = useMemo(() => {
    const now = new Date();
    const all = list ?? [];
    const notPast = (o: ChildOccasion) => o.status === 'published' && occasionPhase(o, now) !== 'past';
    return {
      upcoming: all.filter(notPast),
      mine: all.filter((o) => o.my_registration && o.my_registration.status !== 'cancelled' && notPast(o)),
      past: all.filter((o) => !notPast(o)),
    };
  }, [list]);

  const shown = groups[filter];
  const FILTERS: { value: Filter; label: string; n: number }[] = [
    { value: 'upcoming', label: 'القادمة', n: groups.upcoming.length },
    { value: 'mine', label: 'مشاركاتي', n: groups.mine.length },
    { value: 'past', label: 'السابقة', n: groups.past.length },
  ];

  return (
    <>
      <section className="mb-3 flex items-center gap-2">
        <h2 className="flex items-center gap-2 text-lg font-extrabold"><Tent className="h-5 w-5 text-cyan-600" /> الفعاليات</h2>
        {list && <span className="badge bg-cyan-100 text-cyan-700 tabular-nums">{groups.upcoming.length}</span>}
      </section>

      {!list ? (
        <div className="flex justify-center py-16"><Loader2 className="h-8 w-8 animate-spin text-cyan-500" /></div>
      ) : (
        <>
          <section className="mb-3 grid grid-cols-2 gap-3">
            <div className="card flex items-center gap-3 border border-cyan-100 bg-cyan-50 !p-3">
              <span className="rounded-xl bg-white/70 p-2"><Sparkles className="h-6 w-6 text-cyan-600" /></span>
              <div><p className="text-2xl font-extrabold tabular-nums leading-tight">{open}</p><p className="text-xs font-bold text-slate-500">يمكنك التسجيل فيها</p></div>
            </div>
            <div className="card flex items-center gap-3 border border-emerald-100 bg-emerald-50 !p-3">
              <span className="rounded-xl bg-white/70 p-2"><Ticket className="h-6 w-6 text-emerald-600" /></span>
              <div><p className="text-2xl font-extrabold tabular-nums leading-tight">{withTicket}</p><p className="text-xs font-bold text-slate-500">تذكرة جاهزة</p></div>
            </div>
          </section>

          <div id="child-occ-filters" className="mb-3 flex gap-1">
            {FILTERS.map((f) => (
              <button key={f.value} type="button" onClick={() => setFilter(f.value)} aria-pressed={filter === f.value}
                className={`flex items-center gap-1 rounded-full px-3 py-1 text-xs font-extrabold ${filter === f.value ? 'bg-cyan-600 text-white' : 'bg-white text-slate-500 border border-slate-200'}`}>
                {f.label} <span className="tabular-nums opacity-70">{f.n}</span>
              </button>
            ))}
          </div>

          {shown.length === 0 ? (
            <div className="card py-12 text-center text-slate-400">
              {filter === 'past' ? <History className="mx-auto mb-3 h-10 w-10 text-cyan-200" /> : <Tent className="mx-auto mb-3 h-10 w-10 text-cyan-200" />}
              <p className="font-bold">{filter === 'mine' ? 'لم تسجّل في فعالية قادمة بعد' : filter === 'past' ? 'لا فعاليات سابقة' : 'لا توجد فعاليات قادمة الآن'}</p>
              {filter === 'mine' && groups.upcoming.length > 0 && <p className="mt-1 text-xs font-bold">افتح فعالية من «القادمة» واضغط «أنا مشارك»</p>}
            </div>
          ) : (
            <div id="child-occ-list" className="grid gap-3">
              {shown.map((o) => (
                <OccasionCard key={o.id} id={`child-occ-${o.id}`} o={o} href={`/child/occasions/${o.id}`} counts={{ active: o.active_count }}
                  right={o.my_registration && o.my_registration.status !== 'cancelled'
                    ? <RegStatusBadge status={o.my_registration.status} />
                    : o.can_register ? <span className="badge bg-cyan-600 text-white"><Sparkles className="h-3 w-3" /> التسجيل مفتوح</span> : null}
                  footer={o.last_notification && o.last_notification.kind !== 'status' ? (
                    <p className="mt-1.5 truncate rounded-lg bg-amber-50 px-2 py-1 text-[11px] font-bold text-amber-700">📣 {o.last_notification.body}</p>
                  ) : undefined}
                />
              ))}
            </div>
          )}
        </>
      )}
    </>
  );
}
