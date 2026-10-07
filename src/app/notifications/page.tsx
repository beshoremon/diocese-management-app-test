'use client';

// ---------- NOTIFICATIONS MODULE — HISTORY (السجل) ----------
// Sent / scheduled / failed / cancelled sends visible in my scope, with the
// recipients count, read count and device-push count. Scheduled sends can
// be cancelled; the creator / managers can delete a row. Realtime.

import { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { Loader2, Send, Users, Clock, Eye, Smartphone, XCircle, Trash2, Zap, Filter, ExternalLink, Plus } from 'lucide-react';
import AppShell from '@/components/AppShell';
import { NotifHeader, StatusBadge, Toast, PushToggle } from '@/components/notifications/NotifBits';
import { useAuth } from '@/lib/auth-context';
import { createClient } from '@/lib/supabase/client';
import { useDebouncedRealtime } from '@/lib/realtime';
import { kickDispatcher } from '@/lib/push';
import {
  fetchHistory, cancelNotification, deleteNotification, notifErrorMessage, fmtDateTime,
  type NotifHistoryItem, type NotifStatus,
} from '@/lib/notifications';

type Filter = 'all' | NotifStatus | 'automation';

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'الكل' },
  { value: 'sent', label: 'المُرسَل' },
  { value: 'scheduled', label: 'المجدول' },
  { value: 'failed', label: 'فشل' },
  { value: 'automation', label: 'تلقائي' },
];

