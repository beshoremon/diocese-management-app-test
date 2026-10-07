'use client';

// ---------- Checklist definition (leader) ----------
// Add / rename / toggle required / reorder / delete the items of the
// occasion's checklist, plus a per-item progress bar: how many active
// participants have it done.

import { useState } from 'react';
import { Plus, Loader2, Trash2, ChevronUp, ChevronDown, Check, ListChecks } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth-context';
import {
  addChecklistItem, updateChecklistItem, deleteChecklistItem, occasionErrorMessage, CHECKLIST_SUGGESTIONS,
  type Occasion, type ChecklistItem, type Participant,
} from '@/lib/occasions';

export default function ChecklistTab({ occasion, items, participants, canEdit, onChanged, flash }: {
  occasion: Occasion; items: ChecklistItem[]; participants: Participant[]; canEdit: boolean;
  onChanged: (items: ChecklistItem[]) => void; flash: (m: string) => void;
}) {
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ id: string; label: string } | null>(null);

  const active = participants.filter((p) => p.status !== 'cancelled');

  const add = async (text: string) => {
    const v = text.trim();
    if (!v) return;
    setBusy('add');
    try {
      const last = items[items.length - 1];
      const it = await addChecklistItem(supabase, occasion.id, v, true, (last?.sort_order ?? 0) + 1, profile?.id);
      onChanged([...items, it]);
      setLabel('');
    } catch (e) { flash(occasionErrorMessage(e, 'تعذر الإضافة')); }
    finally { setBusy(null); }
  };

  const patch = async (it: ChecklistItem, p: Partial<Pick<ChecklistItem, 'label' | 'required'>>) => {
    setBusy(it.id);
    const prev = items;
    onChanged(items.map((x) => (x.id === it.id ? { ...x, ...p } : x)));
    try { await updateChecklistItem(supabase, it.id, p); }
    catch (e) { onChanged(prev); flash(occasionErrorMessage(e, 'تعذر التعديل')); }
    finally { setBusy(null); }
  };

  const move = async (idx: number, dir: -1 | 1) => {
    const j = idx + dir;
    if (j < 0 || j >= items.length) return;
    const next = [...items];
    [next[idx], next[j]] = [next[j], next[idx]];
    const fixed = next.map((x, i) => ({ ...x, sort_order: i + 1 }));
    setBusy(items[idx].id);
    onChanged(fixed);
    try {
      await Promise.all(fixed.filter((x, i) => x.sort_order !== items[i]?.sort_order || x.id !== items[i]?.id)
        .map((x) => updateChecklistItem(supabase, x.id, { sort_order: x.sort_order })));
    } catch (e) { onChanged(items); flash(occasionErrorMessage(e, 'تعذر الترتيب')); }
    finally { setBusy(null); }
  };

  const remove = async (it: ChecklistItem) => {
    if (!confirm(`حذف «${it.label}» من قائمة التحقق؟ ستُحذف علامات المشاركين عليه.`)) return;
    setBusy(it.id);
    try { await deleteChecklistItem(supabase, it.id); onChanged(items.filter((x) => x.id !== it.id)); }
    catch (e) { flash(occasionErrorMessage(e, 'تعذر الحذف')); }
    finally { setBusy(null); }
  };

  const suggestions = CHECKLIST_SUGGESTIONS.filter((s) => !items.some((i) => i.label === s));

  return (
    <div className="space-y-3">
      {canEdit && (
        <div className="card !p-3 space-y-2">
          <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); add(label); }}>
            <input id="occ-checklist-new" className="input-field !py-2 text-sm" placeholder="عنصر جديد (مثال: قميص الرحلة)" value={label} onChange={(e) => setLabel(e.target.value)} />
            <button type="submit" disabled={busy === 'add' || !label.trim()} aria-label="إضافة" className="btn-primary !from-cyan-600 !to-cyan-500 !px-3 !py-2">
              {busy === 'add' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
            </button>
          </form>
          {suggestions.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {suggestions.map((s) => (
                <button key={s} type="button" onClick={() => add(s)} disabled={!!busy} className="rounded-full border border-dashed border-cyan-300 bg-cyan-50/50 px-3 py-1 text-xs font-bold text-cyan-700">+ {s}</button>
              ))}
            </div>
          )}
        </div>
      )}

      {items.length === 0 ? (
        <div className="card py-10 text-center text-slate-400">
          <ListChecks className="mx-auto mb-2 h-8 w-8 text-cyan-200" />
          <p className="text-sm font-bold">لا توجد عناصر في قائمة التحقق</p>
        </div>
      ) : (
        <div id="occ-checklist-items" className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
          {items.map((it, idx) => {
            const done = active.filter((p) => p.checklist_items.includes(it.id)).length;
            const pct = active.length ? Math.round((done / active.length) * 100) : 0;
            return (
              <div key={it.id} id={`occ-checklist-item-${it.id}`} className="px-3 py-2.5">
                <div className="flex items-center gap-2">
                  {editing?.id === it.id ? (
                    <input autoFocus className="input-field !py-1.5 text-sm" value={editing.label}
                      onChange={(e) => setEditing({ id: it.id, label: e.target.value })}
                      onBlur={() => { if (editing.label.trim() && editing.label.trim() !== it.label) patch(it, { label: editing.label.trim() }); setEditing(null); }}
                      onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') setEditing(null); }} />
                  ) : (
                    <button type="button" disabled={!canEdit} onClick={() => setEditing({ id: it.id, label: it.label })} className="min-w-0 flex-1 truncate text-right text-sm font-extrabold text-slate-700">
                      {it.label}
                    </button>
                  )}
                  {canEdit && (
                    <>
                      <button type="button" onClick={() => patch(it, { required: !it.required })} disabled={busy === it.id}
                        className={`badge ${it.required ? 'bg-amber-100 text-amber-700' : 'bg-slate-100 text-slate-500'}`}>{it.required ? 'مطلوب' : 'اختياري'}</button>
                      <button type="button" onClick={() => move(idx, -1)} disabled={idx === 0 || !!busy} aria-label="لأعلى" className="rounded-full p-1 text-slate-400 hover:bg-slate-100 disabled:opacity-30"><ChevronUp className="h-4 w-4" /></button>
                      <button type="button" onClick={() => move(idx, 1)} disabled={idx === items.length - 1 || !!busy} aria-label="لأسفل" className="rounded-full p-1 text-slate-400 hover:bg-slate-100 disabled:opacity-30"><ChevronDown className="h-4 w-4" /></button>
                      <button type="button" onClick={() => remove(it)} disabled={busy === it.id} aria-label="حذف" className="rounded-full p-1 text-red-500 hover:bg-red-50">{busy === it.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}</button>
                    </>
                  )}
                </div>
                <div className="mt-1.5 flex items-center gap-2">
                  <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-slate-100"><div className={`h-full rounded-full ${pct === 100 && active.length > 0 ? 'bg-emerald-500' : 'bg-cyan-500'}`} style={{ width: `${pct}%` }} /></div>
                  <span className="flex items-center gap-1 text-[11px] font-bold text-slate-500 tabular-nums"><Check className="h-3 w-3" /> {done} / {active.length}</span>
                </div>
              </div>
            );
          })}
        </div>
      )}
      <p className="text-[11px] font-bold text-slate-400">تُعلَّم العناصر لكل مشارك من تبويب «المشاركون» ← اختر المشارك.</p>
    </div>
  );
}
