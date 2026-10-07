'use client';

// ---------- Announcements & reminders (leader) ----------
// Leaders write announcements / reminders for everyone who sees the
// occasion (RLS insert = scope_contains). Status notifications written
// by the RPCs for single participants are listed read-only below.

import { useState } from 'react';
import { Megaphone, BellRing, Loader2, Send, Trash2, Info } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth-context';
import {
  sendAnnouncement, deleteNotification, occasionErrorMessage, fmtDateTime, NOTIF_KIND_LABELS,
  type Occasion, type OccasionNotification, type Participant,
} from '@/lib/occasions';

export default function AnnouncementsTab({ occasion, notifications, participants, canEdit, onChanged, flash }: {
  occasion: Occasion; notifications: OccasionNotification[]; participants: Participant[]; canEdit: boolean;
  onChanged: (list: OccasionNotification[]) => void; flash: (m: string) => void;
}) {
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const [body, setBody] = useState('');
  const [kind, setKind] = useState<'announcement' | 'reminder'>('announcement');
  const [busy, setBusy] = useState<string | null>(null);

  const byReg = new Map(participants.map((p) => [p.id, p]));
  const broadcasts = notifications.filter((n) => n.registration_id === null);
  const statuses = notifications.filter((n) => n.registration_id !== null);

  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!body.trim() || !profile) return;
    setBusy('send');
    try {
      const n = await sendAnnouncement(supabase, occasion.id, body, kind, profile.id);
      onChanged([n, ...notifications]);
      setBody('');
      flash(kind === 'reminder' ? 'تم إرسال التذكير' : 'تم نشر الإعلان');
    } catch (err) { flash(occasionErrorMessage(err, 'تعذر الإرسال')); }
    finally { setBusy(null); }
  };

  const remove = async (n: OccasionNotification) => {
    if (!confirm('حذف هذا الإعلان؟')) return;
    setBusy(n.id);
    try { await deleteNotification(supabase, n.id); onChanged(notifications.filter((x) => x.id !== n.id)); }
    catch (err) { flash(occasionErrorMessage(err, 'تعذر الحذف')); }
    finally { setBusy(null); }
  };

  const QUICK = [
    'تذكير: التجمع قبل الموعد بنصف ساعة',
    'لا تنسَ إحضار الكارت والتذكرة الإلكترونية',
    'آخر موعد للتسجيل يقترب — سجّل الآن',
  ];

  return (
    <div className="space-y-3">
      {canEdit && (
        <form onSubmit={send} className="card !p-3 space-y-2">
          <div className="grid grid-cols-2 gap-1.5">
            {(['announcement', 'reminder'] as const).map((k) => (
              <button key={k} type="button" onClick={() => setKind(k)} aria-pressed={kind === k}
                className={`flex h-10 items-center justify-center gap-1.5 rounded-xl text-xs font-extrabold ${kind === k ? 'bg-cyan-600 text-white' : 'bg-white text-slate-500 border border-slate-200'}`}>
                {k === 'announcement' ? <Megaphone className="h-4 w-4" /> : <BellRing className="h-4 w-4" />} {NOTIF_KIND_LABELS[k]}
              </button>
            ))}
          </div>
          <textarea id="occ-announce-body" className="input-field text-sm" rows={3} placeholder="اكتب الإعلان أو التذكير للمشاركين…" value={body} onChange={(e) => setBody(e.target.value)} />
          <div className="flex flex-wrap gap-1.5">
            {QUICK.map((q) => <button key={q} type="button" onClick={() => setBody(q)} className="rounded-full border border-dashed border-slate-300 px-3 py-1 text-[11px] font-bold text-slate-500 hover:bg-slate-50">{q}</button>)}
          </div>
          <button id="occ-announce-send" type="submit" disabled={busy === 'send' || !body.trim()} className="btn-primary flex w-full items-center justify-center gap-2 !from-cyan-600 !to-cyan-500 !py-2.5 text-sm">
            {busy === 'send' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />} إرسال لكل من يرى الفعالية
          </button>
        </form>
      )}

      <div>
        <p className="mb-1 text-xs font-extrabold text-slate-500">الإعلانات والتذكيرات</p>
        {broadcasts.length === 0 ? (
          <div className="card py-8 text-center text-slate-400"><Megaphone className="mx-auto mb-2 h-8 w-8 text-cyan-200" /><p className="text-sm font-bold">لا توجد إعلانات بعد</p></div>
        ) : (
          <div id="occ-announcements" className="space-y-2">
            {broadcasts.map((n) => (
              <div key={n.id} id={`occ-notif-${n.id}`} className={`card flex items-start gap-3 !p-3 ${n.kind === 'reminder' ? 'ring-1 ring-amber-100' : ''}`}>
                <span className={`rounded-xl p-2 ${n.kind === 'reminder' ? 'bg-amber-50 text-amber-600' : 'bg-cyan-50 text-cyan-600'}`}>
                  {n.kind === 'reminder' ? <BellRing className="h-5 w-5" /> : <Megaphone className="h-5 w-5" />}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="whitespace-pre-wrap text-sm font-bold text-slate-700">{n.body}</p>
                  <p className="mt-1 text-[11px] font-bold text-slate-400">{NOTIF_KIND_LABELS[n.kind]} · {fmtDateTime(n.created_at)}</p>
                </div>
                {canEdit && (
                  <button type="button" onClick={() => remove(n)} disabled={busy === n.id} aria-label="حذف" className="rounded-full p-1.5 text-red-500 hover:bg-red-50">
                    {busy === n.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {statuses.length > 0 && (
        <div>
          <p className="mb-1 flex items-center gap-1 text-xs font-extrabold text-slate-500"><Info className="h-3.5 w-3.5" /> سجل حالات المشاركين (تلقائي)</p>
          <div id="occ-status-log" className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
            {statuses.slice(0, 40).map((n) => (
              <div key={n.id} className="flex items-start gap-2 px-3 py-2">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-xs font-bold text-slate-600">{byReg.get(n.registration_id!)?.person_name ?? 'مشارك'} — {n.body}</p>
                </div>
                <span className="shrink-0 text-[10px] font-bold text-slate-400">{fmtDateTime(n.created_at)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
