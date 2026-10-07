// ---------- App timezone: Africa/Cairo ----------
// All "today / now / weekday" logic in the app is computed in Cairo
// time regardless of the device timezone.

import type { AppEvent } from './types';

export const APP_TZ = 'Africa/Cairo';

// ---------- Low-level: current date/time parts in Cairo ----------
interface CairoParts {
  year: number;
  month: number; // 1-12
  day: number; // 1-31
  hour: number; // 0-23
  minute: number;
  second: number;
  weekday: number; // 0 = Sunday .. 6 = Saturday
}

const WEEKDAY_INDEX: Record<string, number> = {
  Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6,
};

export function cairoParts(date: Date = new Date()): CairoParts {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: APP_TZ,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    hour12: false, weekday: 'short',
  });
  const parts: Record<string, string> = {};
  for (const p of fmt.formatToParts(date)) parts[p.type] = p.value;
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour) % 24, // "24" can appear at midnight
    minute: Number(parts.minute),
    second: Number(parts.second),
    weekday: WEEKDAY_INDEX[parts.weekday] ?? 0,
  };
}

// 'YYYY-MM-DD' of today in Cairo
export function cairoToday(date: Date = new Date()): string {
  const p = cairoParts(date);
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`;
}

// 0 = Sunday .. 6 = Saturday (Cairo)
export function cairoWeekday(date: Date = new Date()): number {
  return cairoParts(date).weekday;
}

// 'HH:MM' 24h Cairo
export function cairoTimeHM(date: Date = new Date()): string {
  const p = cairoParts(date);
  return `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`;
}

// ISO instant (UTC) of Cairo midnight today — for .gte('created_at', ...)
export function cairoDayStartISO(date: Date = new Date()): string {
  const p = cairoParts(date);
  // Wall-clock "now" in Cairo expressed as a UTC timestamp:
  const cairoAsUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  // Offset between Cairo wall clock and real UTC at this instant:
  const offsetMs = cairoAsUtc - Math.floor(date.getTime() / 1000) * 1000;
  // Cairo midnight (wall clock) minus the offset = real UTC instant:
  const cairoMidnightUtc = Date.UTC(p.year, p.month - 1, p.day, 0, 0, 0);
  return new Date(cairoMidnightUtc - offsetMs).toISOString();
}

// ---------- Display formatting (Arabic, Cairo) ----------
export function formatCairoDate(date: Date = new Date()): string {
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: APP_TZ,
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  }).format(date);
}

export function formatCairoTime(date: Date = new Date()): string {
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: APP_TZ,
    hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true,
  }).format(date);
}

// format a 'HH:MM[:SS]' time string (Cairo local) for display
export function formatTimeHM(t: string | null | undefined): string {
  if (!t) return '';
  const [h, m] = t.split(':').map(Number);
  const d = new Date(Date.UTC(2000, 0, 1, h, m));
  return new Intl.DateTimeFormat('ar-EG', {
    timeZone: 'UTC', hour: 'numeric', minute: '2-digit', hour12: true,
  }).format(d);
}

// ---------- Weekday labels (0 = Sunday .. 6 = Saturday) ----------
export const WEEKDAY_LABELS: string[] = [
  'الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت',
];

export const WEEKDAY_SHORT: string[] = [
  'أحد', 'اثنين', 'ثلاثاء', 'أربعاء', 'خميس', 'جمعة', 'سبت',
];

// ---------- Event availability (day + time window, Cairo) ----------
export interface EventAvailability {
  ok: boolean;
  reason: string | null; // Arabic message when out of day/time
}

const hm = (t: string) => t.slice(0, 5); // 'HH:MM:SS' -> 'HH:MM'

export function eventAvailability(ev: AppEvent, now: Date = new Date()): EventAvailability {
  const today = cairoToday(now);
  const weekday = cairoWeekday(now);
  const nowHM = cairoTimeHM(now);

  // ----- Day check -----
  if (ev.recurrence === 'once') {
    if (ev.event_date && ev.event_date !== today) {
      return {
        ok: false,
        reason: `اليوم ليس يوم المناسبة — موعدها ${ev.event_date}`,
      };
    }
  } else if (ev.recurrence === 'weekly') {
    const days = ev.weekdays ?? [];
    if (days.length > 0 && !days.includes(weekday)) {
      const names = days.map((d) => WEEKDAY_LABELS[d]).join('، ');
      return {
        ok: false,
        reason: `اليوم ليس من أيام المناسبة — أيامها: ${names}`,
      };
    }
  }

  // ----- Time window check -----
  if (ev.start_time && nowHM < hm(ev.start_time)) {
    return {
      ok: false,
      reason: `لم يحن وقت المناسبة بعد — تبدأ ${formatTimeHM(ev.start_time)}`,
    };
  }
  if (ev.end_time && nowHM > hm(ev.end_time)) {
    return {
      ok: false,
      reason: `انتهى وقت المناسبة — كانت حتى ${formatTimeHM(ev.end_time)}`,
    };
  }

  return { ok: true, reason: null };
}

// ---------- Event phase (for child-card coloring) ----------
// 'wrong_day' -> today is not the event's day
// 'before'    -> event day, but before start_time
// 'during'    -> we are inside the event window (or no window given)
// 'after'     -> event day, after end_time (absent if not attended)
export type EventPhase = 'wrong_day' | 'before' | 'during' | 'after';

export function eventPhase(ev: AppEvent, now: Date = new Date()): EventPhase {
  const today = cairoToday(now);
  const weekday = cairoWeekday(now);
  const nowHM = cairoTimeHM(now);

  if (ev.recurrence === 'once') {
    if (ev.event_date && ev.event_date !== today) return 'wrong_day';
  } else if (ev.recurrence === 'weekly') {
    const days = ev.weekdays ?? [];
    if (days.length > 0 && !days.includes(weekday)) return 'wrong_day';
  }

  if (ev.start_time && nowHM < hm(ev.start_time)) return 'before';
  if (ev.end_time && nowHM > hm(ev.end_time)) return 'after';
  return 'during';
}

// ---------- Event occurrences & per-child status ----------
// The status of a child for an event is always judged against the event's
// CURRENT OCCURRENCE — the latest occurrence that has already started (or
// is about to, on its day):
//
//   once   → the single occurrence on event_date
//   weekly → the most recent weekday in `weekdays` whose start has passed
//            (or today when today is an event day and we're before start).
//
// The occurrence "window" runs from its start_time (or 00:00 when none) to
// its end_time (or 23:59:59 when none), Cairo time.
//
//   present        → attended this occurrence (attended_on = occurrence day)
//   not_registered → didn't attend and we are still INSIDE the occurrence
//                    window (or before it on the event day / upcoming)
//   absent         → didn't attend and the window is over:
//                      once   → any instant after the event's end
//                      weekly → any instant after the end of the last
//                               occurrence until the NEXT occurrence starts
export type ChildEventStatus = 'present' | 'not_registered' | 'absent';

export const CHILD_STATUS_LABELS: Record<ChildEventStatus, string> = {
  present: 'حاضر',
  not_registered: 'لم يُسجَّل',
  absent: 'غائب',
};

export interface EventOccurrence {
  date: string;                          // 'YYYY-MM-DD' Cairo day of the occurrence
  phase: 'upcoming' | 'during' | 'after'; // relative to `now`
}

const ymd = (y: number, m: number, d: number) =>
  `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;

// Cairo day shifted by `deltaDays` (negative = past), as 'YYYY-MM-DD' + weekday
function shiftCairoDay(p: CairoParts, deltaDays: number): { date: string; weekday: number } {
  const t = new Date(Date.UTC(p.year, p.month - 1, p.day + deltaDays));
  return {
    date: ymd(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()),
    weekday: t.getUTCDay(),
  };
}

/** The occurrence the child's status refers to at instant `now` (null when
 *  a once-event has no date at all — legacy rows). */
export function currentOccurrence(ev: AppEvent, now: Date = new Date()): EventOccurrence | null {
  const p = cairoParts(now);
  const today = ymd(p.year, p.month, p.day);
  const nowHM = `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`;
  const startHM = ev.start_time ? hm(ev.start_time) : null;
  const endHM = ev.end_time ? hm(ev.end_time) : null;

  // Phase of an occurrence that happens TODAY
  const todayPhase = (): EventOccurrence['phase'] => {
    if (startHM && nowHM < startHM) return 'upcoming';
    if (endHM && nowHM > endHM) return 'after';
    return 'during';
  };

  if (ev.recurrence === 'once') {
    if (!ev.event_date) return null;
    if (today < ev.event_date) return { date: ev.event_date, phase: 'upcoming' };
    if (today > ev.event_date) return { date: ev.event_date, phase: 'after' };
    return { date: today, phase: todayPhase() };
  }

  // weekly — walk back day by day (max one week) to the latest event day
  const days = ev.weekdays ?? [];
  const isEventDay = (wd: number) => days.length === 0 || days.includes(wd);
  if (isEventDay(p.weekday)) return { date: today, phase: todayPhase() };
  for (let k = 1; k <= 7; k++) {
    const d = shiftCairoDay(p, -k);
    if (isEventDay(d.weekday)) return { date: d.date, phase: 'after' };
  }
  return null;
}

/** The occurrence that came BEFORE the one on `date` (exclusive) — for
 *  weekly events the latest event day strictly before `date` (walks back
 *  ≤ 7 days); once-events have no previous occurrence. Used by the call
 *  follow-up cycle (a cycle runs from one occurrence start to the next). */
export function previousOccurrenceDate(ev: AppEvent, date: string): string | null {
  if (ev.recurrence === 'once') return null;
  const [y, m, d] = date.split('-').map(Number);
  if (!y || !m || !d) return null;
  const days = ev.weekdays ?? [];
  const isEventDay = (wd: number) => days.length === 0 || days.includes(wd);
  for (let k = 1; k <= 7; k++) {
    const t = new Date(Date.UTC(y, m - 1, d - k));
    if (isEventDay(t.getUTCDay())) return ymd(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
  }
  return null;
}

/** Status of one child for `ev` at `now`, given the Cairo days on which he
 *  attended this event. */
export function childEventStatus(
  ev: AppEvent,
  attendedDays: Set<string> | undefined,
  now: Date = new Date()
): { status: ChildEventStatus; occurrence: EventOccurrence | null } {
  const occ = currentOccurrence(ev, now);
  if (!occ) {
    // Undated legacy event: judge by today's attendance only
    const today = cairoToday(now);
    return { status: attendedDays?.has(today) ? 'present' : 'not_registered', occurrence: null };
  }
  if (attendedDays?.has(occ.date)) return { status: 'present', occurrence: occ };
  if (occ.phase === 'after') return { status: 'absent', occurrence: occ };
  return { status: 'not_registered', occurrence: occ };
}

// Human description of an event schedule (for lists / selectors)
export function describeEventSchedule(ev: AppEvent): string {
  const parts: string[] = [];
  if (ev.recurrence === 'once') {
    parts.push(ev.event_date ? `مرة واحدة — ${ev.event_date}` : 'مرة واحدة');
  } else {
    const days = ev.weekdays ?? [];
    if (days.length === 0) parts.push('أسبوعياً');
    else if (days.length === 1) parts.push(`كل ${WEEKDAY_LABELS[days[0]]}`);
    else parts.push(`أيام: ${days.map((d) => WEEKDAY_SHORT[d]).join('، ')}`);
  }
  if (ev.start_time || ev.end_time) {
    const from = ev.start_time ? formatTimeHM(ev.start_time) : '';
    const to = ev.end_time ? formatTimeHM(ev.end_time) : '';
    if (from && to) parts.push(`${from} → ${to}`);
    else if (from) parts.push(`من ${from}`);
    else parts.push(`حتى ${to}`);
  }
  return parts.join(' · ');
}