export default function NotificationsHistoryPage() {
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const approved = profile?.status === 'approved';
  const [rows, setRows] = useState<NotifHistoryItem[] | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [busy, setBusy] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<{ id: string; action: 'cancel' | 'delete' } | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const flash = (m: string) => { setToast(m); setTimeout(() => setToast(null), 3200); };

  const load = useCallback(async () => {
    if (!approved) return;
    try { setRows(await fetchHistory(supabase, 120)); setError(null); }
    catch (e) { setError(notifErrorMessage(e, 'تعذر تحميل السجل')); setRows([]); }
  }, [supabase, approved]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => { kickDispatcher(); }, []);
  useDebouncedRealtime(supabase, 'notif-history', [{ table: 'notifications' }, { table: 'notification_recipients' }], load, { enabled: approved, delayMs: 900 });

  const filtered = useMemo(() => (rows ?? []).filter((r) =>
    filter === 'all' ? true : filter === 'automation' ? r.source === 'automation' : r.status === filter
  ), [rows, filter]);

  const counts = useMemo(() => ({
    sent: (rows ?? []).filter((r) => r.status === 'sent').length,
    scheduled: (rows ?? []).filter((r) => r.status === 'scheduled').length,
    failed: (rows ?? []).filter((r) => r.status === 'failed').length,
  }), [rows]);

  const run = async () => {
    if (!confirm) return;
    setBusy(confirm.id);
    try {
      if (confirm.action === 'cancel') { await cancelNotification(supabase, confirm.id); flash('تم إلغاء الإرسال المجدول'); }
      else { await deleteNotification(supabase, confirm.id); flash('تم حذف الإشعار من السجل'); }
      setConfirm(null);
      load();
    } catch (e) { flash(notifErrorMessage(e)); }
    finally { setBusy(null); }
  };

  const canDelete = (r: NotifHistoryItem) => r.is_mine || (profile?.role !== 'class_servant');

  return (
    <AppShell>
      <NotifHeader title="السجل" />
      <PushToggle supabase={supabase} owner={{ kind: 'servant' }} compact />

      <section className="mb-3 grid grid-cols-3 gap-2">
        <Kpi icon={<Send className="h-4 w-4" />} label="مُرسَل" value={counts.sent} tone="emerald" />
        <Kpi icon={<Clock className="h-4 w-4" />} label="مجدول" value={counts.scheduled} tone="amber" />
        <Kpi icon={<XCircle className="h-4 w-4" />} label="فشل" value={counts.failed} tone="red" />
      </section>

      <Link id="notif-new-cta" href="/notifications/new" className="btn-primary mb-3 flex w-full items-center justify-center gap-2 !from-indigo-600 !to-indigo-500">
        <Plus className="h-5 w-5" /> إشعار جديد
      </Link>

      <div className="no-scrollbar mb-3 flex gap-1.5 overflow-x-auto">
        <span className="flex items-center text-slate-400"><Filter className="h-4 w-4" /></span>
        {FILTERS.map((f) => (
          <button key={f.value} type="button" onClick={() => setFilter(f.value)} aria-pressed={filter === f.value}
            className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-extrabold transition ${filter === f.value ? 'bg-indigo-600 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>
            {f.label}
          </button>
        ))}
      </div>

      {error && <p className="card mb-3 text-center text-xs font-bold text-amber-700">{error}</p>}

      {rows === null ? (
        <div className="flex justify-center py-12"><Loader2 className="h-7 w-7 animate-spin text-indigo-500" /></div>
      ) : filtered.length === 0 ? (
        <div className="card py-10 text-center">
          <Send className="mx-auto mb-2 h-8 w-8 text-slate-300" />
          <p className="text-sm font-extrabold text-slate-600">لا توجد إشعارات{filter !== 'all' ? ' بهذا الفلتر' : ' بعد'}</p>
          <p className="mt-1 text-xs font-bold text-slate-400">ابدأ بإرسال إشعار من تبويب «إرسال»</p>
        </div>
      ) : (
        <ul id="notif-history-list" className="space-y-2">
          {filtered.map((r) => (
            <li key={r.id} className="card !p-3">
              <div className="flex items-start gap-3">
                {r.image_url ? (
                  <div className="relative h-12 w-12 shrink-0 overflow-hidden rounded-xl ring-1 ring-slate-200">
                    <Image src={r.image_url} alt="" fill sizes="48px" className="object-cover" />
                  </div>
                ) : (
                  <span className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-xl ${r.source === 'automation' ? 'bg-violet-100 text-violet-600' : 'bg-indigo-100 text-indigo-600'}`}>
                    {r.source === 'automation' ? <Zap className="h-5 w-5" /> : <Send className="h-5 w-5" />}
                  </span>
                )}
                <div className="min-w-0 flex-1">
                  <div className="flex items-start gap-2">
                    <p className="flex-1 truncate text-sm font-extrabold text-slate-800">{r.title}</p>
                    <StatusBadge status={r.status} />
                  </div>
                  {r.body && <p className="mt-0.5 text-xs text-slate-500 line-clamp-2">{r.body}</p>}
                  <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] font-bold text-slate-500">
                    <span className="flex items-center gap-1"><Users className="h-3.5 w-3.5" /> {r.target_label}</span>
                    <span className="flex items-center gap-1 tabular-nums">
                      <Clock className="h-3.5 w-3.5" /> {r.status === 'scheduled' ? `موعده ${fmtDateTime(r.scheduled_at)}` : fmtDateTime(r.sent_at ?? r.created_at)}
                    </span>
                  </div>
                  <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] font-bold text-slate-400">
                    {r.status !== 'scheduled' && r.status !== 'cancelled' && (
                      <>
                        <span className="tabular-nums">{r.recipients_count} مستلم</span>
                        <span className="flex items-center gap-1 tabular-nums"><Eye className="h-3.5 w-3.5" /> {r.read_count} قرأ</span>
                        <span className="flex items-center gap-1 tabular-nums"><Smartphone className="h-3.5 w-3.5" /> {r.push_sent} جهاز</span>
                      </>
                    )}
                    {r.source === 'automation' ? (
                      <span className="flex items-center gap-1 text-violet-600"><Zap className="h-3.5 w-3.5" /> {r.automation_name ?? 'تلقائي'}</span>
                    ) : r.sender_name && <span>بواسطة {r.sender_name}</span>}
                    {r.error === 'no_recipients' && <span className="text-red-600">لا يوجد مستلمون في هذا النطاق</span>}
                    {r.link_url && <span className="flex items-center gap-0.5"><ExternalLink className="h-3 w-3" /> {r.link_url}</span>}
                  </div>
                </div>
              </div>
              {(r.can_cancel || canDelete(r)) && (
                <div className="mt-2 flex justify-end gap-2">
                  {r.can_cancel && (
                    <button type="button" onClick={() => setConfirm({ id: r.id, action: 'cancel' })} disabled={busy === r.id}
                      className="flex items-center gap-1 rounded-lg bg-amber-50 px-2.5 py-1.5 text-[11px] font-extrabold text-amber-700 hover:bg-amber-100">
                      <XCircle className="h-3.5 w-3.5" /> إلغاء الجدولة
                    </button>
                  )}
                  {canDelete(r) && (
                    <button type="button" onClick={() => setConfirm({ id: r.id, action: 'delete' })} disabled={busy === r.id}
                      className="flex items-center gap-1 rounded-lg bg-slate-100 px-2.5 py-1.5 text-[11px] font-extrabold text-slate-600 hover:bg-red-50 hover:text-red-600">
                      <Trash2 className="h-3.5 w-3.5" /> حذف
                    </button>
                  )}
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {confirm && (
        <div className="fixed inset-0 z-[80] flex items-end justify-center bg-black/45 p-4 sm:items-center" onClick={() => setConfirm(null)}>
          <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-2xl" onClick={(e) => e.stopPropagation()}>
            <p className="text-center text-sm font-extrabold text-slate-800">
              {confirm.action === 'cancel' ? 'إلغاء الإرسال المجدول؟' : 'حذف الإشعار من السجل؟'}
            </p>
            <p className="mt-1 text-center text-xs font-bold text-slate-400">
              {confirm.action === 'cancel' ? 'لن يُرسل هذا الإشعار في موعده' : 'سيُحذف من سجلك ومن قائمة الواردة لدى المستلمين'}
            </p>
            <div className="mt-4 grid grid-cols-2 gap-2">
              <button type="button" onClick={() => setConfirm(null)} className="btn-secondary !py-2.5 text-sm">رجوع</button>
              <button id="notif-confirm-btn" type="button" onClick={run} disabled={!!busy}
                className={`btn-primary !py-2.5 text-sm ${confirm.action === 'delete' ? '!from-red-600 !to-red-500' : '!from-amber-600 !to-amber-500'}`}>
                {busy ? <Loader2 className="mx-auto h-4 w-4 animate-spin" /> : confirm.action === 'cancel' ? 'إلغاء الجدولة' : 'حذف'}
              </button>
            </div>
          </div>
        </div>
      )}

      <Toast msg={toast} />
    </AppShell>
  );
}

function Kpi({ icon, label, value, tone }: { icon: React.ReactNode; label: string; value: number; tone: 'emerald' | 'amber' | 'red' }) {
  const cls = { emerald: 'bg-emerald-50 text-emerald-700', amber: 'bg-amber-50 text-amber-700', red: 'bg-red-50 text-red-700' }[tone];
  return (
    <div className={`rounded-2xl px-3 py-2.5 ${cls}`}>
      <p className="flex items-center gap-1 text-[11px] font-extrabold opacity-80">{icon} {label}</p>
      <p className="mt-0.5 text-xl font-extrabold tabular-nums">{value}</p>
    </div>
  );
}
