'use client';

// ---------- Child portal — الحضور ----------
// Every attendance entry of the child: event, Cairo day, registration
// date & time, points granted, who recorded it. Grouped by day, with a
// per-event filter and totals.

import { useMemo, useState } from 'react';
import { CalendarCheck, Star, Loader2, Clock, User, Layers, Filter } from 'lucide-react';
import ChildShell from '@/components/child/ChildShell';
import { EmptyState, PageTitle, fmtDay, fmtTime, fmtDate, usePortalList } from '@/components/child/ChildBits';
import { useChild } from '@/lib/child-context';
import { createClient } from '@/lib/supabase/client';
import { fetchChildAttendance, sumBy, type ChildAttendanceRow } from '@/lib/child-portal';

export default function ChildAttendancePage() {
  return (
    <ChildShell>
      <AttendanceContent />
    </ChildShell>
  );
}

function AttendanceContent() {
  const { token, profile } = useChild();
  const supabase = useMemo(() => createClient(), []);
  const { rows, error } = usePortalList<ChildAttendanceRow>(
    token ? () => fetchChildAttendance(supabase, token) : null,
    `att-${token}-${profile?.enrollments.map((e) => e.attendance_count).join(',')}`
  );
  const [eventFilter, setEventFilter] = useState<string>('all');

  const events = useMemo(() => {
    const map = new Map<string, string>();
    (rows ?? []).forEach((r) => map.set(r.event_id ?? 'none', r.event_name ?? 'بدون مناسبة'));
    return Array.from(map.entries());
  }, [rows]);

  const visible = useMemo(
    () => (rows ?? []).filter((r) => eventFilter === 'all' || (r.event_id ?? 'none') === eventFilter),
    [rows, eventFilter]
  );

  // group by attended_on (already sorted newest first)
  const groups = useMemo(() => {
    const m = new Map<string, ChildAttendanceRow[]>();
    visible.forEach((r) => {
      const arr = m.get(r.attended_on) ?? [];
      arr.push(r);
      m.set(r.attended_on, arr);
    });
    return Array.from(m.entries());
  }, [visible]);

  const multiEnrollment = (profile?.enrollments.length ?? 0) > 1;

  return (
    <>
      <PageTitle
        icon={<CalendarCheck className="h-5 w-5 text-emerald-600" />}
        title="سجل الحضور"
        sub="كل مرات حضورك — المناسبة واليوم ووقت التسجيل والنقاط"
      />

      {/* Summary */}
      <section className="mb-4 grid grid-cols-3 gap-2">
        <div className="card !p-3 text-center bg-emerald-50 border-emerald-100">
          <p className="text-xl font-extrabold tabular-nums">{rows ? visible.length : '…'}</p>
          <p className="text-[11px] font-bold text-slate-500">مرة حضور</p>
        </div>
        <div className="card !p-3 text-center bg-gold-50 border-gold-100">
          <p className="text-xl font-extrabold tabular-nums">{rows ? sumBy(visible, (r) => r.points_delta) : '…'}</p>
          <p className="text-[11px] font-bold text-slate-500">نقاط الحضور</p>
        </div>
        <div className="card !p-3 text-center">
          <p className="text-xl font-extrabold tabular-nums">{rows ? groups.length : '…'}</p>
          <p className="text-[11px] font-bold text-slate-500">يوم</p>
        </div>
      </section>

      {/* Event filter */}
      {events.length > 1 && (
        <section className="mb-4">
          <label htmlFor="child-att-event-filter" className="mb-1 flex items-center gap-1 text-xs font-bold text-slate-500">
            <Filter className="h-3.5 w-3.5" /> المناسبة
          </label>
          <select
            id="child-att-event-filter"
            className="input-field"
            value={eventFilter}
            onChange={(e) => setEventFilter(e.target.value)}
          >
            <option value="all">كل المناسبات</option>
            {events.map(([id, name]) => (
              <option key={id} value={id}>{name}</option>
            ))}
          </select>
        </section>
      )}

      {error && <p className="mb-3 rounded-xl bg-red-50 px-3 py-2 text-sm font-bold text-red-600">{error}</p>}

      {!rows ? (
        <div className="flex justify-center py-10"><Loader2 className="h-7 w-7 animate-spin text-primary-500" /></div>
      ) : groups.length === 0 ? (
        <EmptyState text="لا يوجد حضور مسجل بعد" />
      ) : (
        <div className="space-y-4">
          {groups.map(([day, list]) => (
            <section key={day}>
              <h3 className="mb-1.5 flex items-center justify-between text-xs font-extrabold text-slate-500">
                <span>{fmtDay(day)}</span>
                <span className="badge bg-emerald-100 text-emerald-700">{list.length}</span>
              </h3>
              <div className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
                {list.map((r) => (
                  <div key={r.id} className="flex items-center gap-3 px-4 py-3">
                    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-emerald-100 text-emerald-600">
                      <CalendarCheck className="h-5 w-5" />
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-extrabold">{r.event_name ?? 'مناسبة'}</p>
                      <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] font-bold text-slate-400">
                        <span className="flex items-center gap-1">
                          <Clock className="h-3 w-3" /> سُجّل {fmtDate(r.created_at)} · {fmtTime(r.created_at)}
                        </span>
                        {r.recorded_by_name && (
                          <span className="flex items-center gap-1"><User className="h-3 w-3" /> {r.recorded_by_name}</span>
                        )}
                        {multiEnrollment && (
                          <span className="flex items-center gap-1"><Layers className="h-3 w-3" /> {r.service_name} · {r.class_name}</span>
                        )}
                      </p>
                    </div>
                    <span className="badge bg-gold-100 text-gold-700 shrink-0">
                      <Star className="h-3 w-3" /> +{r.points_delta}
                    </span>
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      )}
    </>
  );
}
