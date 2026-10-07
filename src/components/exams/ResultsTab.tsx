'use client';

// ---------- Exam results tab (نتائج المخدومين) ----------
// Every attempt of the exam (realtime): child name + picture, score,
// percent, pass / fail, points granted, duration. Filter ناجح / لم ينجح /
// جارٍ / ملغي, search by name, sort by degree / name / date. Tap a row →
// detail (every question with the child's answer). Servants with write
// scope can cancel an attempt (refund + the child may retake). Excel export.

import { useEffect, useMemo, useState } from 'react';
import {
  Search, Loader2, Trophy, XCircle, Clock, Ban, ArrowUpDown, ChevronDown, FileSpreadsheet, X, Check, Star, Timer, User,
} from 'lucide-react';
import { PersonAvatar } from '@/components/CallFeedback';
import { ScoreRing, fmtDateTime, fmtDuration } from '@/components/exams/ExamBits';
import { createClient } from '@/lib/supabase/client';
import {
  fetchAttemptDetail, cancelAttempt, examErrorMessage, ATTEMPT_STATUS_LABELS, OPTION_LETTERS,
  type Exam, type ExamAttemptWithPerson, type ExamResult,
} from '@/lib/exams';

type Filter = 'all' | 'passed' | 'failed' | 'in_progress' | 'cancelled';
type SortKey = 'score_desc' | 'score_asc' | 'name' | 'date_desc' | 'date_asc';

const SORTS: { key: SortKey; label: string }[] = [
  { key: 'score_desc', label: 'الدرجة (الأعلى أولاً)' },
  { key: 'score_asc', label: 'الدرجة (الأقل أولاً)' },
  { key: 'name', label: 'الاسم (أ → ي)' },
  { key: 'date_desc', label: 'الأحدث أولاً' },
  { key: 'date_asc', label: 'الأقدم أولاً' },
];

