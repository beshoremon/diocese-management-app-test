'use client';

// ---------- One participant (leader) ----------
// Bottom sheet: identity · status stepper (pending → confirmed → checked_in
// · cancelled) · per-participant checklist ✓ · the e-ticket (QR) · note ·
// remove. Every write is an RPC that re-validates in the database.

import { useState } from 'react';
import { X, Loader2, Trash2, Phone, Ticket, ListChecks, StickyNote, Check } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import {
  setRegistrationStatus, removeRegistration, markChecklist, occasionErrorMessage,
  REG_STATUS_LABELS, REG_STATUS_ORDER,
  type Occasion, type Participant, type ChecklistItem, type RegistrationStatus,
} from '@/lib/occasions';
import { PersonAvatar, RegStatusBadge, TicketCard, RegStatusIcon, whenLabel } from '@/components/occasions/OccasionBits';

export default function ParticipantSheet({
  occasion, participant, items, canManage, onClose, onChanged, onRemoved, flash,
}: {
  occasion: Occasion;
  participant: Participant;
  items: ChecklistItem[];
  canManage: boolean;
  onClose: () => void;
  onChanged: (p: Partial<Participant> & { id: string }) => void;
  onRemoved: (id: string) => void;
  flash: (m: string) => void;
}) {
  const [supabase] = useState(() => createClient());
  const [busy, setBusy] = useState<string | null>(null);
  const [showTicket, setShowTicket] = useState(false);
  const [note, setNote] = useState(participant.note ?? '');
  const p = participant;

  const setStatus = async (s: RegistrationStatus) => {
    if (s === p.status) return;
    if (s === 'cancelled' && !confirm(`إلغاء مشاركة «${p.person_name}»؟`)) return;
    setBusy(s);
    try {
      const r = await setRegistrationStatus(supabase, p.id, s, note);
      onChanged({ id: p.id, status: r.status, confirmed_at: r.confirmed_at, checked_in_at: r.checked_in_at, cancelled_at: r.cancelled_at, note: r.note });
      flash(s === 'checked_in' && occasion.checkin_points > 0 ? `تم تسجيل الدخول · +${occasion.checkin_points} نقطة` : `الحالة الآن: ${REG_STATUS_LABELS[s]}`);
    } catch (e) { flash(occasionErrorMessage(e, 'تعذر تغيير الحالة')); }
    finally { setBusy(null); }
  };

  const toggleItem = async (it: ChecklistItem) => {
    const done = p.checklist_items.includes(it.id);
    setBusy(it.id);
    const next = done ? p.checklist_items.filter((x) => x !== it.id) : [...p.checklist_items, it.id];
    onChanged({ id: p.id, checklist_items: next, checklist_done: next.length });
    try { await markChecklist(supabase, p.id, it.id, !done); }
    catch (e) { onChanged({ id: p.id, checklist_items: p.checklist_items, checklist_done: p.checklist_done }); flash(occasionErrorMessage(e, 'تعذر الحفظ')); }
    finally { setBusy(null); }
  };

  const saveNote = async () => {
    if ((note.trim() || null) === (p.note ?? null)) return;
    setBusy('note');
    try {
      const r = await setRegistrationStatus(supabase, p.id, p.status, note || ' ');
      onChanged({ id: p.id, note: r.note });
    } catch (e) { flash(occasionErrorMessage(e, 'تعذر حفظ الملاحظة')); }
    finally { setBusy(null); }
  };

  const remove = async () => {
    if (!confirm(`حذف «${p.person_name}» نهائياً من قائمة المشاركين؟${p.status === 'checked_in' && occasion.checkin_points > 0 ? `\nستُسترد ${occasion.checkin_points} نقطة.` : ''}`)) return;
    setBusy('remove');
    try { await removeRegistration(supabase, p.id); onRemoved(p.id); onClose(); }
    catch (e) { flash(occasionErrorMessage(e, 'تعذر الحذف')); setBusy(null); }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center sm:p-6" onClick={onClose}>
      <div id="occ-participant-sheet" className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-white p-4 sm:rounded-3xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-start gap-3">
          <PersonAvatar url={p.person_image} name={p.person_name} size={56} />
          <div className="min-w-0 flex-1">
            <p className="truncate text-base font-extrabold">{p.person_name}</p>
            <p className="truncate text-xs font-bold text-slate-400">{p.class_name} · {p.service_name}</p>
            <div className="mt-1 flex flex-wrap items-center gap-1.5">
              <RegStatusBadge status={p.status} />
              <span className="badge bg-slate-100 text-slate-500">{p.source === 'self' ? 'سجّل بنفسه' : `أضافه ${p.registered_by_name ?? 'خادم'}`}</span>
            </div>
          </div>
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        <div className="mt-3 flex gap-2">
          {p.phone && <a href={`tel:${p.phone}`} className="btn-secondary flex flex-1 items-center justify-center gap-1.5 !py-2 text-sm"><Phone className="h-4 w-4" /> اتصال</a>}
          <button type="button" onClick={() => setShowTicket((v) => !v)} className="btn-secondary flex flex-1 items-center justify-center gap-1.5 !py-2 text-sm">
            <Ticket className="h-4 w-4" /> {showTicket ? 'إخفاء التذكرة' : 'التذكرة'}
          </button>
        </div>

        {showTicket && (
          <div className="mt-3">
            <TicketCard code={p.ticket_code} personName={p.person_name} title={occasion.title} when={whenLabel(occasion)} place={occasion.location} status={p.status} id="occ-participant-ticket" />
          </div>
        )}

        {/* status stepper */}
        {canManage && (
          <div className="mt-4">
            <p className="mb-1.5 text-xs font-extrabold text-slate-500">الحالة</p>
            <div id="occ-status-stepper" className="grid grid-cols-4 gap-1.5">
              {REG_STATUS_ORDER.map((s) => {
                const active = p.status === s;
                const tone = s === 'pending' ? 'bg-amber-500' : s === 'confirmed' ? 'bg-emerald-600' : s === 'checked_in' ? 'bg-cyan-600' : 'bg-slate-500';
                return (
                  <button key={s} type="button" disabled={!!busy} onClick={() => setStatus(s)} aria-pressed={active}
                    className={`flex h-14 flex-col items-center justify-center gap-0.5 rounded-xl text-[11px] font-extrabold transition active:scale-95 ${active ? `${tone} text-white shadow ring-2 ring-offset-1 ring-slate-200` : 'bg-white text-slate-600 border border-slate-200'}`}>
                    {busy === s ? <Loader2 className="h-4 w-4 animate-spin" /> : <RegStatusIcon status={s} className="h-4 w-4" />}
                    {REG_STATUS_LABELS[s]}
                  </button>
                );
              })}
            </div>
            {occasion.checkin_points > 0 && <p className="mt-1 text-[11px] font-bold text-slate-400">تسجيل الدخول يمنح +{occasion.checkin_points} نقطة (تُسترد عند التراجع).</p>}
          </div>
        )}

        {/* checklist */}
        {items.length > 0 && (
          <div className="mt-4">
            <p className="mb-1.5 flex items-center gap-1.5 text-xs font-extrabold text-slate-500"><ListChecks className="h-4 w-4" /> قائمة التحقق · {p.checklist_done} / {items.length}</p>
            <div id="occ-participant-checklist" className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
              {items.map((it) => {
                const done = p.checklist_items.includes(it.id);
                return (
                  <button key={it.id} type="button" disabled={!canManage || busy === it.id} onClick={() => toggleItem(it)} aria-pressed={done}
                    className="flex w-full items-center gap-3 px-3 py-2.5 text-right hover:bg-cyan-50/40 disabled:opacity-70">
                    <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-lg border-2 ${done ? 'border-emerald-500 bg-emerald-500 text-white' : 'border-slate-300 bg-white'}`}>
                      {busy === it.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : done && <Check className="h-4 w-4" />}
                    </span>
                    <span className={`flex-1 text-sm font-bold ${done ? 'text-slate-500 line-through' : 'text-slate-700'}`}>{it.label}</span>
                    {it.required && !done && <span className="badge bg-amber-50 text-amber-700">مطلوب</span>}
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {/* note */}
        {canManage && (
          <div className="mt-4">
            <p className="mb-1.5 flex items-center gap-1.5 text-xs font-extrabold text-slate-500"><StickyNote className="h-4 w-4" /> ملاحظة</p>
            <textarea id="occ-participant-note" className="input-field text-sm" rows={2} placeholder="مثال: دفع ٢٠٠ ج · يحتاج دواء…" value={note} onChange={(e) => setNote(e.target.value)} onBlur={saveNote} />
          </div>
        )}

        {canManage && (
          <button id="occ-participant-remove" type="button" disabled={!!busy} onClick={remove} className="mt-4 flex w-full items-center justify-center gap-1.5 rounded-xl bg-red-50 py-2.5 text-sm font-extrabold text-red-600 hover:bg-red-100">
            {busy === 'remove' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />} حذف من المشاركين
          </button>
        )}
      </div>
    </div>
  );
}
