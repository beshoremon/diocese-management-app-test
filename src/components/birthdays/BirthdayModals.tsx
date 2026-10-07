'use client';

// ---------- Birthdays module — modals ----------
// ComposeGreetingModal : edit the greeting template (variables)
// GreetingLogModal     : one child's greetings of the year + gift / undo / note
// GiftModal            : give the yearly points gift (NumPad → RPC)
// BirthdayCardModal    : render the child's birthday card → share as image
//                        (Web Share / WhatsApp) · download PNG · print one

import { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  X, Gift, Loader2, Trash2, Download, Share2, Printer, Send, Phone, MessageSquare, Check, IdCard, RotateCcw,
} from 'lucide-react';
import type { SupabaseClient } from '@supabase/supabase-js';
import NumPadModal from '@/components/NumPadModal';
import CardCanvas, { type CardConstantsData } from '@/components/cards/CardCanvas';
import { normalizeDesign, GOOGLE_FONTS } from '@/lib/card-types';
import {
  type BirthdayRow, type BirthdayCardTemplate, type GreetingKind,
  GREETING_LABELS, MSG_VARS, giveBirthdayGift, cancelBirthdayGift, deleteGreeting, logGreeting,
  birthdayErrorMessage, rowToCardPerson, waNumber, firstName,
} from '@/lib/birthdays';
import { GREETING_ICON, GREETING_COLOR, PersonAvatar, WhatsAppIcon } from './BirthdayBits';

const MM_TO_PX = 96 / 25.4;

// Load the designer Google fonts once (cards render with them)
export function FontsLoader() {
  const href = useMemo(() => {
    const families = GOOGLE_FONTS.map((f) => `family=${f.replace(/ /g, '+')}:wght@400;700;800`).join('&');
    return `https://fonts.googleapis.com/css2?${families}&display=swap`;
  }, []);
  // eslint-disable-next-line @next/next/no-page-custom-font
  return <link rel="stylesheet" href={href} />;
}

