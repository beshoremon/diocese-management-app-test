'use client';

// ---------- Add / edit a live question ----------
// Two kinds: MCQ (2..6 options, optional correct answer → auto-graded +
// points granted instantly) or free text (the servant reads the answers).

import { useState } from 'react';
import { X, Save, Loader2, Plus, Trash2, Check, ListChecks, MessageSquareText, Star } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth-context';
import {
  createLiveQuestion, updateLiveQuestion, onlineErrorMessage, OPTION_LETTERS,
  type LiveQuestion, type LiveQuestionInput,
} from '@/lib/online-classes';

export default function LiveQuestionModal({
  classId, question, sortOrder, onClose, onSaved,
}: { classId: string; question: LiveQuestion | null; sortOrder: number; onClose: () => void; onSaved: (q: LiveQuestion) => void }) {
  const { user } = useAuth();
  const [supabase] = useState(() => createClient());
  const [kind, setKind] = useState<'mcq' | 'text'>(question ? (question.options ? 'mcq' : 'text') : 'mcq');
  const [text, setText] = useState(question?.text ?? '');
  const [options, setOptions] = useState<string[]>(question?.options ?? ['', '']);
  const [correct, setCorrect] = useState<number | null>(question?.correct_index ?? null);
  const [points, setPoints] = useState(question?.points ?? 0);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    if (!text.trim()) return setError('اكتب نص السؤال');
    let payload: LiveQuestionInput;
    if (kind === 'mcq') {
      const opts = options.map((o) => o.trim());
      if (opts.length < 2) return setError('أضف اختيارين على الأقل');
      if (opts.some((o) => !o)) return setError('يوجد اختيار فارغ');
      if (points > 0 && correct === null) return setError('حدد الإجابة الصحيحة لمنح النقاط، أو اجعل النقاط صفراً');
      payload = { text: text.trim(), options: opts, correct_index: correct, points };
    } else {
      payload = { text: text.trim(), options: null, correct_index: null, points: 0 };
    }
    setSaving(true);
    try {
      const saved = question
        ? await updateLiveQuestion(supabase, question.id, payload)
        : await createLiveQuestion(supabase, classId, payload, sortOrder, user?.id);
      onSaved(saved);
    } catch (err) {
      setError(onlineErrorMessage(err, 'تعذر الحفظ'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/50 backdrop-blur-[2px] sm:items-center" onClick={onClose}>
      <form id="lq-form" onSubmit={submit} onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-t-3xl bg-white p-4 shadow-2xl sm:rounded-3xl" style={{ animation: 'slideUp .25s ease-out' }}>
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-base font-extrabold">{question ? 'تعديل السؤال' : 'سؤال مباشر جديد'}</h3>
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        <div className="mb-3 grid grid-cols-2 gap-2">
          {([['mcq', 'اختيار من متعدد', ListChecks], ['text', 'إجابة حرة', MessageSquareText]] as const).map(([k, label, Icon]) => (
            <button key={k} type="button" id={`lq-kind-${k}`} onClick={() => setKind(k)}
              className={`flex items-center justify-center gap-2 rounded-xl px-3 py-2.5 text-sm font-extrabold transition ${kind === k ? 'bg-red-600 text-white shadow' : 'bg-white text-slate-600 ring-1 ring-slate-200'}`}>
              <Icon className="h-4 w-4" /> {label}
            </button>
          ))}
        </div>

        <label className="block">
          <span className="mb-1 block text-xs font-extrabold text-slate-600">نص السؤال</span>
          <textarea id="lq-text" className="input-field min-h-[64px]" value={text} onChange={(e) => setText(e.target.value)} placeholder="مثال: من بنى الفلك؟" autoFocus />
        </label>

        {kind === 'mcq' && (
          <div className="mt-3">
            <p className="mb-1 text-xs font-extrabold text-slate-600">الاختيارات — اضغط الحرف لتحديد الإجابة الصحيحة (اختياري)</p>
            <div className="space-y-2">
              {options.map((o, i) => (
                <div key={i} className="flex items-center gap-2">
                  <button type="button" id={`lq-correct-${i}`} onClick={() => setCorrect(correct === i ? null : i)} aria-label={`الإجابة الصحيحة ${OPTION_LETTERS[i]}`}
                    className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-sm font-extrabold transition ${correct === i ? 'bg-emerald-600 text-white' : 'bg-slate-100 text-slate-600'}`}>
                    {correct === i ? <Check className="h-5 w-5" /> : OPTION_LETTERS[i]}
                  </button>
                  <input id={`lq-opt-${i}`} className="input-field flex-1" value={o} placeholder={`الاختيار ${OPTION_LETTERS[i]}`}
                    onChange={(e) => setOptions((l) => l.map((x, k) => (k === i ? e.target.value : x)))} />
                  {options.length > 2 && (
                    <button type="button" onClick={() => { setOptions((l) => l.filter((_, k) => k !== i)); setCorrect((c) => (c === i ? null : c !== null && c > i ? c - 1 : c)); }}
                      aria-label="حذف الاختيار" className="rounded-lg p-2 text-red-500 hover:bg-red-50"><Trash2 className="h-4 w-4" /></button>
                  )}
                </div>
              ))}
            </div>
            {options.length < 6 && (
              <button type="button" id="lq-add-opt" onClick={() => setOptions((l) => [...l, ''])} className="mt-2 flex items-center gap-1 text-xs font-extrabold text-red-600">
                <Plus className="h-4 w-4" /> إضافة اختيار
              </button>
            )}
            <label className="mt-3 block">
              <span className="mb-1 flex items-center gap-1 text-xs font-extrabold text-slate-600"><Star className="h-3.5 w-3.5 text-gold-500" /> نقاط الإجابة الصحيحة</span>
              <input id="lq-points" type="number" min={0} max={1000} className="input-field" value={points} onChange={(e) => setPoints(Math.max(0, Math.min(1000, Math.round(Number(e.target.value) || 0))))} />
              <span className="mt-1 block text-[11px] font-bold text-slate-400">تُضاف لرصيد المخدوم فور إجابته إجابة صحيحة</span>
            </label>
          </div>
        )}

        {error && <p className="mt-3 rounded-xl bg-red-50 px-3 py-2 text-xs font-bold text-red-600">{error}</p>}

        <div className="mt-4 flex gap-2">
          <button type="button" onClick={onClose} className="btn-secondary flex-1">إلغاء</button>
          <button id="lq-save" type="submit" disabled={saving} className="btn-primary flex flex-1 items-center justify-center gap-2 !from-red-600 !to-red-500">
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />} حفظ
          </button>
        </div>
      </form>
    </div>
  );
}
