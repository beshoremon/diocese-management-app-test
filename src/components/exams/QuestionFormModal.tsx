'use client';

// ---------- Add / edit a multiple-choice question ----------
// text · optional picture (compressed webp) · 2..6 options · tap the letter
// to mark the correct one · points · seconds (blank = exam default).

import { useState } from 'react';
import Image from 'next/image';
import { X, Save, Loader2, Plus, Trash2, Upload, Check, Clock, Star, ImageIcon } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { uploadPhoto } from '@/lib/upload';
import {
  createQuestion, updateQuestion, examErrorMessage, OPTION_LETTERS, MIN_OPTIONS, MAX_OPTIONS,
  type Exam, type ExamQuestion,
} from '@/lib/exams';

async function compressImage(file: File): Promise<Blob> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const i = new window.Image();
      i.onload = () => resolve(i);
      i.onerror = reject;
      i.src = url;
    });
    const max = 1024;
    const scale = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const ctx = canvas.getContext('2d')!;
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/webp', 0.82));
    return blob ?? file;
  } catch {
    return file;
  } finally {
    URL.revokeObjectURL(url);
  }
}

export default function QuestionFormModal({
  exam, question, nextSortOrder, onClose, onSaved,
}: {
  exam: Exam;
  question: ExamQuestion | null;
  nextSortOrder: number;
  onClose: () => void;
  /** `addAnother` = the servant pressed «حفظ وإضافة آخر» */
  onSaved: (saved: ExamQuestion, addAnother: boolean) => void;
}) {
  const [supabase] = useState(() => createClient());
  const mode = question ? 'edit' : 'add';

  const [text, setText] = useState(question?.text ?? '');
  const [options, setOptions] = useState<string[]>(question?.options ?? ['', '', '', '']);
  const [correct, setCorrect] = useState<number>(question?.correct_index ?? -1);
  const [points, setPoints] = useState(String(question?.points ?? exam.default_points));
  const [seconds, setSeconds] = useState(question?.seconds != null ? String(question.seconds) : '');
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [photoPreview, setPhotoPreview] = useState<string | null>(question?.image_url ?? null);
  const [removePhoto, setRemovePhoto] = useState(false);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState<false | 'save' | 'another'>(false);

  const setOpt = (i: number, v: string) => setOptions((o) => o.map((x, j) => (j === i ? v : x)));
  const addOpt = () => options.length < MAX_OPTIONS && setOptions((o) => [...o, '']);
  const removeOpt = (i: number) => {
    if (options.length <= MIN_OPTIONS) return;
    setOptions((o) => o.filter((_, j) => j !== i));
    setCorrect((c) => (c === i ? -1 : c > i ? c - 1 : c));
  };

  const pickPhoto = (f: File | null) => {
    setPhotoFile(f);
    setRemovePhoto(false);
    if (f) setPhotoPreview(URL.createObjectURL(f));
  };

  const validate = (): string | null => {
    if (!text.trim()) return 'اكتب نص السؤال';
    const trimmed = options.map((o) => o.trim());
    if (trimmed.some((o) => !o)) return 'اكتب نص كل الاختيارات أو احذف الفارغ منها';
    if (new Set(trimmed).size !== trimmed.length) return 'يوجد اختياران بنفس النص';
    if (correct < 0 || correct >= options.length) return 'اضغط على حرف الاختيار الصحيح لتحديده';
    const p = Number(points);
    if (!Number.isFinite(p) || p < 0 || p > 1000) return 'الدرجة بين 0 و 1000';
    if (seconds !== '') {
      const s = Number(seconds);
      if (!Number.isFinite(s) || s < 5 || s > 3600) return 'الوقت بين 5 و 3600 ثانية';
    }
    return null;
  };

  const submit = async (addAnother: boolean) => {
    setError('');
    const v = validate();
    if (v) return setError(v);
    setSaving(addAnother ? 'another' : 'save');
    try {
      let image_url: string | null = removePhoto ? null : (question?.image_url ?? null);
      if (photoFile) {
        const blob = await compressImage(photoFile);
        image_url = await uploadPhoto(supabase, 'exams', blob, 'question.webp');
      }
      const input = {
        text: text.trim(),
        image_url,
        options: options.map((o) => o.trim()),
        correct_index: correct,
        points: Math.round(Number(points)),
        seconds: seconds === '' ? null : Math.round(Number(seconds)),
      };
      const saved = question
        ? await updateQuestion(supabase, question.id, input)
        : await createQuestion(supabase, exam.id, input, nextSortOrder);
      onSaved(saved, addAnother);
      if (addAnother) {
        // reset for the next one, keep points / seconds (they are usually the same)
        setText(''); setOptions(['', '', '', '']); setCorrect(-1);
        setPhotoFile(null); setPhotoPreview(null); setRemovePhoto(false);
      }
    } catch (err) {
      setError(examErrorMessage(err, 'تعذر حفظ السؤال'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/50 backdrop-blur-[2px] sm:items-center" onClick={onClose}>
      <form
        id="question-form" onSubmit={(e) => { e.preventDefault(); submit(false); }} onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-t-3xl bg-white p-4 shadow-2xl sm:rounded-3xl"
        style={{ animation: 'slideUp .25s ease-out' }}
      >
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-base font-extrabold">{mode === 'add' ? `سؤال جديد (${nextSortOrder})` : 'تعديل السؤال'}</h3>
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs font-extrabold text-slate-600">نص السؤال</span>
          <textarea id="q-text" className="input-field min-h-[72px]" value={text} onChange={(e) => setText(e.target.value)} placeholder="اكتب السؤال هنا…" autoFocus />
        </label>

        {/* picture */}
        <div className="mt-3 flex items-center gap-3">
          <div className="relative h-20 w-28 shrink-0 overflow-hidden rounded-xl bg-violet-50 ring-1 ring-violet-100">
            {photoPreview ? (
              <Image src={photoPreview} alt="" fill sizes="112px" className="object-cover" unoptimized />
            ) : (
              <ImageIcon className="absolute inset-0 m-auto h-8 w-8 text-violet-200" />
            )}
          </div>
          <div className="flex flex-col gap-1.5">
            <label className="btn-secondary flex cursor-pointer items-center gap-1.5 !py-1.5 !px-3 text-xs">
              <Upload className="h-3.5 w-3.5" /> {photoPreview ? 'تغيير الصورة' : 'صورة للسؤال (اختياري)'}
              <input type="file" accept="image/*" className="hidden" onChange={(e) => pickPhoto(e.target.files?.[0] ?? null)} />
            </label>
            {photoPreview && (
              <button type="button" onClick={() => { setPhotoFile(null); setPhotoPreview(null); setRemovePhoto(true); }}
                className="flex items-center gap-1 text-xs font-bold text-red-500">
                <Trash2 className="h-3.5 w-3.5" /> إزالة الصورة
              </button>
            )}
          </div>
        </div>

        {/* options */}
        <div className="mt-3">
          <p className="mb-1 flex items-center justify-between text-xs font-extrabold text-slate-600">
            <span>الاختيارات — اضغط الحرف لتحديد الإجابة الصحيحة</span>
            <span className="text-slate-400">{options.length}/{MAX_OPTIONS}</span>
          </p>
          <div className="space-y-2">
            {options.map((o, i) => {
              const isCorrect = correct === i;
              return (
                <div key={i} className={`flex items-center gap-2 rounded-xl p-1 ring-1 transition ${isCorrect ? 'bg-emerald-50 ring-emerald-300' : 'ring-slate-200'}`}>
                  <button type="button" id={`q-correct-${i}`} onClick={() => setCorrect(i)} aria-pressed={isCorrect} aria-label={`الاختيار ${OPTION_LETTERS[i]} صحيح`}
                    className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-sm font-extrabold transition ${isCorrect ? 'bg-emerald-600 text-white' : 'bg-slate-100 text-slate-600 hover:bg-slate-200'}`}>
                    {isCorrect ? <Check className="h-5 w-5" /> : OPTION_LETTERS[i]}
                  </button>
                  <input id={`q-opt-${i}`} className="input-field !py-2 !px-3 text-sm" value={o} onChange={(e) => setOpt(i, e.target.value)} placeholder={`الاختيار ${OPTION_LETTERS[i]}`} />
                  <button type="button" onClick={() => removeOpt(i)} disabled={options.length <= MIN_OPTIONS} aria-label="حذف الاختيار"
                    className="rounded-lg p-2 text-slate-400 hover:bg-red-50 hover:text-red-500 disabled:opacity-30">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
              );
            })}
          </div>
          {options.length < MAX_OPTIONS && (
            <button type="button" id="q-add-option" onClick={addOpt} className="mt-2 flex items-center gap-1 text-xs font-extrabold text-violet-600">
              <Plus className="h-4 w-4" /> إضافة اختيار
            </button>
          )}
        </div>

        {/* points + seconds */}
        <div className="mt-3 grid grid-cols-2 gap-2">
          <label className="block">
            <span className="mb-1 block text-xs font-extrabold text-slate-600">درجة السؤال</span>
            <div className="relative">
              <Star className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gold-500" />
              <input id="q-points" type="number" min={0} max={1000} className="input-field pr-9 tabular-nums" value={points} onChange={(e) => setPoints(e.target.value)} />
            </div>
          </label>
          <label className="block">
            <span className="mb-1 block text-xs font-extrabold text-slate-600">الوقت (ثانية)</span>
            <div className="relative">
              <Clock className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
              <input id="q-seconds" type="number" min={5} max={3600} className="input-field pr-9 tabular-nums" value={seconds} onChange={(e) => setSeconds(e.target.value)} placeholder={`افتراضي ${exam.default_seconds}`} />
            </div>
          </label>
        </div>

        {error && <p className="mt-3 rounded-xl bg-red-50 px-3 py-2 text-xs font-bold text-red-600">{error}</p>}

        <div className="mt-4 flex gap-2">
          <button type="submit" id="q-save" disabled={!!saving} className="btn-primary flex flex-1 items-center justify-center gap-2 !from-violet-600 !to-violet-500">
            {saving === 'save' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
            {mode === 'add' ? 'حفظ' : 'حفظ التعديل'}
          </button>
          {mode === 'add' && (
            <button type="button" id="q-save-another" disabled={!!saving} onClick={() => submit(true)} className="btn-secondary flex items-center gap-1.5 text-sm">
              {saving === 'another' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
              حفظ وإضافة آخر
            </button>
          )}
        </div>
      </form>
    </div>
  );
}
