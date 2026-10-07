'use client';

// ---------- Check-in (تسجيل الدخول) ----------
// Camera scanner (ticket QR or the child's card QR) + manual code entry +
// a quick name search fallback. Every scan calls `occasion_checkin` — the
// database decides (ticket / national id → registration → status → points)
// and returns the participant for the big green / amber result card.

import { useMemo, useState } from 'react';
import { Loader2, ScanLine, Search, CheckCircle2, AlertTriangle, Star, Ticket } from 'lucide-react';
import QrScanner from '@/components/store/QrScanner';
import { createClient } from '@/lib/supabase/client';
import { checkinByCode, occasionErrorMessage, fmtTime, type Occasion, type Participant, type CheckinResult } from '@/lib/occasions';
import { PersonAvatar, RegStatusBadge } from '@/components/occasions/OccasionBits';

type Result = { ok: true; r: CheckinResult } | { ok: false; msg: string; code: string };

export default function CheckinTab({ occasion, participants, onCheckedIn, canManage }: {
  occasion: Occasion; participants: Participant[]; onCheckedIn: (r: CheckinResult) => void; canManage: boolean;
}) {
  const [supabase] = useState(() => createClient());
  const [busy, setBusy] = useState(false);
  const [manual, setManual] = useState('');
  const [last, setLast] = useState<Result | null>(null);
  const [history, setHistory] = useState<CheckinResult[]>([]);
  const [search, setSearch] = useState('');

  const handle = async (code: string) => {
    if (busy) return;
    setBusy(true);
    try {
      const r = await checkinByCode(supabase, occasion.id, code);
      setLast({ ok: true, r });
      if (r.result === 'checked_in') { onCheckedIn(r); setHistory((h) => [r, ...h].slice(0, 20)); }
      if (navigator.vibrate) navigator.vibrate(r.result === 'checked_in' ? 80 : [40, 40, 40]);
    } catch (e) {
      setLast({ ok: false, msg: occasionErrorMessage(e, 'تعذر تسجيل الدخول'), code });
      if (navigator.vibrate) navigator.vibrate([60, 40, 60]);
    } finally { setBusy(false); }
  };

  const active = participants.filter((p) => p.status !== 'cancelled');
  const checked = active.filter((p) => p.status === 'checked_in').length;
  const matches = useMemo(() => {
    const s = search.trim().toLowerCase();
    if (!s) return [];
    return active.filter((p) => p.person_name.toLowerCase().includes(s) || p.national_id.includes(s) || p.ticket_code.toLowerCase().includes(s)).slice(0, 8);
  }, [active, search]);

  if (!canManage) return <p className="card text-center text-sm font-bold text-slate-400">ليس لديك صلاحية تسجيل الدخول في هذه الفعالية</p>;

  return (
    <div className="space-y-3">
      <div className="card flex items-center gap-3 !p-3">
        <span className="rounded-xl bg-cyan-600 p-2.5 text-white"><Ticket className="h-6 w-6" /></span>
        <div className="min-w-0 flex-1">
          <p className="text-sm font-extrabold">سجّل الدخول <span className="tabular-nums text-cyan-700">{checked}</span> من <span className="tabular-nums">{active.length}</span></p>
          <div className="mt-1 h-2 w-full overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-cyan-500 transition-all" style={{ width: `${active.length ? Math.round((checked / active.length) * 100) : 0}%` }} /></div>
        </div>
      </div>

      <QrScanner onCode={handle} paused={busy} hint="امسح QR التذكرة أو كارت المخدوم" />

      {last && (
        <div id="occ-checkin-result" className={`card !p-3 ring-2 ${last.ok ? (last.r.result === 'checked_in' ? 'ring-emerald-300 bg-emerald-50/60' : 'ring-amber-300 bg-amber-50/60') : 'ring-red-300 bg-red-50/60'}`}>
          {last.ok ? (
            <div className="flex items-center gap-3">
              <PersonAvatar url={last.r.person_image} name={last.r.person_name} size={56} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-base font-extrabold">{last.r.person_name}</p>
                <p className="truncate text-xs font-bold text-slate-500">{last.r.class_name} · <span dir="ltr" className="font-mono">{last.r.ticket_code}</span></p>
                <p className={`mt-1 flex flex-wrap items-center gap-1 text-sm font-extrabold ${last.r.result === 'checked_in' ? 'text-emerald-700' : 'text-amber-700'}`}>
                  {last.r.result === 'checked_in'
                    ? <><CheckCircle2 className="h-4 w-4" /> تم تسجيل الدخول {last.r.points > 0 && <span className="badge bg-gold-100 text-gold-700"><Star className="h-3 w-3" /> +{last.r.points}</span>}</>
                    : <><AlertTriangle className="h-4 w-4" /> سجّل الدخول من قبل {last.r.checked_in_at ? `· ${fmtTime(last.r.checked_in_at)}` : ''}</>}
                </p>
              </div>
            </div>
          ) : (
            <div className="flex items-center gap-3">
              <span className="rounded-xl bg-red-100 p-2.5 text-red-600"><AlertTriangle className="h-6 w-6" /></span>
              <div className="min-w-0 flex-1">
                <p className="text-sm font-extrabold text-red-700">{last.msg}</p>
                <p className="truncate font-mono text-[11px] text-slate-400" dir="ltr">{last.code}</p>
              </div>
            </div>
          )}
        </div>
      )}

      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (manual.trim()) { handle(manual); setManual(''); } }}>
        <input id="occ-checkin-manual" className="input-field font-mono text-sm" dir="ltr" placeholder="T-XXXXXXXXXX أو الرقم القومي" value={manual} onChange={(e) => setManual(e.target.value)} />
        <button type="submit" disabled={busy || !manual.trim()} aria-label="تسجيل الدخول بالكود" className="btn-primary !from-cyan-600 !to-cyan-500 !px-4 !py-2">
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <ScanLine className="h-4 w-4" />}
        </button>
      </form>

      <div>
        <div className="relative">
          <Search className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input id="occ-checkin-search" className="input-field pr-9 text-sm" placeholder="أو ابحث بالاسم لتسجيل الدخول بدون كود…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        {matches.length > 0 && (
          <div className="card mt-2 !p-0 divide-y divide-indigo-50 overflow-hidden">
            {matches.map((p) => (
              <div key={p.id} className="flex items-center gap-2.5 px-3 py-2">
                <PersonAvatar url={p.person_image} name={p.person_name} size={36} />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-extrabold">{p.person_name}</p>
                  <p className="truncate text-[11px] font-bold text-slate-400">{p.class_name}</p>
                </div>
                {p.status === 'checked_in' ? <RegStatusBadge status={p.status} /> : (
                  <button type="button" disabled={busy} onClick={() => { handle(p.ticket_code); setSearch(''); }} className="rounded-full bg-cyan-600 px-3 py-1.5 text-xs font-extrabold text-white">تسجيل الدخول</button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {history.length > 0 && (
        <div>
          <p className="mb-1 text-xs font-extrabold text-slate-500">آخر من سجّلوا الدخول</p>
          <div id="occ-checkin-history" className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
            {history.map((r) => (
              <div key={r.registration_id + (r.checked_in_at ?? '')} className="flex items-center gap-2.5 px-3 py-2">
                <PersonAvatar url={r.person_image} name={r.person_name} size={32} />
                <p className="min-w-0 flex-1 truncate text-sm font-bold">{r.person_name}</p>
                <span className="text-[11px] font-bold text-slate-400 tabular-nums">{r.checked_in_at ? fmtTime(r.checked_in_at) : ''}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
