'use client';

// ---------- Child portal — الإشعارات (notification center) ----------
// The child's received notifications: unread count, list, read / unread
// state, tap → opens the linked page. «تفعيل إشعارات الجهاز» card on top.

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Bell, CheckCheck, Loader2, Inbox } from 'lucide-react';
import ChildShell, { useChildNotifications } from '@/components/child/ChildShell';
import { PageTitle } from '@/components/child/ChildBits';
import { NotifCard, PushToggle, Toast, isInternalLink } from '@/components/notifications/NotifBits';
import { useChild } from '@/lib/child-context';
import { createClient } from '@/lib/supabase/client';
import { childMarkRead, notifErrorMessage, type InboxItem } from '@/lib/notifications';

export default function ChildNotificationsPage() {
  return (
    <ChildShell>
      <Content />
    </ChildShell>
  );
}

function Content() {
  const router = useRouter();
  const { token, patchNotifications } = useChild();
  const { list, unread } = useChildNotifications();
  const [supabase] = useState(() => createClient());
  const [onlyUnread, setOnlyUnread] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const flash = (m: string) => { setToast(m); setTimeout(() => setToast(null), 2500); };

  const items = useMemo(() => (list ?? []).filter((i) => !onlyUnread || !i.read_at), [list, onlyUnread]);

  const open = (item: InboxItem) => {
    if (!token) return;
    if (!item.read_at) {
      patchNotifications((l) => l.map((x) => x.id === item.id ? { ...x, read_at: new Date().toISOString() } : x));
      childMarkRead(supabase, token, [item.id]).catch(() => {});
    }
    if (item.link_url) {
      if (isInternalLink(item.link_url)) router.push(item.link_url.startsWith('/child') ? item.link_url : '/child');
      else window.open(item.link_url, '_blank', 'noopener');
    }
  };

  const readAll = async () => {
    if (!token) return;
    try {
      await childMarkRead(supabase, token);
      patchNotifications((l) => l.map((x) => ({ ...x, read_at: x.read_at ?? new Date().toISOString() })));
      flash('تم تعليم الكل كمقروء');
    } catch (e) { flash(notifErrorMessage(e)); }
  };

  return (
    <>
      <PageTitle
        icon={<Bell className="h-5 w-5 text-indigo-600" />}
        title="الإشعارات"
        sub={unread > 0 ? `${unread} غير مقروء` : 'كل الإشعارات مقروءة'}
      />

      {token && <PushToggle supabase={supabase} owner={{ kind: 'child', token }} />}

      <div className="mb-3 flex items-center gap-2">
        <button type="button" onClick={() => setOnlyUnread(false)} aria-pressed={!onlyUnread}
          className={`rounded-full px-3 py-1.5 text-xs font-extrabold ${!onlyUnread ? 'bg-indigo-600 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>الكل</button>
        <button type="button" onClick={() => setOnlyUnread(true)} aria-pressed={onlyUnread}
          className={`rounded-full px-3 py-1.5 text-xs font-extrabold ${onlyUnread ? 'bg-indigo-600 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>غير المقروء ({unread})</button>
        {unread > 0 && (
          <button id="child-notif-read-all" type="button" onClick={readAll} className="mr-auto flex items-center gap-1 rounded-full bg-slate-100 px-3 py-1.5 text-xs font-extrabold text-slate-600 hover:bg-slate-200">
            <CheckCheck className="h-4 w-4" /> الكل مقروء
          </button>
        )}
      </div>

      {list === null ? (
        <div className="flex justify-center py-12"><Loader2 className="h-7 w-7 animate-spin text-indigo-500" /></div>
      ) : items.length === 0 ? (
        <div className="card py-10 text-center">
          <Inbox className="mx-auto mb-2 h-8 w-8 text-slate-300" />
          <p className="text-sm font-extrabold text-slate-600">{onlyUnread ? 'لا توجد إشعارات غير مقروءة' : 'لا توجد إشعارات بعد'}</p>
          <p className="mt-1 text-xs font-bold text-slate-400">ستصلك هنا إشعارات الخدام والتذكيرات</p>
        </div>
      ) : (
        <ul id="child-notif-list" className="space-y-2">
          {items.map((i) => <li key={i.id}><NotifCard item={i} onOpen={open} /></li>)}
        </ul>
      )}
      <Toast msg={toast} />
    </>
  );
}
