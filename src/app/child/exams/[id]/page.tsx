'use client';

// ---------- Child portal — EXAM PLAYER (حل الامتحان) ----------
// Flow: intro → start (RPC picks + snapshots the questions) → one question
// at a time with a countdown → «التالي» (or auto when the clock hits 0)
// → next question … → result screen.
//
// The countdown is anchored on the SERVER deadline (deadline_at) with the
// client/server clock offset (server_now) — so changing the phone's clock
// does not give more time, and a reload resumes with the right remaining
// seconds. The server re-checks the deadline on every answer (+3 s grace);
// a late answer counts as timed-out. Going back is impossible by design
// (the RPC only accepts the current position).

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Image from 'next/image';
import Link from 'next/link';
import { useParams, useRouter, useSearchParams } from 'next/navigation';
import {
  GraduationCap, Play, Loader2, ChevronLeft, Clock, ListChecks, Trophy, Star, CheckCircle2, XCircle, Check, X,
  ArrowRight, Timer, AlertTriangle, RotateCcw, Home, Sparkles, Info,
} from 'lucide-react';
import ChildShell from '@/components/child/ChildShell';
import { ScoreRing } from '@/components/exams/ExamBits';
import { useChild } from '@/lib/child-context';
import { createClient } from '@/lib/supabase/client';
import {
  fetchChildExams, startChildExam, currentChildExamStep, answerChildExam, fetchChildExamResult, childErrorMessage,
  type ChildExam, type ChildExamQuestion, type ChildExamStep,
} from '@/lib/child-portal';
import { fmtSeconds, passLabel, OPTION_LETTERS, type ExamResult } from '@/lib/exams';

type Phase = 'loading' | 'intro' | 'question' | 'submitting' | 'result' | 'error';

export default function ChildExamPlayerPage() {
  return (
    <ChildShell>
      <Player />
    </ChildShell>
  );
}

