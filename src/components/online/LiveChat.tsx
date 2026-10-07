'use client';

// ---------- Live chat panel (shared by the servant control room and the child room) ----------
// Presentational: receives the messages + a `send` callback. Auto-scrolls to
// the newest message, marks servant messages with a badge, lets the caller
// delete (servant) when `onDelete` is given. Realtime is handled by the parent.

import { useEffect, useRef, useState } from 'react';
import Image from 'next/image';
import { Send, Loader2, User, Trash2, MessageCircle, Lock } from 'lucide-react';
import { fmtTime } from '@/components/online/OnlineBits';
import type { RoomMessage } from '@/lib/online-classes';

export default function LiveChat({
  messages, disabled, disabledText, onSend, onDelete, meIsServant = false, height = 'h-[52vh]',
}: {
  messages: RoomMessage[];
  disabled?: boolean;
  disabledText?: string;
  onSend: (body: string) => Promise<void>;
  onDelete?: (m: RoomMessage) => Promise<void>;
  meIsServant?: boolean;
  height?: string;
}) {
  const [text, setText] = useState('');
  const [sending, setSending] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const stickToBottom = useRef(true);

  useEffect(() => {
    const el = listRef.current;
    if (el && stickToBottom.current) el.scrollTop = el.scrollHeight;
  }, [messages.length]);

  const onScroll = () => {
    const el = listRef.current;
    if (!el) return;
    stickToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const body = text.trim();
    if (!body || sending) return;
    setSending(true);
    try {
      await onSend(body);
      setText('');
      stickToBottom.current = true;
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="card flex flex-col !p-0 overflow-hidden">
      <div ref={listRef} onScroll={onScroll} id="live-chat-list" className={`${height} overflow-y-auto bg-slate-50/60 p-3`}>
        {messages.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center text-slate-400">
            <MessageCircle className="mb-2 h-8 w-8 text-slate-300" />
            <p className="text-xs font-bold">لا رسائل بعد — كن أول من يكتب</p>
          </div>
        ) : (
          <ul className="space-y-2">
            {messages.map((m) => {
              const mine = meIsServant ? m.is_servant : m.mine;
              return (
                <li key={m.id} className={`flex items-end gap-2 ${mine ? 'flex-row-reverse' : ''}`}>
                  <div className="relative h-7 w-7 shrink-0 overflow-hidden rounded-full bg-slate-200">
                    {m.sender_image ? <Image src={m.sender_image} alt={m.sender_name ?? ''} fill sizes="28px" className="object-cover" /> : <User className="absolute inset-0 m-auto h-4 w-4 text-slate-500" />}
                  </div>
                  <div className={`group relative max-w-[78%] rounded-2xl px-3 py-2 text-sm shadow-sm ${m.is_servant ? 'bg-red-600 text-white' : mine ? 'bg-primary-600 text-white' : 'bg-white text-slate-800'}`}>
                    <p className={`mb-0.5 flex items-center gap-1 text-[10px] font-extrabold ${m.is_servant || mine ? 'text-white/80' : 'text-slate-500'}`}>
                      {m.sender_name ?? 'مخدوم'}
                      {m.is_servant && <span className="rounded-full bg-white/25 px-1.5 text-[9px]">خادم</span>}
                    </p>
                    <p className="whitespace-pre-wrap break-words leading-snug">{m.body}</p>
                    <p className={`mt-0.5 text-[9px] font-bold ${m.is_servant || mine ? 'text-white/70' : 'text-slate-400'}`}>{fmtTime(m.created_at)}</p>
                    {onDelete && (
                      <button type="button" aria-label="حذف" onClick={() => onDelete(m)}
                        className="absolute -top-2 -left-2 hidden rounded-full bg-white p-1 text-red-500 shadow ring-1 ring-slate-200 group-hover:block">
                        <Trash2 className="h-3 w-3" />
                      </button>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
      {disabled ? (
        <p className="flex items-center justify-center gap-1.5 border-t border-slate-100 bg-white px-3 py-2.5 text-xs font-bold text-slate-400">
          <Lock className="h-3.5 w-3.5" /> {disabledText ?? 'الدردشة مغلقة'}
        </p>
      ) : (
        <form onSubmit={submit} className="flex items-center gap-2 border-t border-slate-100 bg-white p-2">
          <input id="live-chat-input" className="input-field flex-1 !py-2 text-sm" placeholder="اكتب رسالة…" value={text} maxLength={1000}
            onChange={(e) => setText(e.target.value)} />
          <button id="live-chat-send" type="submit" disabled={!text.trim() || sending} aria-label="إرسال"
            className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-red-600 text-white disabled:opacity-40">
            {sending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4 -scale-x-100" />}
          </button>
        </form>
      )}
    </div>
  );
}