function Sheet({ title, onClose, children, wide = false }: { title: React.ReactNode; onClose: () => void; children: React.ReactNode; wide?: boolean }) {
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-6 print:hidden" onClick={onClose}>
      <div
        className={`no-scrollbar max-h-[92vh] w-full overflow-y-auto rounded-t-3xl bg-white p-5 sm:rounded-3xl ${wide ? 'max-w-2xl' : 'max-w-md'}`}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between gap-2">
          <h3 className="flex min-w-0 items-center gap-2 text-lg font-extrabold">{title}</h3>
          <button onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

// ============================================================
// Compose greeting template
// ============================================================
export function ComposeGreetingModal({
  template, onSave, onClose,
}: { template: string; onSave: (t: string) => void; onClose: () => void }) {
  const [text, setText] = useState(template);
  const insertVar = (token: string) => {
    const el = document.getElementById('bd-compose-textarea') as HTMLTextAreaElement | null;
    if (el) {
      const start = el.selectionStart ?? text.length;
      const end = el.selectionEnd ?? text.length;
      const next = text.slice(0, start) + token + text.slice(end);
      setText(next);
      requestAnimationFrame(() => { el.focus(); el.setSelectionRange(start + token.length, start + token.length); });
    } else setText((t) => t + token);
  };
  return (
    <Sheet title={<><MessageSquare className="h-5 w-5 text-pink-600" /> نص التهنئة</>} onClose={onClose}>
      <textarea id="bd-compose-textarea" className="input-field" rows={5} value={text} onChange={(e) => setText(e.target.value)} placeholder="اكتب نص رسالة التهنئة..." />
      <p className="mb-1.5 mt-3 text-xs font-bold text-slate-500">إضافة متغير:</p>
      <div className="flex flex-wrap gap-2">
        {MSG_VARS.map((v) => (
          <button key={v.token} type="button" onClick={() => insertVar(v.token)}
            className="rounded-full bg-pink-50 px-3 py-1.5 text-xs font-bold text-pink-700 transition hover:bg-pink-100 active:scale-95">
            + {v.label}
          </button>
        ))}
      </div>
      <p className="mt-3 rounded-xl bg-slate-50 px-3 py-2 text-[11px] text-slate-500">
        تُستبدل المتغيرات ببيانات كل مخدوم عند الإرسال — سواء لمخدوم واحد أو للجميع.
      </p>
      <div className="mt-4 flex gap-2">
        <button type="button" onClick={() => { onSave(text); onClose(); }} className="btn-primary flex-1 !py-2.5">حفظ النص</button>
        <button type="button" onClick={onClose} className="btn-secondary !py-2.5">إلغاء</button>
      </div>
    </Sheet>
  );
}

// ============================================================
// Gift modal (NumPad → RPC)
// ============================================================
export function GiftModal({
  supabase, row, year, defaultPoints, onDone, onClose,
}: {
  supabase: SupabaseClient; row: BirthdayRow; year: number; defaultPoints: number;
  onDone: (msg: string) => void; onClose: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const confirm = async (points: number) => {
    if (points <= 0) { setErr('عدد النقاط غير صالح'); return; }
    setBusy(true); setErr(null);
    try {
      const res = await giveBirthdayGift(supabase, row.enrollment_id, year, points, `هدية عيد ميلاد ${year}`);
      onDone(`🎁 أُضيفت ${res.points} نقطة هدية لـ ${firstName(row.name)} — الرصيد ${res.balance_after}`);
      onClose();
    } catch (e) { setErr(birthdayErrorMessage(e)); }
    finally { setBusy(false); }
  };
  if (busy) {
    return (
      <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/40">
        <Loader2 className="h-8 w-8 animate-spin text-white" />
      </div>
    );
  }
  return (
    <>
      <NumPadModal title={`🎁 هدية عيد ميلاد — ${firstName(row.name)}`} initial={defaultPoints} onConfirm={confirm} onClose={onClose} />
      {err && (
        <div className="fixed inset-x-4 bottom-24 z-[70] mx-auto max-w-md rounded-2xl bg-red-600 px-4 py-3 text-center text-sm font-bold text-white shadow-xl">{err}</div>
      )}
    </>
  );
}

// ============================================================
// Greeting log — one child, one year
// ============================================================
export function GreetingLogModal({
  supabase, row, year, canCancelGift, currentUserId, onChanged, onGift, onCard, onClose,
}: {
  supabase: SupabaseClient; row: BirthdayRow; year: number;
  canCancelGift: boolean; currentUserId?: string;
  onChanged: () => void; onGift: () => void; onCard: () => void; onClose: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState('');

  const remove = async (id: string, kind: GreetingKind) => {
    setBusy(id); setErr(null);
    try {
      if (kind === 'gift') await cancelBirthdayGift(supabase, id);
      else await deleteGreeting(supabase, id);
      onChanged();
    } catch (e) { setErr(birthdayErrorMessage(e)); }
    finally { setBusy(null); }
  };
  const addNote = async () => {
    if (!note.trim()) return;
    setBusy('note'); setErr(null);
    try { await logGreeting(supabase, row, year, 'note', note.trim(), currentUserId); setNote(''); onChanged(); }
    catch (e) { setErr(birthdayErrorMessage(e)); }
    finally { setBusy(null); }
  };
  const gifted = row.greetings.find((g) => g.kind === 'gift');

  return (
    <Sheet title={<><PersonAvatar url={row.image_url} name={row.name} size={36} /><span className="truncate">{row.name}</span></>} onClose={onClose}>
      <p className="-mt-2 mb-3 text-xs font-bold text-slate-400">
        🎂 يتمّ {row.turns_age} سنة في {year} · سجل تهاني هذه السنة
      </p>

      <div className="mb-3 grid grid-cols-2 gap-2">
        <button type="button" onClick={onGift} disabled={!!gifted}
          className={`flex items-center justify-center gap-1.5 rounded-xl py-2.5 text-sm font-extrabold ${gifted ? 'bg-amber-50 text-amber-400' : 'bg-amber-500 text-white shadow active:scale-95'}`}>
          <Gift className="h-4 w-4" /> {gifted ? `أُهدي ${gifted.points} نقطة` : 'هدية نقاط'}
        </button>
        <button type="button" onClick={onCard}
          className="flex items-center justify-center gap-1.5 rounded-xl bg-pink-600 py-2.5 text-sm font-extrabold text-white shadow active:scale-95">
          <IdCard className="h-4 w-4" /> كارت التهنئة
        </button>
      </div>

      {row.greetings.length === 0 ? (
        <p className="rounded-2xl bg-slate-50 py-6 text-center text-sm font-bold text-slate-400">لم يُهنَّأ بعد هذه السنة</p>
      ) : (
        <ul className="divide-y divide-slate-100 rounded-2xl border border-slate-100">
          {row.greetings.map((g) => {
            const Icon = GREETING_ICON[g.kind];
            const removable = g.kind === 'gift' ? canCancelGift : (canCancelGift || g.recorded_by === currentUserId);
            return (
              <li key={g.id} className="flex items-start gap-2 px-3 py-2">
                <span className={`mt-0.5 rounded-lg p-1.5 ${GREETING_COLOR[g.kind]}`}><Icon className="h-4 w-4" /></span>
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-extrabold">
                    {GREETING_LABELS[g.kind]}{g.kind === 'gift' && g.points != null ? ` · +${g.points}` : ''}
                  </span>
                  {g.message && <span className="block truncate text-xs text-slate-500">{g.message}</span>}
                  <span className="block text-[10px] font-bold text-slate-400">
                    {new Date(g.created_at).toLocaleString('ar-EG', { dateStyle: 'medium', timeStyle: 'short' })}
                    {g.recorded_by_name ? ` · ${g.recorded_by_name}` : ''}
                  </span>
                </span>
                {removable && (
                  <button type="button" onClick={() => remove(g.id, g.kind)} disabled={busy === g.id}
                    aria-label={g.kind === 'gift' ? 'إلغاء الهدية' : 'حذف'} className="rounded-full p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-600">
                    {busy === g.id ? <Loader2 className="h-4 w-4 animate-spin" /> : g.kind === 'gift' ? <RotateCcw className="h-4 w-4" /> : <Trash2 className="h-4 w-4" />}
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}

      <div className="mt-3 flex gap-2">
        <input className="input-field !py-2 text-sm" placeholder="ملاحظة (مثلاً: هنّأناه في القداس)" value={note} onChange={(e) => setNote(e.target.value)} />
        <button type="button" onClick={addNote} disabled={!note.trim() || busy === 'note'} className="btn-secondary !px-3 !py-2">
          {busy === 'note' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
        </button>
      </div>
      {err && <p className="mt-2 text-xs font-bold text-red-600">{err}</p>}
    </Sheet>
  );
}

// ============================================================
// Birthday card modal — preview · share image · download · print one
// ============================================================
export function BirthdayCardModal({
  supabase, row, year, template, templates, onPickTemplate, constants, currentUserId, onLogged, onClose,
}: {
  supabase: SupabaseClient; row: BirthdayRow; year: number;
  template: BirthdayCardTemplate | null; templates: BirthdayCardTemplate[];
  onPickTemplate: (t: BirthdayCardTemplate) => void;
  constants: CardConstantsData; currentUserId?: string;
  onLogged: (msg: string) => void; onClose: () => void;
}) {
  const cardRef = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [printing, setPrinting] = useState(false);
  const design = useMemo(() => (template ? normalizeDesign(template.design) : null), [template]);
  const person = useMemo(() => rowToCardPerson(row, year), [row, year]);

  // fit the card in the sheet
  const [boxW, setBoxW] = useState(320);
  const boxRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = boxRef.current; if (!el) return;
    const ro = new ResizeObserver(() => setBoxW(el.clientWidth - 24));
    ro.observe(el); setBoxW(el.clientWidth - 24);
    return () => ro.disconnect();
  }, []);
  const scale = design ? Math.min(boxW / design.width, 360 / design.height) : 1;

  // Rasterize the on-screen card to a PNG at ~300 dpi (modern-screenshot
  // clones the DOM into an SVG foreignObject; remote pictures are inlined
  // via fetch — the Supabase public bucket serves CORS headers).
  const toBlob = async (): Promise<Blob> => {
    const { domToBlob } = await import('modern-screenshot');
    const node = cardRef.current;
    if (!node || !design) throw new Error('no card');
    const targetScale = (300 / 25.4) / scale; // px-per-mm at 300 dpi ÷ current px-per-mm
    const blob = await domToBlob(node, {
      scale: targetScale, type: 'image/png', backgroundColor: null,
      fetch: { requestInit: { mode: 'cors', cache: 'no-cache' } },
    });
    if (!blob) throw new Error('rasterize failed');
    return blob;
  };

  const fileName = `birthday-${firstName(row.name)}-${year}.png`;
  const saveBlob = (blob: Blob) => {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = fileName; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 3000);
  };

  const download = async () => {
    setBusy('download'); setErr(null);
    try { saveBlob(await toBlob()); }
    catch (e) { setErr((e as Error).message || 'تعذّر إنشاء الصورة'); }
    finally { setBusy(null); }
  };

  const share = async () => {
    setBusy('share'); setErr(null);
    try {
      const blob = await toBlob();
      const file = new File([blob], fileName, { type: 'image/png' });
      const nav = navigator as Navigator & { canShare?: (d: ShareData) => boolean };
      if (nav.share && (!nav.canShare || nav.canShare({ files: [file] }))) {
        await nav.share({ files: [file], title: `عيد ميلاد ${row.name}`, text: `🎂 كل سنة وأنت طيب يا ${firstName(row.name)}` });
        await logGreeting(supabase, row, year, 'card_shared', template?.name ?? null, currentUserId).catch(() => {});
        onLogged('تم إرسال الكارت ✓');
      } else {
        // fallback (desktop): download + open the WhatsApp chat so the servant attaches it
        saveBlob(blob);
        if (row.phone) window.open(`https://wa.me/${waNumber(row.phone)}`, '_blank', 'noopener,noreferrer');
        await logGreeting(supabase, row, year, 'card_shared', template?.name ?? null, currentUserId).catch(() => {});
        onLogged('تم تنزيل الكارت — أرفقه في محادثة الواتساب');
      }
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setErr((e as Error).message || 'تعذّر المشاركة');
    } finally { setBusy(null); }
  };

  const printOne = () => {
    if (!design) return;
    setPrinting(true);
    setTimeout(async () => {
      window.print();
      setPrinting(false);
      await logGreeting(supabase, row, year, 'card_printed', template?.name ?? null, currentUserId).catch(() => {});
      onLogged('تمت طباعة الكارت ✓');
    }, 600);
  };

  return (
    <Sheet wide title={<><IdCard className="h-5 w-5 text-pink-600" /><span className="truncate">كارت تهنئة — {row.name}</span></>} onClose={onClose}>
      <FontsLoader />
      {templates.length > 1 && (
        <select className="input-field mb-3 appearance-none !py-2 text-sm font-bold" value={template?.id ?? ''}
          onChange={(e) => { const t = templates.find((x) => x.id === e.target.value); if (t) onPickTemplate(t); }}>
          {templates.map((t) => <option key={t.id} value={t.id}>{t.name}{t.is_default ? ' (افتراضي)' : ''}</option>)}
        </select>
      )}

      <div ref={boxRef} className="flex w-full justify-center overflow-hidden rounded-2xl bg-slate-100 p-3">
        {design ? (
          <div ref={cardRef} style={{ display: 'inline-block' }}>
            <CardCanvas design={design} scale={scale} person={person} constants={constants} />
          </div>
        ) : (
          <p className="py-10 text-center text-sm font-bold text-slate-400">
            لا يوجد قالب كارت لنطاق هذا المخدوم — أنشئ واحداً من تبويب «كروت التهنئة»
          </p>
        )}
      </div>

      {design && (
        <div className="mt-3 grid grid-cols-3 gap-2">
          <button type="button" onClick={share} disabled={!!busy} className="flex flex-col items-center gap-1 rounded-2xl bg-emerald-600 py-3 text-xs font-extrabold text-white shadow active:scale-95">
            {busy === 'share' ? <Loader2 className="h-5 w-5 animate-spin" /> : <Share2 className="h-5 w-5" />} إرسال الصورة
          </button>
          <button type="button" onClick={download} disabled={!!busy} className="flex flex-col items-center gap-1 rounded-2xl bg-slate-700 py-3 text-xs font-extrabold text-white shadow active:scale-95">
            {busy === 'download' ? <Loader2 className="h-5 w-5 animate-spin" /> : <Download className="h-5 w-5" />} تنزيل PNG
          </button>
          <button type="button" onClick={printOne} disabled={!!busy || printing} className="flex flex-col items-center gap-1 rounded-2xl bg-violet-600 py-3 text-xs font-extrabold text-white shadow active:scale-95">
            {printing ? <Loader2 className="h-5 w-5 animate-spin" /> : <Printer className="h-5 w-5" />} طباعة
          </button>
        </div>
      )}
      {row.phone && (
        <div className="mt-2 grid grid-cols-2 gap-2">
          <a href={`tel:${row.phone}`} onClick={() => logGreeting(supabase, row, year, 'call', null, currentUserId).catch(() => {})}
            className="flex items-center justify-center gap-1.5 rounded-xl border border-sky-200 bg-sky-50 py-2 text-xs font-extrabold text-sky-700">
            <Phone className="h-4 w-4" /> اتصال
          </a>
          <a href={`https://wa.me/${waNumber(row.phone)}`} target="_blank" rel="noopener noreferrer"
            className="flex items-center justify-center gap-1.5 rounded-xl border border-emerald-200 bg-emerald-50 py-2 text-xs font-extrabold text-emerald-700">
            <WhatsAppIcon className="h-4 w-4" /> فتح المحادثة
          </a>
        </div>
      )}
      {err && <p className="mt-2 text-xs font-bold text-red-600">{err}</p>}
      <p className="mt-2 text-center text-[11px] font-bold text-slate-400">
        <Send className="mr-1 inline h-3 w-3" /> «إرسال الصورة» يفتح قائمة المشاركة في الهاتف (واتساب وغيره) بصورة الكارت بدقة طباعة.
      </p>

      {/* hidden single-card print sheet */}
      {design && typeof document !== 'undefined' && createPortal(
        <div id="bd-card-print-root" dir="rtl">
          <style>{`
            #bd-card-print-root { display: none; }
            @media print {
              body > *:not(#bd-card-print-root) { display: none !important; }
              #bd-card-print-root { display: block !important; }
              @page { size: ${design.width}mm ${design.height}mm; margin: 0; }
              html, body { margin: 0 !important; padding: 0 !important; background: #fff !important; }
              * { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
            }
          `}</style>
          <div style={{ width: `${design.width}mm`, height: `${design.height}mm`, overflow: 'hidden' }}>
            <CardCanvas design={design} scale={MM_TO_PX} person={person} constants={constants} />
          </div>
        </div>,
        document.body
      )}
    </Sheet>
  );
}
