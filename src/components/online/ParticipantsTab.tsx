'use client';

// ---------- Participants / attendance tab (control room) ----------
// Every child who entered, evaluated LIVE against the class rules
// (online_class_live_stats): join time, presence %, checks ok / total,
// answers, online dot, computed status (+ manual override) and — after the
// class ended — the final result. Filter present / absent / online, search,
// Excel export.

import { useMemo, useState } from 'react';
import Image from 'next/image';
import { User, Search, Download, Wifi, WifiOff, Clock, ShieldCheck, ListChecks, MessageCircle, Undo2, Loader2, CheckCircle2, XCircle } from 'lucide-react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { fmtTime } from '@/components/online/OnlineBits';
import { setOverride, onlineErrorMessage, fmtSpan, fmtPercent, type LiveStats, type LiveParticipant, type OnlineClass, type AttendanceStatus } from '@/lib/online-classes';

type Filter = 'all' | 'present' | 'absent' | 'online';

export default function ParticipantsTab({
  cls, stats, loading, canWrite, supabase, onChanged, flash,
}: { cls: OnlineClass; stats: LiveStats | null; loading: boolean; canWrite: boolean; supabase: SupabaseClient; onChanged: () => void; flash: (m: string) => void }) {
  const [filter, setFilter] = useState<Filter>('all');
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState<string | null>(null);

  const rows = useMemo(() => {
    const s = search.trim().toLowerCase();
    return (stats?.participants ?? []).filter((p) =>
      (filter === 'all' || (filter === 'online' ? p.online : p.status === filter)) &&
      (!s || p.name.toLowerCase().includes(s) || p.national_id.includes(s)));
  }, [stats, filter, search]);

  const override = async (p: LiveParticipant, status: AttendanceStatus | null) => {
    setBusy(p.participant_id);
    try {
      await setOverride(supabase, p.participant_id, status);
      flash(status === null ? 'عاد الحساب للقواعد' : status === 'present' ? `${p.name}: حاضر (يدوي)` : `${p.name}: غائب (يدوي)`);
      onChanged();
    } catch (e) { flash(onlineErrorMessage(e, 'تعذر التعديل')); } finally { setBusy(null); }
  };

  const exportExcel = async () => {
    if (!stats) return;
    const XLSX = await import('xlsx');
    const data = stats.participants.map((p) => ({
      'الاسم': p.name, 'الرقم القومي': p.national_id, 'الفصل': p.class_name,
      'وقت الدخول': fmtTime(p.first_joined_at), 'آخر ظهور': fmtTime(p.last_seen_at),
      'مدة الحضور': fmtSpan(p.seconds), 'نسبة الحضور ٪': Math.round(Number(p.percent)),
      'فحوص ناجحة': p.checks_ok, 'فحوص متأخرة': p.checks_late, 'فحوص مُرسلة': p.checks_total,
      'إجابات': p.answers_count, 'إجابات صحيحة': p.correct_count, 'رسائل': p.messages_count,
      'مرات الدخول': p.sessions_count,
      'النتيجة': p.status === 'present' ? 'حاضر' : 'غائب',
      'تعديل يدوي': p.override_status ? (p.override_status === 'present' ? 'حاضر' : 'غائب') : '',
    }));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(data.length ? data : [{ '': 'لا توجد بيانات' }]), 'الحضور');
    XLSX.writeFile(wb, `حضور_${cls.title.replace(/[\\/:*?"<>|]/g, '_')}.xlsx`);
  };

  const t = stats?.totals;

  return (
    <div>
      {/* totals */}
      <section className="mb-3 grid grid-cols-5 gap-1.5">
        {[
          { label: 'مستحق', value: t?.eligible ?? '…', tone: 'text-slate-600' },
          { label: 'دخل', value: t?.entered ?? '…', tone: 'text-primary-600' },
          { label: 'متصل', value: t?.online ?? '…', tone: 'text-sky-600' },
          { label: 'حاضر', value: t?.present ?? '…', tone: 'text-emerald-600' },
          { label: 'غائب', value: t?.absent ?? '…', tone: 'text-red-600' },
        ].map((k) => (
          <div key={k.label} className="card !p-2 text-center">
            <p className={`text-base font-extrabold tabular-nums ${k.tone}`}>{k.value}</p>
            <p className="text-[10px] font-bold text-slate-400">{k.label}</p>
          </div>
        ))}
      </section>

      <p className="mb-2 flex items-center gap-1.5 rounded-xl bg-emerald-50 px-3 py-2 text-[11px] font-bold text-emerald-800">
        <ShieldCheck className="h-3.5 w-3.5 shrink-0" />
        القاعدة: {cls.min_time_percent}٪ من الوقت + {cls.checks_min_success} من {cls.checks_required} فحوص{cls.min_answers ? ` + ${cls.min_answers} إجابة` : ''} — أُرسل حتى الآن {stats?.checks_sent ?? 0} فحص.
        {cls.status === 'live' && ' الحالة هنا تقديرية وتتغير حتى «أنهِ الفصل».'}
      </p>

      <div className="mb-2 flex items-center gap-2">
        <div className="relative flex-1">
          <Search className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input id="pt-search" className="input-field pr-9 !py-2 text-sm" placeholder="ابحث بالاسم…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <button type="button" id="pt-export" onClick={exportExcel} disabled={!stats} className="btn-secondary flex items-center gap-1 !py-2 !px-3 text-xs"><Download className="h-4 w-4" /> Excel</button>
      </div>
      <div className="mb-3 flex gap-1.5 overflow-x-auto no-scrollbar">
        {([['all', 'الكل'], ['online', 'متصل الآن'], ['present', 'حاضر'], ['absent', 'غائب']] as [Filter, string][]).map(([k, l]) => (
          <button key={k} type="button" id={`pt-filter-${k}`} onClick={() => setFilter(k)}
            className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-extrabold transition ${filter === k ? 'bg-red-600 text-white' : 'bg-white text-slate-600 ring-1 ring-slate-200'}`}>{l}</button>
        ))}
      </div>

      {loading && !stats ? (
        <div className="flex justify-center py-12"><Loader2 className="h-7 w-7 animate-spin text-red-500" /></div>
      ) : rows.length === 0 ? (
        <div className="card py-10 text-center text-slate-400">
          <User className="mx-auto mb-2 h-8 w-8 text-slate-300" />
          <p className="text-sm font-bold">{(stats?.participants.length ?? 0) === 0 ? 'لم يدخل أحد بعد' : 'لا نتائج'}</p>
        </div>
      ) : (
        <div id="pt-list" className="space-y-2">
          {rows.map((p) => {
            const present = p.status === 'present';
            const need = Math.min(cls.checks_min_success, p.checks_total);
            return (
              <div key={p.participant_id} id={`pt-${p.participant_id}`} className={`card !p-3 ${present ? 'border-emerald-100' : 'border-red-100'}`}>
                <div className="flex items-start gap-3">
                  <div className="relative h-11 w-11 shrink-0 overflow-hidden rounded-xl bg-slate-100">
                    {p.image_url ? <Image src={p.image_url} alt={p.name} fill sizes="44px" className="object-cover" /> : <User className="absolute inset-0 m-auto h-5 w-5 text-slate-400" />}
                    <span className={`absolute bottom-0.5 right-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-white ${p.online ? 'bg-emerald-500' : 'bg-slate-300'}`} />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="truncate font-extrabold">{p.name}</span>
                      <span className={`badge ${present ? 'bg-emerald-100 text-emerald-700' : 'bg-red-100 text-red-600'}`}>
                        {present ? <CheckCircle2 className="h-3 w-3" /> : <XCircle className="h-3 w-3" />} {present ? 'حاضر' : 'غائب'}
                      </span>
                      {p.override_status && <span className="badge bg-amber-100 text-amber-700">يدوي</span>}
                      {p.online ? <span className="badge bg-sky-50 text-sky-700"><Wifi className="h-3 w-3" /> متصل</span> : <span className="badge bg-slate-100 text-slate-500"><WifiOff className="h-3 w-3" /> خرج {fmtTime(p.left_at ?? p.last_seen_at)}</span>}
                    </div>
                    <p className="mt-0.5 text-[11px] font-bold text-slate-400">{p.class_name} · دخل {fmtTime(p.first_joined_at)}{p.sessions_count > 1 ? ` · ${p.sessions_count} مرات` : ''}</p>
                    <div className="mt-2 grid grid-cols-3 gap-1.5 text-center">
                      <Stat icon={Clock} label="الوقت" value={`${fmtPercent(p.percent)} · ${fmtSpan(p.seconds)}`} ok={Number(p.percent) >= cls.min_time_percent} />
                      <Stat icon={ShieldCheck} label="الفحوص" value={`${p.checks_ok} / ${p.checks_total}${p.checks_late ? ` (+${p.checks_late} متأخر)` : ''}`} ok={p.checks_ok >= need} />
                      <Stat icon={ListChecks} label="الإجابات" value={`${p.answers_count}${p.correct_count ? ` · ${p.correct_count} صح` : ''}`} ok={p.answers_count >= cls.min_answers} />
                    </div>
                    {/* presence bar */}
                    <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-slate-100">
                      <div className={`h-full rounded-full transition-all ${Number(p.percent) >= cls.min_time_percent ? 'bg-emerald-500' : 'bg-red-400'}`} style={{ width: `${Math.min(100, Number(p.percent))}%` }} />
                    </div>
                  </div>
                </div>
                {canWrite && (
                  <div className="mt-2 flex items-center justify-end gap-1 border-t border-slate-100 pt-2">
                    {p.messages_count > 0 && <span className="mr-auto badge bg-slate-100 text-slate-500"><MessageCircle className="h-3 w-3" /> {p.messages_count}</span>}
                    {p.override_status ? (
                      <button type="button" disabled={busy === p.participant_id} onClick={() => override(p, null)} className="flex items-center gap-1 rounded-lg px-2 py-1 text-[11px] font-bold text-slate-500 hover:bg-slate-50">
                        {busy === p.participant_id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Undo2 className="h-3.5 w-3.5" />} إلغاء التعديل اليدوي
                      </button>
                    ) : present ? (
                      <button type="button" disabled={busy === p.participant_id} onClick={() => override(p, 'absent')} className="flex items-center gap-1 rounded-lg px-2 py-1 text-[11px] font-bold text-red-600 hover:bg-red-50">
                        {busy === p.participant_id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <XCircle className="h-3.5 w-3.5" />} اعتبره غائباً
                      </button>
                    ) : (
                      <button type="button" disabled={busy === p.participant_id} onClick={() => override(p, 'present')} className="flex items-center gap-1 rounded-lg px-2 py-1 text-[11px] font-bold text-emerald-700 hover:bg-emerald-50">
                        {busy === p.participant_id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <CheckCircle2 className="h-3.5 w-3.5" />} اعتبره حاضراً
                      </button>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function Stat({ icon: Icon, label, value, ok }: { icon: React.ComponentType<{ className?: string }>; label: string; value: string; ok: boolean }) {
  return (
    <div className={`rounded-lg px-1.5 py-1 ${ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>
      <p className="flex items-center justify-center gap-1 text-[10px] font-bold opacity-70"><Icon className="h-3 w-3" /> {label}</p>
      <p className="text-[11px] font-extrabold tabular-nums">{value}</p>
    </div>
  );
}
