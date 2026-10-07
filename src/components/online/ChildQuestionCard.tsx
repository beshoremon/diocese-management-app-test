'use client';

// ---------- Child room — one live question card ----------
// MCQ: pick → «إرسال»; after answering (or once closed) the options lock and
// the correct one is highlighted when revealed. Free text: input + send.

import { useState } from 'react';
import { ListChecks, Star, Check, Send, Loader2 } from 'lucide-react';
import type { ChildLiveQuestion } from '@/lib/child-portal';
import { OPTION_LETTERS } from '@/lib/online-classes';

export default function ChildQuestionCard({ q, busy, onAnswer }: {
  q: ChildLiveQuestion; busy: boolean; onAnswer: (selected: number | null, text: string | null) => void;
}) {
  const [text, setText] = useState('');
  const [picked, setPicked] = useState<number | null>(null);
  const mine = q.my_answer;
  const closed = q.status === 'closed';

  return (
    <div id={`child-lq-${q.id}`} className={`card !p-3 ${!closed && !mine ? 'ring-2 ring-red-200' : ''}`}>
      <div className="flex items-start gap-2">
        <span className={`rounded-lg p-1.5 ${closed ? 'bg-slate-100 text-slate-500' : 'bg-red-600 text-white'}`}><ListChecks className="h-4 w-4" /></span>
        <div className="min-w-0 flex-1">
          <p className="font-extrabold leading-snug">{q.text}</p>
          <p className="mt-0.5 flex flex-wrap gap-1.5 text-[10px] font-bold text-slate-400">
            <span>{closed ? 'أُغلق' : 'مفتوح الآن'}</span>
            {q.points > 0 && <span className="text-gold-700"><Star className="inline h-3 w-3" /> +{q.points} للإجابة الصحيحة</span>}
          </p>
        </div>
      </div>

      {q.options ? (
        <div className="mt-2 space-y-1.5">
          {q.options.map((o, i) => {
            const isMine = mine?.selected_index === i;
            const isCorrect = q.correct_index === i;
            const cls = mine || closed
              ? isCorrect && closed ? 'bg-emerald-100 text-emerald-800 ring-emerald-300'
                : isMine ? (mine?.is_correct === false ? 'bg-red-100 text-red-700 ring-red-300' : 'bg-primary-100 text-primary-800 ring-primary-300')
                  : 'bg-slate-50 text-slate-500 ring-slate-100'
              : picked === i ? 'bg-red-600 text-white ring-red-600' : 'bg-white text-slate-700 ring-slate-200';
            return (
              <button key={i} type="button" disabled={!!mine || closed || busy} onClick={() => setPicked(i)}
                className={`flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-start text-sm font-bold ring-1 transition ${cls}`}>
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-black/10 text-[11px] font-extrabold">{isCorrect && closed ? <Check className="h-3.5 w-3.5" /> : OPTION_LETTERS[i]}</span>
                <span className="flex-1">{o}</span>
                {isMine && <span className="text-[10px]">إجابتك</span>}
              </button>
            );
          })}
          {!mine && !closed && (
            <button type="button" disabled={picked === null || busy} onClick={() => onAnswer(picked, null)} className="btn-primary flex w-full items-center justify-center gap-2 !from-red-600 !to-red-500 !py-2.5 text-sm">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4 -scale-x-100" />} إرسال الإجابة
            </button>
          )}
          {mine && (
            <p className={`text-center text-xs font-extrabold ${mine.is_correct === true ? 'text-emerald-700' : mine.is_correct === false ? 'text-red-600' : 'text-slate-500'}`}>
              {mine.is_correct === true ? `إجابة صحيحة 🎉${mine.points_granted ? ` +${mine.points_granted} نقطة` : ''}` : mine.is_correct === false ? (closed ? 'إجابة غير صحيحة' : 'تم تسجيل إجابتك') : 'تم تسجيل إجابتك'}
            </p>
          )}
          {!mine && closed && <p className="text-center text-xs font-bold text-slate-400">لم تُجب على هذا السؤال</p>}
        </div>
      ) : (
        <div className="mt-2">
          {mine ? (
            <p className="rounded-xl bg-primary-50 px-3 py-2 text-sm text-primary-900"><span className="text-[10px] font-bold text-primary-600">إجابتك:</span> {mine.answer_text}</p>
          ) : closed ? (
            <p className="text-center text-xs font-bold text-slate-400">أُغلق السؤال</p>
          ) : (
            <form onSubmit={(e) => { e.preventDefault(); if (text.trim()) onAnswer(null, text.trim()); }} className="flex items-center gap-2">
              <input className="input-field flex-1 !py-2 text-sm" placeholder="اكتب إجابتك…" value={text} onChange={(e) => setText(e.target.value)} maxLength={500} />
              <button type="submit" disabled={!text.trim() || busy} aria-label="إرسال" className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-red-600 text-white disabled:opacity-40">
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4 -scale-x-100" />}
              </button>
            </form>
          )}
        </div>
      )}
    </div>
  );
}