function Player() {
  const { id } = useParams<{ id: string }>();
  const search = useSearchParams();
  const router = useRouter();
  const { token, refresh } = useChild();
  const supabase = useMemo(() => createClient(), []);

  const [exam, setExam] = useState<ChildExam | null>(null);
  const [phase, setPhase] = useState<Phase>('loading');
  const [attemptId, setAttemptId] = useState<string | null>(null);
  const [question, setQuestion] = useState<ChildExamQuestion | null>(null);
  const [result, setResult] = useState<ExamResult | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [error, setError] = useState('');
  const [clockOffset, setClockOffset] = useState(0);      // serverNow - clientNow (ms)
  const [remaining, setRemaining] = useState(0);          // seconds left for the current question
  const submittingRef = useRef(false);

  // ---------- apply a step returned by the RPCs ----------
  const applyStep = useCallback((step: ChildExamStep) => {
    setAttemptId(step.attempt_id);
    if (step.finished && step.result) {
      setResult(step.result);
      setQuestion(null);
      setPhase('result');
      refresh(); // points badge in the header / home
      return;
    }
    if (step.question) {
      const q = step.question;
      setClockOffset(new Date(q.server_now).getTime() - Date.now());
      setQuestion(q);
      setSelected(null);
      setPhase('question');
    }
  }, [refresh]);

  // ---------- boot: load the exam card + resume / show result ----------
  useEffect(() => {
    if (!token) return;
    let cancelled = false;
    (async () => {
      try {
        const list = await fetchChildExams(supabase, token);
        const x = list.find((e) => e.id === id) ?? null;
        if (cancelled) return;
        if (!x) { setError('الامتحان غير موجود أو غير متاح لك'); setPhase('error'); return; }
        setExam(x);
        const viewResult = search.get('view') === 'result';
        const att = search.get('attempt');
        if (viewResult && att) {
          const r = await fetchChildExamResult(supabase, token, att);
          if (cancelled) return;
          setAttemptId(att); setResult(r); setPhase('result');
          return;
        }
        if (x.open_attempt_id) {
          // resume straight away — the clock is already running
          const step = await currentChildExamStep(supabase, token, x.open_attempt_id);
          if (cancelled) return;
          applyStep(step);
          return;
        }
        setPhase('intro');
      } catch (e) {
        if (!cancelled) { setError(childErrorMessage(e)); setPhase('error'); }
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, id, supabase]);

  // ---------- start ----------
  const start = async () => {
    if (!token) return;
    setPhase('loading');
    try {
      applyStep(await startChildExam(supabase, token, id));
    } catch (e) {
      setError(childErrorMessage(e)); setPhase('error');
    }
  };

  // ---------- submit the current answer (or a timeout) ----------
  const submit = useCallback(async (sel: number | null) => {
    if (!token || !attemptId || !question || submittingRef.current) return;
    submittingRef.current = true;
    setPhase('submitting');
    try {
      applyStep(await answerChildExam(supabase, token, attemptId, question.position, sel));
    } catch (e) {
      // network hiccup: re-sync with the server instead of losing the attempt
      try { applyStep(await currentChildExamStep(supabase, token, attemptId)); }
      catch (e2) { setError(childErrorMessage(e2)); setPhase('error'); }
      void e;
    } finally {
      submittingRef.current = false;
    }
  }, [token, attemptId, question, supabase, applyStep]);

  // ---------- countdown anchored on the server deadline ----------
  useEffect(() => {
    if (phase !== 'question' || !question) return;
    const deadline = new Date(question.deadline_at).getTime();
    const tick = () => {
      const now = Date.now() + clockOffset;
      const left = Math.max(0, Math.ceil((deadline - now) / 1000));
      setRemaining(left);
      if (left <= 0) submit(selectedRef.current);   // auto-advance when the time is up
    };
    tick();
    const t = setInterval(tick, 250);
    return () => clearInterval(t);
  }, [phase, question, clockOffset, submit]);

  // keep the latest selection reachable from the timer without re-creating it
  const selectedRef = useRef<number | null>(null);
  useEffect(() => { selectedRef.current = selected; }, [selected]);

  // re-sync when the tab comes back (phone locked mid-question)
  useEffect(() => {
    if (!token || !attemptId || phase !== 'question') return;
    const onVis = async () => {
      if (document.visibilityState !== 'visible' || submittingRef.current) return;
      try { applyStep(await currentChildExamStep(supabase, token, attemptId)); } catch { /* ignore */ }
    };
    document.addEventListener('visibilitychange', onVis);
    return () => document.removeEventListener('visibilitychange', onVis);
  }, [token, attemptId, phase, supabase, applyStep]);

  // ---------- render ----------
  if (phase === 'loading') {
    return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-violet-500" /></div>;
  }

  if (phase === 'error') {
    return (
      <div className="card py-10 text-center">
        <AlertTriangle className="mx-auto mb-2 h-8 w-8 text-red-400" />
        <p className="font-bold text-red-600">{error}</p>
        <Link href="/child/exams" className="btn-secondary mt-4 inline-flex items-center gap-1 !py-2 !px-4 text-sm"><ArrowRight className="h-4 w-4" /> رجوع للامتحانات</Link>
      </div>
    );
  }

  if (phase === 'intro' && exam) {
    const attemptsLeft = Math.max(0, exam.max_attempts - exam.attempts_used);
    return (
      <div id="exam-intro" className="card !p-0 overflow-hidden">
        <div className="bg-gradient-to-l from-violet-700 to-primary-600 px-5 pt-6 pb-8 text-white">
          <GraduationCap className="mb-2 h-9 w-9" />
          <h2 className="text-xl font-extrabold leading-tight">{exam.title}</h2>
          <p className="mt-1 text-xs text-violet-100">{exam.service_name} · {exam.class_name}</p>
        </div>
        <div className="-mt-4 mx-4 rounded-2xl bg-white p-3 shadow-card ring-1 ring-violet-50">
          <div className="grid grid-cols-3 gap-2 text-center">
            <div><p className="text-lg font-extrabold tabular-nums text-violet-600">{exam.served_questions}</p><p className="text-[10px] font-bold text-slate-400">سؤال</p></div>
            <div><p className="text-lg font-extrabold tabular-nums text-violet-600">{fmtSeconds(exam.default_seconds)}</p><p className="text-[10px] font-bold text-slate-400">لكل سؤال</p></div>
            <div><p className="text-lg font-extrabold tabular-nums text-violet-600">{passLabel(exam)}</p><p className="text-[10px] font-bold text-slate-400">للنجاح</p></div>
          </div>
        </div>
        <div className="p-4">
          {exam.description && <p className="mb-3 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-600">{exam.description}</p>}
          <ul className="space-y-2 text-xs font-bold text-slate-600">
            <li className="flex items-start gap-2"><Timer className="mt-0.5 h-4 w-4 shrink-0 text-violet-500" /> يظهر سؤال واحد كل مرة ومعه عدّاد؛ عند انتهاء الوقت ينتقل للسؤال التالي تلقائياً.</li>
            <li className="flex items-start gap-2"><ChevronLeft className="mt-0.5 h-4 w-4 shrink-0 text-violet-500" /> اختر إجابتك ثم اضغط «التالي» — لا يمكن الرجوع للسؤال السابق.</li>
            {(exam.points_pass > 0 || exam.points_full > 0) && (
              <li className="flex items-start gap-2"><Star className="mt-0.5 h-4 w-4 shrink-0 text-gold-500" />
                {exam.points_pass > 0 && <>النجاح يضيف <b>{exam.points_pass}</b> نقطة لرصيدك</>}
                {exam.points_full > 0 && <>{exam.points_pass > 0 ? ' — و' : ''}الدرجة الكاملة تضيف <b>{exam.points_full}</b> نقطة</>}
              </li>
            )}
            <li className="flex items-start gap-2"><Info className="mt-0.5 h-4 w-4 shrink-0 text-violet-500" /> لديك {attemptsLeft} محاولة{exam.max_attempts > 1 ? ` من ${exam.max_attempts}` : ''}. إذا أُغلق التطبيق يستمر الوقت ويمكنك المتابعة.</li>
          </ul>
          <button id="exam-start-btn" type="button" onClick={start} disabled={attemptsLeft === 0 || exam.total_questions === 0}
            className="btn-primary mt-4 flex w-full items-center justify-center gap-2 !from-violet-600 !to-violet-500 text-base">
            <Play className="h-5 w-5" /> ابدأ الامتحان
          </button>
          <Link href="/child/exams" className="mt-2 block text-center text-xs font-bold text-slate-400">رجوع</Link>
        </div>
      </div>
    );
  }

  if ((phase === 'question' || phase === 'submitting') && question) {
    const total = question.total;
    const pct = question.seconds > 0 ? (remaining / question.seconds) * 100 : 0;
    const urgent = remaining <= 5;
    const busy = phase === 'submitting';
    return (
      <div id="exam-question" className="select-none">
        {/* progress + timer */}
        <div className="mb-3 flex items-center gap-3">
          <div className="flex-1">
            <div className="mb-1 flex items-center justify-between text-[11px] font-extrabold text-slate-500">
              <span>سؤال {question.position + 1} من {total}</span>
              <span className="flex items-center gap-1 text-gold-600"><Star className="h-3 w-3" /> {question.points} درجة</span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-slate-200">
              <div className="h-full rounded-full bg-violet-600 transition-all" style={{ width: `${((question.position + 1) / total) * 100}%` }} />
            </div>
          </div>
          <div className={`relative flex h-16 w-16 shrink-0 items-center justify-center ${urgent ? 'animate-pulse' : ''}`} aria-live="polite" aria-label={`الوقت المتبقي ${remaining} ثانية`}>
            <svg className="absolute inset-0 -rotate-90" viewBox="0 0 64 64">
              <circle cx="32" cy="32" r="28" stroke="#e2e8f0" strokeWidth="6" fill="none" />
              <circle cx="32" cy="32" r="28" stroke={urgent ? '#dc2626' : remaining <= question.seconds / 3 ? '#f59e0b' : '#7c3aed'} strokeWidth="6" fill="none"
                strokeLinecap="round" strokeDasharray={2 * Math.PI * 28} strokeDashoffset={2 * Math.PI * 28 * (1 - pct / 100)} className="transition-[stroke-dashoffset] duration-200" />
            </svg>
            <span className={`text-lg font-extrabold tabular-nums ${urgent ? 'text-red-600' : 'text-slate-700'}`}>{remaining}</span>
          </div>
        </div>

        {/* question */}
        <div className="card mb-3">
          <p className="text-base font-extrabold leading-relaxed">{question.text}</p>
          {question.image_url && (
            <div className="relative mt-3 h-48 w-full overflow-hidden rounded-xl bg-slate-100">
              <Image src={question.image_url} alt="" fill sizes="600px" className="object-contain" priority />
            </div>
          )}
        </div>

        {/* options */}
        <div className="space-y-2">
          {question.options.map((o, i) => {
            const on = selected === i;
            return (
              <button key={i} id={`exam-opt-${i}`} type="button" disabled={busy} onClick={() => setSelected(i)} aria-pressed={on}
                className={`flex w-full items-center gap-3 rounded-2xl border-2 px-3 py-3 text-start transition active:scale-[0.99] ${on ? 'border-violet-600 bg-violet-50 shadow-md' : 'border-slate-200 bg-white hover:border-violet-300'}`}>
                <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-xl text-sm font-extrabold ${on ? 'bg-violet-600 text-white' : 'bg-slate-100 text-slate-600'}`}>
                  {on ? <Check className="h-5 w-5" /> : OPTION_LETTERS[i]}
                </span>
                <span className="flex-1 text-sm font-bold leading-snug">{o}</span>
              </button>
            );
          })}
        </div>

        <button id="exam-next" type="button" disabled={busy || selected === null} onClick={() => submit(selected)}
          className="btn-primary mt-4 flex w-full items-center justify-center gap-2 !from-violet-600 !to-violet-500 text-base disabled:opacity-40">
          {busy ? <Loader2 className="h-5 w-5 animate-spin" /> : <>{question.position + 1 === total ? 'إنهاء الامتحان' : 'التالي'} <ChevronLeft className="h-5 w-5" /></>}
        </button>
        <p className="mt-2 text-center text-[11px] font-bold text-slate-400">
          {selected === null ? 'اختر إجابة — أو ينتقل السؤال تلقائياً عند انتهاء الوقت' : 'لا يمكن الرجوع بعد الضغط على التالي'}
        </p>
      </div>
    );
  }

  if (phase === 'result' && result) {
    return <ResultScreen result={result} exam={exam} onRetry={() => { router.replace(`/child/exams/${id}`); setResult(null); setPhase('intro'); }} />;
  }

  return null;
}

// ---------- result screen ----------
function ResultScreen({ result: r, exam, onRetry }: { result: ExamResult; exam: ChildExam | null; onRetry: () => void }) {
  const show = r.show_result && r.percent !== undefined;
  const passed = !!r.passed;
  const full = !!r.full_mark;
  const attemptsLeft = exam ? Math.max(0, exam.max_attempts - (exam.attempts_used + (exam.open_attempt_id ? 1 : 0))) : 0;
  const canRetry = !!exam && exam.is_open && attemptsLeft > 0 && !passed;

  return (
    <div id="exam-result">
      <div className={`card !p-0 overflow-hidden text-center ${!show ? '' : full ? 'ring-2 ring-gold-300' : passed ? 'ring-2 ring-emerald-200' : 'ring-2 ring-red-100'}`}>
        <div className={`px-5 pt-6 pb-8 text-white ${!show ? 'bg-gradient-to-l from-slate-600 to-slate-500' : full ? 'bg-gradient-to-l from-amber-500 to-gold-500' : passed ? 'bg-gradient-to-l from-emerald-600 to-teal-500' : 'bg-gradient-to-l from-rose-600 to-red-500'}`}>
          {!show ? <CheckCircle2 className="mx-auto mb-2 h-10 w-10" /> : full ? <Sparkles className="mx-auto mb-2 h-10 w-10" /> : passed ? <Trophy className="mx-auto mb-2 h-10 w-10" /> : <XCircle className="mx-auto mb-2 h-10 w-10" />}
          <h2 className="text-2xl font-extrabold">{!show ? 'أكملت الامتحان' : full ? 'الدرجة الكاملة! 🎉' : passed ? 'مبروك — نجحت!' : 'لم تنجح هذه المرة'}</h2>
          <p className="mt-1 text-sm opacity-90">{r.exam_title}</p>
        </div>
        {show && (
          <div className="-mt-6 flex justify-center"><div className="rounded-full bg-white p-1.5 shadow-lg"><ScoreRing percent={Number(r.percent)} size={92} stroke={8} tone={full ? '#d97706' : passed ? '#059669' : '#dc2626'} /></div></div>
        )}
        <div className="p-4">
          {show ? (
            <>
              <div className="grid grid-cols-3 gap-2 text-center">
                <div className="rounded-xl bg-slate-50 p-2"><p className="text-lg font-extrabold tabular-nums">{Number(r.score)}<span className="text-xs text-slate-400"> / {Number(r.max_score)}</span></p><p className="text-[10px] font-bold text-slate-400">الدرجة</p></div>
                <div className="rounded-xl bg-slate-50 p-2"><p className="text-lg font-extrabold tabular-nums">{r.correct_count}<span className="text-xs text-slate-400"> / {r.questions_count}</span></p><p className="text-[10px] font-bold text-slate-400">إجابة صحيحة</p></div>
                <div className="rounded-xl bg-slate-50 p-2"><p className="text-lg font-extrabold tabular-nums">{passLabel({ pass_mode: r.pass_mode!, pass_value: r.pass_value! })}</p><p className="text-[10px] font-bold text-slate-400">حد النجاح</p></div>
              </div>
              {(r.points_granted ?? 0) > 0 && (
                <p className="mt-3 flex items-center justify-center gap-2 rounded-xl bg-gold-100 px-3 py-2 text-sm font-extrabold text-gold-700">
                  <Star className="h-4 w-4" /> أُضيفت {r.points_granted} نقطة إلى رصيدك
                </p>
              )}
              {r.timed_out_count > 0 && (
                <p className="mt-2 flex items-center justify-center gap-1 text-xs font-bold text-orange-600"><Clock className="h-3.5 w-3.5" /> {r.timed_out_count} سؤال انتهى وقته بدون إجابة</p>
              )}
            </>
          ) : (
            <p className="text-sm font-bold text-slate-500">تم تسجيل إجاباتك — النتيجة عند خادمك.</p>
          )}

          <div className="mt-4 flex gap-2">
            <Link href="/child/exams" className="btn-secondary flex flex-1 items-center justify-center gap-1.5 text-sm"><ArrowRight className="h-4 w-4" /> الامتحانات</Link>
            <Link href="/child" className="btn-secondary flex items-center justify-center gap-1.5 text-sm"><Home className="h-4 w-4" /></Link>
            {canRetry && (
              <button id="exam-retry" type="button" onClick={onRetry} className="btn-primary flex flex-1 items-center justify-center gap-1.5 !from-violet-600 !to-violet-500 text-sm">
                <RotateCcw className="h-4 w-4" /> إعادة ({attemptsLeft})
              </button>
            )}
          </div>
        </div>
      </div>

      {/* answers review */}
      {r.answers && r.answers.length > 0 && (
        <section className="mt-4">
          <p className="mb-2 flex items-center gap-1.5 px-1 text-xs font-extrabold text-slate-500"><ListChecks className="h-4 w-4" /> مراجعة الإجابات</p>
          <div className="space-y-2">
            {r.answers.map((an) => {
              const answered = an.selected_index !== null;
              return (
                <div key={an.position} className={`card !p-3 ring-1 ${an.is_correct ? 'bg-emerald-50/50 ring-emerald-100' : answered ? 'bg-red-50/50 ring-red-100' : 'bg-slate-50 ring-slate-200'}`}>
                  <div className="flex items-start gap-2">
                    <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-lg bg-white text-[11px] font-extrabold tabular-nums ring-1 ring-slate-200">{an.position + 1}</span>
                    <p className="flex-1 text-sm font-bold leading-snug">{an.text}</p>
                    {an.is_correct ? <CheckCircle2 className="h-5 w-5 shrink-0 text-emerald-600" /> : <XCircle className="h-5 w-5 shrink-0 text-red-500" />}
                  </div>
                  {an.image_url && <div className="relative mt-2 h-32 w-full overflow-hidden rounded-xl bg-white"><Image src={an.image_url} alt="" fill sizes="400px" className="object-contain" /></div>}
                  <div className="mt-2 space-y-1">
                    {an.options.map((o, i) => {
                      const isC = i === an.correct_index;
                      const isS = i === an.selected_index;
                      if (!isC && !isS) return null;
                      return (
                        <div key={i} className={`flex items-center gap-2 rounded-lg px-2 py-1 text-xs font-bold ${isC ? 'bg-emerald-100 text-emerald-800' : 'bg-red-100 text-red-700'}`}>
                          <span className="w-4 text-center">{OPTION_LETTERS[i]}</span>
                          <span className="flex-1">{o}</span>
                          {isC ? <span className="flex items-center gap-1"><Check className="h-3.5 w-3.5" /> الصحيحة</span> : <span className="flex items-center gap-1"><X className="h-3.5 w-3.5" /> إجابتك</span>}
                        </div>
                      );
                    })}
                    {!answered && <p className="text-[11px] font-bold text-orange-600">{an.timed_out ? '⏱ انتهى الوقت بدون إجابة' : 'بدون إجابة'}</p>}
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}
    </div>
  );
}
