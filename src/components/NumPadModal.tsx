'use client';

// ---------- NumPad modal ----------
// Tapping a points number opens this numpad. Typing REPLACES the existing
// number (first keypress starts fresh), so the servant just writes the new
// value and confirms.

import { useState } from 'react';
import { X, Delete, Check } from 'lucide-react';

export default function NumPadModal({
  title,
  initial,
  onConfirm,
  onClose,
}: {
  title: string;
  initial: number;
  onConfirm: (value: number) => void;
  onClose: () => void;
}) {
  // '' = untouched -> show the current number faded; first digit replaces it
  const [entry, setEntry] = useState('');

  const shown = entry === '' ? String(initial) : entry;

  const pressDigit = (d: string) => {
    setEntry((prev) => {
      const next = (prev + d).replace(/^0+(?=\d)/, ''); // no leading zeros
      return next.slice(0, 4); // max 4 digits
    });
  };

  const backspace = () => setEntry((prev) => prev.slice(0, -1));

  const confirm = () => {
    const v = entry === '' ? initial : Math.max(0, parseInt(entry, 10) || 0);
    onConfirm(v);
  };

  const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

  return (
    <div
      className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-6"
      onClick={onClose}
    >
      <div
        id="numpad-modal"
        className="w-full max-w-xs rounded-t-3xl sm:rounded-3xl bg-white p-5 animate-[slideUp_0.2s_ease-out]"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-base font-extrabold">{title}</h3>
          <button onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* Display */}
        <div
          id="numpad-display"
          className={`mb-4 rounded-2xl bg-slate-50 px-4 py-3 text-center text-3xl font-extrabold tabular-nums ${
            entry === '' ? 'text-slate-300' : 'text-slate-800'
          }`}
        >
          {shown}
        </div>

        {/* Keys */}
        <div className="grid grid-cols-3 gap-2" dir="ltr">
          {keys.map((k) => (
            <button
              key={k}
              type="button"
              onClick={() => pressDigit(k)}
              className="rounded-2xl bg-slate-100 py-3.5 text-xl font-extrabold text-slate-700 transition hover:bg-slate-200 active:scale-95"
            >
              {k}
            </button>
          ))}
          <button
            type="button"
            onClick={backspace}
            aria-label="مسح رقم"
            className="flex items-center justify-center rounded-2xl bg-red-50 py-3.5 text-red-500 transition hover:bg-red-100 active:scale-95"
          >
            <Delete className="h-6 w-6" />
          </button>
          <button
            type="button"
            onClick={() => pressDigit('0')}
            className="rounded-2xl bg-slate-100 py-3.5 text-xl font-extrabold text-slate-700 transition hover:bg-slate-200 active:scale-95"
          >
            0
          </button>
          <button
            type="button"
            onClick={confirm}
            aria-label="تأكيد"
            className="flex items-center justify-center rounded-2xl bg-emerald-500 py-3.5 text-white shadow transition hover:bg-emerald-600 active:scale-95"
          >
            <Check className="h-6 w-6" />
          </button>
        </div>
      </div>
    </div>
  );
}
