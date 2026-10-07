'use client';

// ---------- NOTIFICATIONS MODULE — SERVANT INBOX (الواردة) ----------
// The servant's own received notifications (staff broadcasts + automations
// aimed at class servants). Read / unread, «mark all read», tap → opens the
// linked page. Realtime on notification_recipients + SW push messages.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { BellRing, CheckCheck, Loader2, Inbox } from 'lucide-react';
import AppShell from '@/components/AppShell';
import { NotifHeader, NotifCard, Toast, PushToggle, isInternalLink } from '@/components/notifications/NotifBits';
import { useAuth } from '@/lib/auth-context';
import { createClient } from '@/lib/supabase/client';
import { useDebouncedRealtime } from '@/lib/realtime';
import { fetchInbox, markRead, notifErrorMessage, type InboxItem } from '@/lib/notifications';

export default function ServantInboxPage() {
  const router = useRouter();
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const approved = profile?.status === 'approved';
  const [items, setItems] = useState<InboxItem[] | null>(null);
  const [onlyUnread, setOnlyUnread] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const flash = (m: string) => { setToast(m); setTimeout(() => setToast(null), 2500); };

  const load = useCallback(async () => {
    if (!approved) return;
    try { setItems(await fetchInbox(supabase, 100)); }
    catch (e) { flash(notifErrorMessage(e, 'تعذر التحميل')); setItems([]); }
  }, [supabase, approved]);
  useEffect(() => { load(); }, [load]);
  useDebouncedRealtime(supabase, 'notif-inbox', [{ table: 'notification_recipients' }], load, { enabled: approved, delayMs: 700 });

  // the service worker tells us when a push arrived
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    const h = (e: MessageEvent) => { if (e.data?.type === 'push') load(); };
    navigator.serviceWorker.addEventListener('message', h);
    return () => navigator.serviceWorker.removeEventListener('message', h);
  }, [load]);

  const unread = useMemo(() => (items ?? []).filter((i) => !i.read_at).length, [items]);
  const list = useMemo(() => (items ?? []).filter((i) => !onlyUnread || !i.read_at), [items, onlyUnread]);

  const open = async (item: InboxItem) => {
    if (!item.read_at) {
      setItems((l) => (l ?? []).map((x) => x.id === item.id ? { ...x, read_at: new Date().toISOString() } : x));
      markRead(supabase, [item.id]).catch(() => {});
    }
    if (item.link_url) {
      if (isInternalLink(item.link_url)) router.push(item.link_url.startsWith('/child') ? '/notifications/inbox' : item.link_url);
      else window.open(item.link_url, '_blank', 'noopener');
    }
  };

  const readAll = async () => {
    try { await markRead(supabase); setItems((l) => (l ?? []).map((x) => ({ ...x, read_at: x.read_at ?? new Date().toISOString() }))); flash('تم تعليم الكل كمقروء'); }
    catch (e) { flash(notifErrorMessage(e)); }
  };

  return (
    <AppShell>
      <NotifHeader title="الواردة" back="/notifications" badge={unread > 0 ? <span className="badge bg-red-100 text-red-700 tabular-nums">{unread}</span> : undefined} />
      <PushToggle supabase={supabase} owner={{ kind: 'servant' }} />

      <div className="mb-3 flex items-center gap-2">
        <button type="button" onClick={() => setOnlyUnread(false)} aria-pressed={!onlyUnread}
          className={`rounded-full px-3 py-1.5 text-xs font-extrabold ${!onlyUnread ? 'bg-indigo-600 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>الكل</button>
        <button type="button" onClick={() => setOnlyUnread(true)} aria-pressed={onlyUnread}
          className={`rounded-full px-3 py-1.5 text-xs font-extrabold ${onlyUnread ? 'bg-indigo-600 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>غير المقروء ({unread})</button>
        {unread > 0 && (
          <button id="inbox-read-all" type="button" onClick={readAll} className="mr-auto flex items-center gap-1 rounded-full bg-slate-100 px-3 py-1.5 text-xs font-extrabold text-slate-600 hover:bg-slate-200">
            <CheckCheck className="h-4 w-4" /> تعليم الكل كمقروء
          </button>
        )}
      </div>

      {items === null ? (
        <div className="flex justify-center py-12"><Loader2 className="h-7 w-7 animate-spin text-indigo-500" /></div>
      ) : list.length === 0 ? (
        <div className="card py-10 text-center">
          <Inbox className="mx-auto mb-2 h-8 w-8 text-slate-300" />
          <p className="text-sm font-extrabold text-slate-600">{onlyUnread ? 'لا توجد إشعارات غير مقروءة' : 'لا توجد إشعارات واردة'}</p>
          <p className="mt-1 flex items-center justify-center gap-1 text-xs font-bold text-slate-400"><BellRing className="h-3.5 w-3.5" /> ستظهر هنا إشعارات المسؤولين والإشعارات التلقائية الموجهة لك</p>
        </div>
      ) : (
        <ul id="inbox-list" className="space-y-2">
          {list.map((i) => <li key={i.id}><NotifCard item={i} onOpen={open} /></li>)}
        </ul>
      )}
      <Toast msg={toast} />
    </AppShell>
  );
}
