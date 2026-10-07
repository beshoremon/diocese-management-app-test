'use client';

// ---------- Header date button + working-date modal ----------
// An interactive date pill next to the side-menu button — ALWAYS shows the
// working date. Tapping it opens a polished modal with date + time pickers,
// quick chips (yesterday / today / tomorrow) and a LIVE status preview that
// updates while you change the inputs. Once applied, ALL date-based
// operations (attendance register, availability, "today") use the chosen
// instant until reset back to the live clock.

import { useMemo, useState } from 'react';
import { CalendarDays, X, Clock, RotateCcw, Check, History, Radio, FastForward } from 'lucide-react';
import { useAppDate } from '@/lib/app-date-context';
import { cairoToday, cairoTimeHM, formatCairoDate, formatTimeHM } from '@/lib/time';

// Interpret a picked Cairo wall-clock date+time as a real instant.
// Cairo is UTC+2 (standard) / UTC+3 (DST); probe with +02:00 and adjust.
function cairoWallClockToInstant(dateStr: string, timeStr: string): Date {
  const t = timeStr || '00:00';
  const guess = new Date(`${dateStr}T${t}:00+02:00`);
  const rendered = `${cairoToday(guess)}T${cairoTimeHM(guess)}`;
  const wanted = `${dateStr}T${t}`;
  if (rendered === wanted) return guess;
  const diff = new Date(`${wanted}:00Z`).getTime() - new Date(`${rendered}:00Z`).getTime();
  return new Date(guess.getTime() + diff);
}

const dayShift = (days: number) => new Date(Date.now() + days * 86_400_000);