export default function ResultsTab({
  exam, attempts, loading, canWrite, className: classNameOf, onChanged,
}: {
  exam: Exam;
  attempts: ExamAttemptWithPerson[];
  loading: boolean;
  canWrite: boolean;
  className: (id: string) => string;
  onChanged: () => void;
}) {
  const [supabase] = useState(() => createClient());
  const [filter, setFilter] = useState<Filter>('all');
  const [sort, setSort] = useState<SortKey>('score_desc');
  const [search, setSearch] = useState('');
  const [detail, setDetail] = useState<ExamAttemptWithPerson | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const flash = (m: string) => { setToast(m); setTimeout(() => setToast(null), 3000); };

  const counts = useMemo(() => ({
    all: attempts.length,
    passed: attempts.filter((a) => a.status === 'submitted' && a.passed).length,
    failed: attempts.filter((a) => a.status === 'submitted' && !a.passed).length,
    in_progress: attempts.filter((a) => a.status === 'in_progress').length,
    cancelled: attempts.filter((a) => a.status === 'cancelled').length,
  }), [attempts]);

  const visible = useMemo(() => {
    const s = search.trim().toLowerCase();
    const rows = attempts.filter((a) => {
      if (filter === 'passed' && !(a.status === 'submitted' && a.passed)) return false;
      if (filter === 'failed' && !(a.status === 'submitted' && !a.passed)) return false;
      if (filter === 'in_progress' && a.status !== 'in_progress') return false;
      if (filter === 'cancelled' && a.status !== 'cancelled') return false;
      if (s && !(a.person?.name ?? '').toLowerCase().includes(s) && !(a.person?.national_id ?? '').includes(s)) return false;
      return true;
    });
    const byName = (a: ExamAttemptWithPerson, b: ExamAttemptWithPerson) => (a.person?.name ?? '').localeCompare(b.person?.name ?? '', 'ar');
    rows.sort((a, b) => {
      switch (sort) {
        case 'score_desc': return Number(b.percent) - Number(a.percent) || Number(b.score) - Number(a.score) || byName(a, b);
        case 'score_asc': return Number(a.percent) - Number(b.percent) || Number(a.score) - Number(b.score) || byName(a, b);
        case 'name': return byName(a, b);
        case 'date_desc': return new Date(b.started_at).getTime() - new Date(a.started_at).getTime();
        case 'date_asc': return new Date(a.started_at).getTime() - new Date(b.started_at).getTime();
      }
    });
    return rows;
  }, [attempts, filter, sort, search]);

  const submitted = attempts.filter((a) => a.status === 'submitted');
  const avg = submitted.length ? Math.round(submitted.reduce((s, a) => s + Number(a.percent), 0) / submitted.length) : null;

  const exportExcel = async () => {
    const XLSX = await import('xlsx');
    const rows = visible.map((a, i) => ({
      '#': i + 1,
      'الاسم': a.person?.name ?? '',
      'الرقم القومي': a.person?.national_id ?? '',
      'الفصل': classNameOf(a.class_id),
      'الحالة': ATTEMPT_STATUS_LABELS[a.status],
      'النتيجة': a.status === 'submitted' ? (a.passed ? (a.full_mark ? 'الدرجة الكاملة' : 'ناجح') : 'لم ينجح') : '',
      'الدرجة': Number(a.score),
      'من': Number(a.max_score),
      'النسبة ٪': Number(a.percent),
      'إجابات صحيحة': a.correct_count,
      'عدد الأسئلة': a.questions_count,
      'انتهى وقتها': a.timed_out_count,
      'النقاط المكتسبة': a.points_granted,
      'المحاولة': a.attempt_no,
      'البداية': fmtDateTime(a.started_at),
      'النهاية': fmtDateTime(a.finished_at),
      'المدة': fmtDuration(a.started_at, a.finished_at),
    }));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows.length ? rows : [{ '': 'لا توجد بيانات' }]), 'النتائج');
    XLSX.writeFile(wb, `نتائج_${exam.title.replace(/[\\/:*?"<>|]/g, '_')}.xlsx`);
  };

  return (
    <>
      {/* summary */}
      <section className="mb-3 grid grid-cols-4 gap-2">
        <div className="card !p-2 text-center"><p className="text-lg font-extrabold tabular-nums text-primary-600">{submitted.length}</p><p className="text-[10px] font-bold text-slate-400">أكمل الامتحان</p></div>
        <div className="card !p-2 text-center"><p className="text-lg font-extrabold tabular-nums text-emerald-600">{counts.passed}</p><p className="text-[10px] font-bold text-slate-400">ناجح</p></div>
        <div className="card !p-2 text-center"><p className="text-lg font-extrabold tabular-nums text-red-500">{counts.failed}</p><p className="text-[10px] font-bold text-slate-400">لم ينجح</p></div>
        <div className="card !p-2 text-center"><p className="text-lg font-extrabold tabular-nums text-violet-600">{avg === null ? '—' : `${avg}٪`}</p><p className="text-[10px] font-bold text-slate-400">متوسط النسبة</p></div>
      </section>

      <div className="relative mb-2">
        <Search className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
        <input id="results-search" className="input-field pr-9" placeholder="ابحث بالاسم أو الرقم القومي…" value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>

      <div className="mb-2 flex gap-1.5 overflow-x-auto no-scrollbar">
        {([
          ['all', 'الكل'], ['passed', 'ناجح'], ['failed', 'لم ينجح'], ['in_progress', 'جارٍ الحل'], ['cancelled', 'ملغي'],
        ] as [Filter, string][]).map(([k, label]) => (
          <button key={k} type="button" id={`results-filter-${k}`} onClick={() => setFilter(k)}
            className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-extrabold transition ${filter === k ? 'bg-violet-600 text-white' : 'bg-white text-slate-600 ring-1 ring-slate-200'}`}>
            {label} <span className="opacity-70 tabular-nums">({counts[k]})</span>
          </button>
        ))}
      </div>

      <div className="mb-3 flex items-center gap-2">
        <div className="relative flex-1">
          <ArrowUpDown className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <select id="results-sort" className="input-field appearance-none !py-2 pr-9 text-xs font-bold" value={sort} onChange={(e) => setSort(e.target.value as SortKey)}>
            {SORTS.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select>
          <ChevronDown className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
        </div>
        <button id="results-export" type="button" onClick={exportExcel} disabled={visible.length === 0} className="btn-secondary flex items-center gap-1.5 !py-2 !px-3 text-xs disabled:opacity-40">
          <FileSpreadsheet className="h-4 w-4" /> Excel
        </button>
      </div>

      {loading ? (
        <div className="flex justify-center py-16"><Loader2 className="h-8 w-8 animate-spin text-violet-500" /></div>
      ) : visible.length === 0 ? (
        <div className="card py-12 text-center text-slate-400">
          <User className="mx-auto mb-3 h-10 w-10 text-violet-200" />
          <p className="font-bold">{attempts.length === 0 ? 'لم يحل أحد الامتحان بعد' : 'لا نتائج للفلتر الحالي'}</p>
        </div>
      ) : (
        <div id="results-list" className="card !p-0 divide-y divide-violet-50 overflow-hidden">
          {visible.map((a, i) => {
            const done = a.status === 'submitted';
            return (
              <button key={a.id} id={`result-row-${a.id}`} type="button" onClick={() => setDetail(a)}
                className="flex w-full items-center gap-3 px-3 py-3 text-start transition hover:bg-violet-50/40">
                <span className="w-5 shrink-0 text-center text-[11px] font-extrabold tabular-nums text-slate-400">{i + 1}</span>
                <PersonAvatar name={a.person?.name ?? ''} imageUrl={a.person?.image_url ?? null} size={44} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-extrabold">{a.person?.name ?? '—'}</span>
                  <span className="block truncate text-[11px] font-bold text-slate-400">{classNameOf(a.class_id)} · {fmtDateTime(a.started_at)}</span>
                  <span className="mt-1 flex flex-wrap items-center gap-1.5">
                    {a.status === 'in_progress' && <span className="badge bg-amber-100 text-amber-700"><Timer className="h-3 w-3" /> جارٍ الحل · سؤال {a.current_index + 1}/{a.questions_count}</span>}
                    {a.status === 'cancelled' && <span className="badge bg-slate-200 text-slate-600"><Ban className="h-3 w-3" /> ملغي</span>}
                    {done && (a.passed
                      ? <span className={`badge ${a.full_mark ? 'bg-gold-100 text-gold-700' : 'bg-emerald-100 text-emerald-700'}`}><Trophy className="h-3 w-3" /> {a.full_mark ? 'الدرجة الكاملة' : 'ناجح'}</span>
                      : <span className="badge bg-red-100 text-red-600"><XCircle className="h-3 w-3" /> لم ينجح</span>)}
                    {done && <span className="badge bg-slate-100 text-slate-600">{Number(a.score)} / {Number(a.max_score)}</span>}
                    {done && a.points_granted > 0 && <span className="badge bg-gold-100 text-gold-700"><Star className="h-3 w-3" /> +{a.points_granted}</span>}
                    {done && a.timed_out_count > 0 && <span className="badge bg-orange-100 text-orange-700"><Clock className="h-3 w-3" /> {a.timed_out_count} انتهى وقته</span>}
                  </span>
                </span>
                {done && <ScoreRing percent={Number(a.percent)} size={48} stroke={5} />}
              </button>
            );
          })}
        </div>
      )}

      {detail && (
        <AttemptDetailModal
          attempt={detail} exam={exam} canWrite={canWrite}
          onClose={() => setDetail(null)}
          onCancelled={() => { setDetail(null); onChanged(); }}
          flash={flash}
        />
      )}
      {toast && (
        <div role="status" className="fixed inset-x-4 bottom-24 z-[70] mx-auto max-w-md rounded-2xl bg-slate-900 px-4 py-3 text-center text-sm font-bold text-white shadow-xl">{toast}</div>
      )}
    </>
  );
}

// ---------- detail modal ----------
function AttemptDetailModal({
  attempt, exam, canWrite, onClose, onCancelled, flash,
}: {
  attempt: ExamAttemptWithPerson; exam: Exam; canWrite: boolean;
  onClose: () => void; onCancelled: () => void; flash: (m: string) => void;
}) {
  const [supabase] = useState(() => createClient());
  const [res, setRes] = useState<ExamResult | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetchAttemptDetail(supabase, attempt.id)
      .then((r) => { if (!cancelled) setRes(r); })
      .catch((e) => { if (!cancelled) setErr(examErrorMessage(e, 'تعذر تحميل التفاصيل')); });
    return () => { cancelled = true; };
  }, [supabase, attempt.id]);

  const cancel = async () => {
    const msg = attempt.status === 'submitted'
      ? `إلغاء محاولة «${attempt.person?.name}»؟\n${attempt.points_granted > 0 ? `سيتم خصم ${attempt.points_granted} نقطة كانت قد أُضيفت، و` : ''}يمكنه حل الامتحان مرة أخرى.`
      : `إلغاء المحاولة الجارية لـ «${attempt.person?.name}»؟ يمكنه البدء من جديد.`;
    if (!confirm(msg)) return;
    setBusy(true);
    try {
      await cancelAttempt(supabase, attempt.id);
      flash('تم إلغاء المحاولة');
      onCancelled();
    } catch (e) {
      flash(examErrorMessage(e, 'تعذر الإلغاء'));
    } finally {
      setBusy(false);
    }
  };

  const done = attempt.status === 'submitted';

  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/50 backdrop-blur-[2px] sm:items-center" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-t-3xl bg-white shadow-2xl sm:rounded-3xl" style={{ animation: 'slideUp .25s ease-out' }}>
        <div className="sticky top-0 z-10 flex items-center gap-3 border-b border-violet-50 bg-white px-4 py-3">
          <PersonAvatar name={attempt.person?.name ?? ''} imageUrl={attempt.person?.image_url ?? null} size={44} />
          <div className="min-w-0 flex-1">
            <p className="truncate font-extrabold">{attempt.person?.name}</p>
            <p className="truncate text-[11px] font-bold text-slate-400">{exam.title} · المحاولة {attempt.attempt_no}</p>
          </div>
          {done && <ScoreRing percent={Number(attempt.percent)} size={52} stroke={5} />}
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        <div className="p-4">
          <div className="grid grid-cols-3 gap-2 text-center">
            <div className="rounded-xl bg-slate-50 p-2"><p className="text-base font-extrabold tabular-nums">{Number(attempt.score)}<span className="text-xs text-slate-400"> / {Number(attempt.max_score)}</span></p><p className="text-[10px] font-bold text-slate-400">الدرجة</p></div>
            <div className="rounded-xl bg-slate-50 p-2"><p className="text-base font-extrabold tabular-nums">{attempt.correct_count}<span className="text-xs text-slate-400"> / {attempt.questions_count}</span></p><p className="text-[10px] font-bold text-slate-400">إجابة صحيحة</p></div>
            <div className="rounded-xl bg-slate-50 p-2"><p className="text-base font-extrabold tabular-nums">{fmtDuration(attempt.started_at, attempt.finished_at)}</p><p className="text-[10px] font-bold text-slate-400">المدة</p></div>
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs">
            <span className={`badge ${attempt.status === 'submitted' ? (attempt.passed ? 'bg-emerald-100 text-emerald-700' : 'bg-red-100 text-red-600') : 'bg-slate-200 text-slate-600'}`}>
              {attempt.status === 'submitted' ? (attempt.full_mark ? 'الدرجة الكاملة' : attempt.passed ? 'ناجح' : 'لم ينجح') : ATTEMPT_STATUS_LABELS[attempt.status]}
            </span>
            {attempt.points_granted > 0 && <span className="badge bg-gold-100 text-gold-700"><Star className="h-3 w-3" /> +{attempt.points_granted} نقطة</span>}
            {attempt.timed_out_count > 0 && <span className="badge bg-orange-100 text-orange-700"><Clock className="h-3 w-3" /> {attempt.timed_out_count} انتهى وقته</span>}
            <span className="text-slate-400">{fmtDateTime(attempt.started_at)}</span>
            {attempt.cancel_note && <span className="text-slate-400">· {attempt.cancel_note}</span>}
          </div>

          {/* answers */}
          <div className="mt-4">
            <p className="mb-2 text-xs font-extrabold text-slate-600">الأسئلة والإجابات</p>
            {err && <p className="rounded-xl bg-red-50 px-3 py-2 text-xs font-bold text-red-600">{err}</p>}
            {!res && !err && <div className="flex justify-center py-6"><Loader2 className="h-6 w-6 animate-spin text-violet-500" /></div>}
            {res?.answers && (
              <div className="space-y-2">
                {res.answers.map((an) => {
                  const answered = an.selected_index !== null;
                  return (
                    <div key={an.position} className={`rounded-2xl p-3 ring-1 ${an.is_correct ? 'bg-emerald-50/60 ring-emerald-100' : answered ? 'bg-red-50/60 ring-red-100' : 'bg-slate-50 ring-slate-200'}`}>
                      <div className="flex items-start gap-2">
                        <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-lg bg-white text-[11px] font-extrabold tabular-nums ring-1 ring-slate-200">{an.position + 1}</span>
                        <p className="flex-1 text-sm font-bold leading-snug">{an.text}</p>
                        <span className="badge bg-white ring-1 ring-slate-200 tabular-nums">{Number(an.points_earned)}/{an.points}</span>
                      </div>
                      <div className="mt-2 space-y-1">
                        {an.options.map((o, i) => {
                          const isC = i === an.correct_index;
                          const isS = i === an.selected_index;
                          return (
                            <div key={i} className={`flex items-center gap-2 rounded-lg px-2 py-1 text-xs font-bold ${isC ? 'bg-emerald-100 text-emerald-800' : isS ? 'bg-red-100 text-red-700' : 'text-slate-500'}`}>
                              <span className="w-5 shrink-0 text-center">{OPTION_LETTERS[i]}</span>
                              <span className="flex-1">{o}</span>
                              {isC && <Check className="h-3.5 w-3.5" />}
                              {isS && !isC && <X className="h-3.5 w-3.5" />}
                            </div>
                          );
                        })}
                      </div>
                      <p className="mt-1.5 flex items-center gap-2 text-[10px] font-bold text-slate-400">
                        {an.timed_out ? <span className="text-orange-600">⏱ انتهى الوقت بدون إجابة</span> : !answered ? 'بدون إجابة' : an.is_correct ? 'إجابة صحيحة' : 'إجابة خاطئة'}
                        {an.time_spent_ms !== null && <span>· {Math.round(an.time_spent_ms / 1000)} ث</span>}
                      </p>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {canWrite && attempt.status !== 'cancelled' && (
            <button id="attempt-cancel" type="button" disabled={busy} onClick={cancel}
              className="mt-4 flex w-full items-center justify-center gap-2 rounded-xl bg-red-50 px-4 py-3 text-sm font-extrabold text-red-600 hover:bg-red-100 disabled:opacity-50">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Ban className="h-4 w-4" />}
              إلغاء المحاولة {attempt.points_granted > 0 ? `(واسترداد ${attempt.points_granted} نقطة)` : ''} — يسمح بإعادة الامتحان
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
