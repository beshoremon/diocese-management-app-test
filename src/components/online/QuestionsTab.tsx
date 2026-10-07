'use client';

// ---------- Live questions tab (control room) ----------
// Servant prepares questions (draft), OPENS one during the stream (children
// see it instantly), watches the answers arrive in realtime (per-option bar
// chart or free-text list), then CLOSES it (the correct answer is revealed
// to the children). Points for correct MCQ answers are granted by the DB.

import { useMemo, useState } from 'react';
import { Plus, Pencil, Trash2, Play, Square, Loader2, ListChecks, MessageSquareText, Star, Check, Users, RotateCcw } from 'lucide-react';
import type { SupabaseClient } from '@supabase/supabase-js';
import LiveQuestionModal from '@/components/online/LiveQuestionModal';
import { fmtTime } from '@/components/online/OnlineBits';
import {
  updateLiveQuestion, deleteLiveQuestion, onlineErrorMessage, OPTION_LETTERS, QUESTION_STATUS_LABELS,
  type LiveQuestion, type LiveAnswer, type LiveParticipant, type OnlineClass,
} from '@/lib/online-classes';

export default function QuestionsTab({
  cls, questions, answers, participants, canWrite, supabase, onChanged, flash,
}: {
  cls: OnlineClass; questions: LiveQuestion[]; answers: LiveAnswer[]; participants: LiveParticipant[];
  canWrite: boolean; supabase: SupabaseClient; onChanged: () => void; flash: (m: string) => void;
}) {
  const [form, setForm] = useState<{ open: boolean; q: LiveQuestion | null }>({ open: false, q: null });
  const [busy, setBusy] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);
  const names = useMemo(() => new Map(participants.map((p) => [p.participant_id, p.name])), [participants]);
  const byQuestion = useMemo(() => {
    const m = new Map<string, LiveAnswer[]>();
    for (const a of answers) m.set(a.question_id, [...(m.get(a.question_id) ?? []), a]);
    return m;
  }, [answers]);
  const onlineCount = participants.filter((p) => p.online).length;

  const setStatus = async (q: LiveQuestion, status: LiveQuestion['status']) => {
    if (status === 'open' && cls.status !== 'live') return flash('ابدأ الفصل أولاً حتى يظهر السؤال للمخدومين');
    setBusy(q.id);
    try {
      await updateLiveQuestion(supabase, q.id, { status });
      flash(status === 'open' ? 'السؤال مفتوح الآن للمخدومين' : status === 'closed' ? 'أُغلق السؤال — ظهرت الإجابة الصحيحة' : 'عاد السؤال غير معروض');
      onChanged();
    } catch (e) { flash(onlineErrorMessage(e, 'تعذر التغيير')); } finally { setBusy(null); }
  };
  const remove = async (q: LiveQuestion) => {
    if ((byQuestion.get(q.id)?.length ?? 0) > 0 && !confirm('لهذا السؤال إجابات — حذفه يحذفها (النقاط المضافة لا تُخصم). متابعة؟')) return;
    setBusy(q.id);
    try { await deleteLiveQuestion(supabase, q.id); onChanged(); }
    catch (e) { flash(onlineErrorMessage(e, 'تعذر الحذف')); } finally { setBusy(null); }
  };

  return (
    <div>
      <div className="mb-3 flex items-center justify-between">
        <p className="text-xs font-bold text-slate-500">{questions.length} سؤال · {onlineCount} متصل الآن</p>
        {canWrite && (
          <button id="lq-new" type="button" onClick={() => setForm({ open: true, q: null })} className="btn-primary flex items-center gap-1.5 !py-2 !px-3 text-xs !from-red-600 !to-red-500">
            <Plus className="h-4 w-4" /> سؤال جديد
          </button>
        )}
      </div>

      {questions.length === 0 ? (
        <div className="card py-10 text-center text-slate-400">
          <ListChecks className="mx-auto mb-2 h-8 w-8 text-slate-300" />
          <p className="text-sm font-bold">لا أسئلة بعد — جهّز أسئلتك قبل الدرس وافتحها وقت البث</p>
        </div>
      ) : (
        <div id="lq-list" className="space-y-2">
          {questions.map((q, i) => {
            const ans = byQuestion.get(q.id) ?? [];
            const isOpen = q.status === 'open';
            const open = expanded === q.id || isOpen;
            return (
              <div key={q.id} id={`lq-${q.id}`} className={`card !p-3 ${isOpen ? 'ring-2 ring-red-300' : ''}`}>
                <div className="flex items-start gap-2">
                  <span className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-xs font-extrabold ${isOpen ? 'bg-red-600 text-white' : q.status === 'closed' ? 'bg-slate-200 text-slate-600' : 'bg-slate-100 text-slate-500'}`}>{i + 1}</span>
                  <button type="button" onClick={() => setExpanded(open && !isOpen ? null : q.id)} className="min-w-0 flex-1 text-start">
                    <p className="font-extrabold leading-snug">{q.text}</p>
                    <p className="mt-1 flex flex-wrap items-center gap-1.5">
                      <span className={`badge ${isOpen ? 'bg-red-100 text-red-600' : q.status === 'closed' ? 'bg-slate-200 text-slate-600' : 'bg-slate-100 text-slate-500'}`}>{QUESTION_STATUS_LABELS[q.status]}</span>
                      <span className="badge bg-slate-100 text-slate-600">{q.options ? <><ListChecks className="h-3 w-3" /> {q.options.length} اختيارات</> : <><MessageSquareText className="h-3 w-3" /> إجابة حرة</>}</span>
                      {q.points > 0 && <span className="badge bg-gold-100 text-gold-700"><Star className="h-3 w-3" /> +{q.points}</span>}
                      <span className="badge bg-primary-100 text-primary-700"><Users className="h-3 w-3" /> {ans.length} إجابة</span>
                      {q.opened_at && <span className="badge bg-slate-100 text-slate-500">فُتح {fmtTime(q.opened_at)}</span>}
                    </p>
                  </button>
                </div>

                {open && (
                  <div className="mt-3 border-t border-slate-100 pt-3">
                    {q.options ? (
                      <div className="space-y-1.5">
                        {q.options.map((o, k) => {
                          const n = ans.filter((a) => a.selected_index === k).length;
                          const pct = ans.length ? Math.round((n * 100) / ans.length) : 0;
                          const correct = q.correct_index === k;
                          return (
                            <div key={k} className="relative overflow-hidden rounded-xl bg-slate-50 px-3 py-2">
                              <div className={`absolute inset-y-0 right-0 transition-all ${correct ? 'bg-emerald-100' : 'bg-slate-200/70'}`} style={{ width: `${pct}%` }} />
                              <div className="relative flex items-center gap-2 text-sm">
                                <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-[11px] font-extrabold ${correct ? 'bg-emerald-600 text-white' : 'bg-white text-slate-600'}`}>{correct ? <Check className="h-3.5 w-3.5" /> : OPTION_LETTERS[k]}</span>
                                <span className="min-w-0 flex-1 truncate font-bold">{o}</span>
                                <span className="shrink-0 text-xs font-extrabold tabular-nums text-slate-600">{n} · {pct}٪</span>
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    ) : ans.length === 0 ? (
                      <p className="text-center text-xs font-bold text-slate-400">لا إجابات بعد</p>
                    ) : (
                      <ul className="max-h-60 space-y-1 overflow-y-auto">
                        {ans.map((a) => (
                          <li key={a.id} className="rounded-xl bg-slate-50 px-3 py-2 text-sm">
                            <span className="font-extrabold">{names.get(a.participant_id) ?? 'مخدوم'}:</span> <span className="text-slate-700">{a.answer_text}</span>
                            <span className="mr-2 text-[10px] font-bold text-slate-400">{fmtTime(a.answered_at)}</span>
                          </li>
                        ))}
                      </ul>
                    )}
                    {q.options && ans.length > 0 && (
                      <details className="mt-2">
                        <summary className="cursor-pointer text-[11px] font-bold text-slate-500">من أجاب؟ ({ans.length})</summary>
                        <ul className="mt-1 flex flex-wrap gap-1">
                          {ans.map((a) => (
                            <li key={a.id} className={`badge ${a.is_correct === true ? 'bg-emerald-100 text-emerald-700' : a.is_correct === false ? 'bg-red-100 text-red-600' : 'bg-slate-100 text-slate-600'}`}>
                              {names.get(a.participant_id) ?? 'مخدوم'} · {a.selected_index !== null ? OPTION_LETTERS[a.selected_index] : '—'}
                            </li>
                          ))}
                        </ul>
                      </details>
                    )}
                  </div>
                )}

                {canWrite && (
                  <div className="mt-2 flex items-center justify-end gap-1 border-t border-slate-100 pt-2">
                    {q.status === 'draft' && (
                      <button type="button" id={`lq-open-${q.id}`} disabled={busy === q.id} onClick={() => setStatus(q, 'open')} className="flex items-center gap-1 rounded-lg bg-red-600 px-3 py-1.5 text-[11px] font-extrabold text-white">
                        {busy === q.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Play className="h-3.5 w-3.5" />} افتح للمخدومين
                      </button>
                    )}
                    {q.status === 'open' && (
                      <button type="button" id={`lq-close-${q.id}`} disabled={busy === q.id} onClick={() => setStatus(q, 'closed')} className="flex items-center gap-1 rounded-lg bg-slate-800 px-3 py-1.5 text-[11px] font-extrabold text-white">
                        {busy === q.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Square className="h-3.5 w-3.5" />} أغلق السؤال
                      </button>
                    )}
                    {q.status === 'closed' && (
                      <button type="button" disabled={busy === q.id} onClick={() => setStatus(q, 'open')} className="flex items-center gap-1 rounded-lg px-2 py-1 text-[11px] font-bold text-slate-500 hover:bg-slate-50">
                        <RotateCcw className="h-3.5 w-3.5" /> أعد فتحه
                      </button>
                    )}
                    <span className="mx-1 h-4 w-px bg-slate-200" />
                    <button type="button" disabled={ans.length > 0} title={ans.length ? 'لا يمكن التعديل بعد وصول إجابات' : ''} onClick={() => setForm({ open: true, q })} className="rounded-lg p-1.5 text-slate-500 hover:bg-slate-50 disabled:opacity-40"><Pencil className="h-4 w-4" /></button>
                    <button type="button" disabled={busy === q.id} onClick={() => remove(q)} className="rounded-lg p-1.5 text-red-500 hover:bg-red-50"><Trash2 className="h-4 w-4" /></button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {form.open && (
        <LiveQuestionModal
          classId={cls.id} question={form.q} sortOrder={questions.length + 1}
          onClose={() => setForm({ open: false, q: null })}
          onSaved={() => { setForm({ open: false, q: null }); onChanged(); }}
        />
      )}
    </div>
  );
}