export default function AppDateButton() {
  const { appDate, isOverridden, setAppDate, now } = useAppDate();
  const [open, setOpen] = useState(false);
  const [dateStr, setDateStr] = useState('');
  const [timeStr, setTimeStr] = useState('');

  const openModal = () => {
    const base = now();
    setDateStr(cairoToday(base));
    setTimeStr(cairoTimeHM(base));
    setOpen(true);
  };

  // ---------- LIVE preview: status recomputes on every input change ----------
  const preview = useMemo(() => {
    if (!dateStr) return null;
    const instant = cairoWallClockToInstant(dateStr, timeStr || '00:00');
    const liveToday = cairoToday(new Date());
    const diffMs = instant.getTime() - Date.now();
    let status: 'live' | 'past' | 'future';
    if (Math.abs(diffMs) < 90_000) status = 'live';
    else status = diffMs < 0 ? 'past' : 'future';
    return {
      instant,
      status,
      isToday: dateStr === liveToday,
      dateLabel: formatCairoDate(instant),
      timeLabel: formatTimeHM(`${timeStr || '00:00'}:00`),
    };
  }, [dateStr, timeStr]);

  const apply = () => {
    if (!preview) return;
    // live == follow the real clock (no frozen override)
    setAppDate(preview.status === 'live' ? null : preview.instant);
    setOpen(false);
  };

  const reset = () => {
    setAppDate(null);
    setOpen(false);
  };

  // Square badge label — day on top, month below (calendar-page style),
  // plus a tiny time line when the date is overridden.
  const pillDate = isOverridden && appDate ? appDate : new Date();
  const [, , pd] = cairoToday(pillDate).split('-');
  const pillMonth = new Intl.DateTimeFormat('ar-EG', {
    month: 'short',
    timeZone: 'Africa/Cairo',
  }).format(pillDate);

  const STATUS_UI = {
    live: { chip: 'bg-emerald-100 text-emerald-700', icon: Radio, label: 'مطابق للساعة الحية — لن يتم تجميد التاريخ' },
    past: { chip: 'bg-amber-100 text-amber-700', icon: History, label: 'تاريخ سابق — سيتم التسجيل بأثر رجعي' },
    future: { chip: 'bg-sky-100 text-sky-700', icon: FastForward, label: 'تاريخ قادم — سيتم التسجيل مقدماً' },
  } as const;

  return (
    <>
      <button
        id="app-date-btn"
        aria-label="تغيير تاريخ العمل"
        onClick={openModal}
        className={`flex h-12 w-12 shrink-0 flex-col items-center justify-center rounded-xl font-extrabold transition active:scale-95 ${
          isOverridden
            ? 'bg-gold-400 text-primary-900 shadow ring-2 ring-gold-200'
            : 'bg-white/15 text-white hover:bg-white/25'
        }`}
      >
        <span className="text-sm tabular-nums leading-none">{pd}</span>
        <span className="mt-0.5 text-[9px] font-bold leading-none opacity-90">{pillMonth}</span>
        {isOverridden && appDate && (
          <span className="mt-0.5 text-[8px] font-bold tabular-nums leading-none opacity-80">
            {cairoTimeHM(appDate)}
          </span>
        )}
      </button>

      {open && (
        <div
          className="fixed inset-0 z-[70] flex items-center justify-center bg-black/50 backdrop-blur-[2px] p-4 sm:p-6"
          onClick={() => setOpen(false)}
        >
          <div
            id="app-date-modal"
            className="w-full max-w-sm max-h-[90dvh] overflow-y-auto rounded-3xl bg-white text-slate-800 shadow-2xl animate-[slideUp_0.25s_ease-out]"
            onClick={(e) => e.stopPropagation()}
          >
            {/* Gradient header with LIVE formatted preview */}
            <div className="bg-gradient-to-l from-primary-700 via-primary-600 to-accent-600 px-5 pb-5 pt-4 text-white">
              <div className="flex items-center justify-between">
                <h3 className="flex items-center gap-2 text-base font-extrabold">
                  <CalendarDays className="h-5 w-5 text-gold-300" />
                  تاريخ العمل
                </h3>
                <button onClick={() => setOpen(false)} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-white/15">
                  <X className="h-5 w-5" />
                </button>
              </div>
              {preview && (
                <div className="mt-3 rounded-2xl bg-white/10 px-4 py-3 ring-1 ring-white/20">
                  <p className="text-sm font-extrabold leading-snug">{preview.dateLabel}</p>
                  <p className="mt-0.5 flex items-center gap-1 text-xs font-bold text-indigo-100">
                    <Clock className="h-3.5 w-3.5" /> {preview.timeLabel}
                  </p>
                </div>
              )}
            </div>

            <div className="p-5">
              {/* LIVE status — changes as the date/time inputs change */}
              {preview && (() => {
                const ui = STATUS_UI[preview.status];
                const Icon = ui.icon;
                return (
                  <div
                    id="app-date-status"
                    className={`mb-4 flex items-center gap-2 rounded-2xl px-3.5 py-2.5 text-xs font-extrabold transition-colors duration-300 ${ui.chip}`}
                  >
                    <Icon className="h-4 w-4 shrink-0" />
                    {ui.label}
                  </div>
                );
              })()}

              {/* Quick day chips */}
              <div className="mb-4 grid grid-cols-3 gap-2">
                {([
                  { label: 'أمس', d: dayShift(-1) },
                  { label: 'اليوم', d: dayShift(0) },
                  { label: 'غدًا', d: dayShift(1) },
                ] as const).map(({ label, d }) => {
                  const v = cairoToday(d);
                  const active = dateStr === v;
                  return (
                    <button
                      key={label}
                      type="button"
                      onClick={() => setDateStr(v)}
                      className={`rounded-xl py-2 text-xs font-extrabold transition active:scale-95 ${
                        active
                          ? 'bg-primary-600 text-white shadow'
                          : 'bg-slate-100 text-slate-500 hover:bg-slate-200'
                      }`}
                    >
                      {label}
                    </button>
                  );
                })}
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-1 block text-xs font-bold text-slate-500">التاريخ</label>
                  <input
                    id="app-date-input"
                    type="date"
                    className="input-field !px-3 tabular-nums"
                    value={dateStr}
                    onChange={(e) => setDateStr(e.target.value)}
                  />
                </div>
                <div>
                  <label className="mb-1 flex items-center gap-1 text-xs font-bold text-slate-500">
                    <Clock className="h-3.5 w-3.5" /> الوقت
                  </label>
                  <input
                    id="app-time-input"
                    type="time"
                    className="input-field !px-3 tabular-nums"
                    value={timeStr}
                    onChange={(e) => setTimeStr(e.target.value)}
                  />
                </div>
              </div>

              {isOverridden && appDate && (
                <p className="mt-3 rounded-xl bg-gold-50 px-3 py-2 text-[11px] font-bold text-gold-700">
                  ⏱ التاريخ المجمّد حالياً: {formatCairoDate(appDate)} — {cairoTimeHM(appDate)}
                </p>
              )}

              <div className="mt-4 flex gap-2">
                {isOverridden && (
                  <button
                    id="app-date-reset"
                    type="button"
                    onClick={reset}
                    className="btn-secondary flex-none flex items-center gap-1.5 !px-4"
                  >
                    <RotateCcw className="h-4 w-4" />
                    الساعة الحية
                  </button>
                )}
                <button
                  id="app-date-apply"
                  type="button"
                  onClick={apply}
                  disabled={!preview}
                  className="btn-primary flex-1 flex items-center justify-center gap-2"
                >
                  <Check className="h-5 w-5" />
                  اعتماد التاريخ
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
