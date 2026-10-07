'use client';

// ---------- Messages module (وحدة الرسائل) — client data layer ----------
// Everything goes through the SECURITY DEFINER RPCs of migration 0029.
//   servant side : chat_inbox · chat_thread · chat_send · chat_mark_read ·
//                  chat_staff_recipients · chat_audience_count · chat_unread_total
//   child portal : child_chat_overview · child_chat_messages · child_chat_send ·
//                  child_chat_mark_read · child_chat_unread (anon, token = national id)
//
// Buckets (conversation keys):
//   'e:<enrollment_id>'  the conversation of one child (his enrollment)
//   's:<profile_id>'     my direct conversation with another servant
//   'b'                  the announcements (broadcasts) list

import type { SupabaseClient } from '@supabase/supabase-js';
import type { AppRole } from '@/lib/types';

export const MESSAGES_MIGRATION_HINT =
  'وحدة الرسائل تحتاج تشغيل تحديث قاعدة البيانات 0029_chat_messages.sql في Supabase';

export type ChatKind = 'child' | 'staff' | 'broadcast_children' | 'broadcast_staff';

export interface ChatMessage {
  id: string;
  kind: ChatKind;
  body: string;
  image_url: string | null;
  created_at: string;
  is_me: boolean;
  sender_kind: 'child' | 'servant';
  sender_id?: string | null;
  sender_name: string | null;
  sender_photo: string | null;
  sender_role: AppRole | null;
  is_broadcast: boolean;
  audience_label: string | null;
  can_delete?: boolean;
}

export interface ChatConversation {
  bucket: string;
  kind: 'child' | 'staff';
  enrollment_id: string | null;
  person_id: string | null;
  person_name: string | null;
  person_image: string | null;
  church_id: string | null;
  service_id: string | null;
  class_id: string | null;
  church_name: string | null;
  service_name: string | null;
  class_name: string | null;
  other_profile_id: string | null;
  other_name: string | null;
  other_photo: string | null;
  other_role: AppRole | null;
  last_body: string;
  last_image: string | null;
  last_at: string;
  last_is_me: boolean;
  last_sender_name: string | null;
  unread: number;
}

export interface ChatInbox {
  conversations: ChatConversation[];
  broadcasts_unread: number;
  broadcasts_last: {
    body: string; image_url: string | null; created_at: string; kind: ChatKind;
    sender_name: string | null; audience_label: string;
  } | null;
  total_unread: number;
}

export interface ChatThreadHeader {
  kind: 'child' | 'staff' | 'broadcast';
  // child
  enrollment_id?: string;
  person_id?: string;
  person_name?: string;
  person_image?: string | null;
  person_phone?: string | null;
  // staff
  other_profile_id?: string;
  other_name?: string;
  other_photo?: string | null;
  other_role?: AppRole;
  other_phone?: string | null;
  can_write?: boolean;
  // both
  church_name?: string | null;
  service_name?: string | null;
  class_name?: string | null;
}

export interface ChatThread {
  header: ChatThreadHeader;
  messages: ChatMessage[];
  has_more: boolean;
}

export interface StaffRecipient {
  id: string;
  full_name: string;
  role: AppRole;
  photo_url: string | null;
  church_id: string | null;
  service_id: string | null;
  class_id: string | null;
  church_name: string | null;
  service_name: string | null;
  class_name: string | null;
}

export type SendTarget = 'children' | 'staff';

export interface SendPayload {
  target: SendTarget;
  body: string;
  image_url?: string | null;
  /** selected recipients … */
  enrollment_ids?: string[];
  profile_ids?: string[];
  /** … OR an audience scope (all null = every church — owner only) */
  church_id?: string | null;
  service_id?: string | null;
  class_id?: string | null;
}

// ---------- error mapping ----------
const ERRORS: Record<string, string> = {
  module_not_visible: 'وحدة الرسائل غير مفعّلة لنطاقك',
  not_authenticated: 'يجب تسجيل الدخول',
  not_approved: 'حسابك لم يُعتمد بعد',
  empty_message: 'اكتب نص الرسالة أو أضف صورة',
  message_too_long: 'الرسالة طويلة جداً (الحد 4000 حرف)',
  too_many_recipients: 'عدد المستلمين كبير جداً — قسّم الإرسال',
  enrollment_not_found: 'المخدوم غير موجود',
  enrollment_not_visible: 'ليس لديك صلاحية على هذا المخدوم',
  scope_not_allowed: 'لا يمكنك الإرسال لهذا النطاق — اختر نطاقاً داخل صلاحيتك',
  scope_chain: 'النطاق غير متناسق (الفصل لا يتبع الخدمة أو الخدمة لا تتبع الكنيسة)',
  staff_not_reachable: 'يمكنك مراسلة الخدام التابعين لك فقط (أو الرد على من راسلك)',
  bad_target: 'نوع الإرسال غير صحيح',
  bad_bucket: 'المحادثة غير صحيحة',
  profile_not_found: 'الخادم غير موجود',
  rate_limited: 'أرسلت رسائل كثيرة — انتظر قليلاً ثم أعد المحاولة',
  invalid_code: 'الكود غير صالح',
  unknown_code: 'الكود غير مسجل',
};

export function isMessagesMigrationMissing(e: unknown): boolean {
  const m = String((e as { message?: string })?.message ?? e ?? '');
  return /chat_messages|chat_inbox|chat_thread|chat_send|child_chat_|Could not find the function|does not exist/i.test(m);
}

export function chatErrorMessage(e: unknown, fallback = 'حدث خطأ'): string {
  const msg = String((e as { message?: string })?.message ?? e ?? '');
  for (const k of Object.keys(ERRORS)) if (msg.includes(k)) return ERRORS[k];
  if (isMessagesMigrationMissing(e)) return MESSAGES_MIGRATION_HINT;
  return fallback;
}

// ---------- servant RPCs ----------
export async function fetchInbox(supabase: SupabaseClient): Promise<ChatInbox> {
  const { data, error } = await supabase.rpc('chat_inbox');
  if (error) throw error;
  const d = (data ?? {}) as Partial<ChatInbox>;
  return {
    conversations: (d.conversations ?? []) as ChatConversation[],
    broadcasts_unread: d.broadcasts_unread ?? 0,
    broadcasts_last: d.broadcasts_last ?? null,
    total_unread: d.total_unread ?? 0,
  };
}

export async function fetchUnreadTotal(supabase: SupabaseClient): Promise<number> {
  const { data, error } = await supabase.rpc('chat_unread_total');
  if (error) throw error;
  return (data as number) ?? 0;
}

export async function fetchThread(
  supabase: SupabaseClient, bucket: string, opts: { before?: string | null; limit?: number } = {}
): Promise<ChatThread> {
  const { data, error } = await supabase.rpc('chat_thread', {
    p_bucket: bucket, p_before: opts.before ?? null, p_limit: opts.limit ?? 50,
  });
  if (error) throw error;
  return data as ChatThread;
}

export async function sendMessage(supabase: SupabaseClient, p: SendPayload): Promise<{ sent: number; message_ids: string[] }> {
  const { data, error } = await supabase.rpc('chat_send', { p });
  if (error) throw error;
  return data as { sent: number; message_ids: string[] };
}

export async function markRead(supabase: SupabaseClient, bucket: string): Promise<void> {
  await supabase.rpc('chat_mark_read', { p_bucket: bucket });
}

export async function fetchStaffRecipients(supabase: SupabaseClient): Promise<StaffRecipient[]> {
  const { data, error } = await supabase.rpc('chat_staff_recipients');
  if (error) throw error;
  return (data ?? []) as StaffRecipient[];
}

export async function fetchAudienceCount(
  supabase: SupabaseClient, target: SendTarget, church: string | null, service: string | null, cls: string | null
): Promise<number> {
  const { data, error } = await supabase.rpc('chat_audience_count', {
    p_target: target, p_church: church, p_service: service, p_class: cls,
  });
  if (error) throw error;
  return (data as number) ?? 0;
}

export async function deleteMessage(supabase: SupabaseClient, id: string): Promise<boolean> {
  const { data, error } = await supabase.from('chat_messages').delete().eq('id', id).select('id');
  if (error) throw error;
  return (data ?? []).length > 0;
}

// ---------- child portal RPCs ----------
export interface ChildChatOverview {
  enrollment_id: string;
  created_at: string;
  church_name: string;
  church_logo: string | null;
  service_name: string;
  class_name: string;
  last_body: string | null;
  last_image: string | null;
  last_at: string | null;
  last_is_me: boolean | null;
  last_sender_name: string | null;
  unread: number;
}

export async function fetchChildChatOverview(supabase: SupabaseClient, token: string): Promise<ChildChatOverview[]> {
  const { data, error } = await supabase.rpc('child_chat_overview', { p_national_id: token });
  if (error) throw error;
  return (data ?? []) as ChildChatOverview[];
}

export async function fetchChildChatUnread(supabase: SupabaseClient, token: string): Promise<number> {
  const { data, error } = await supabase.rpc('child_chat_unread', { p_national_id: token });
  if (error) throw error;
  return (data as number) ?? 0;
}

export async function fetchChildChatMessages(
  supabase: SupabaseClient, token: string, enrollmentId: string, opts: { before?: string | null; limit?: number } = {}
): Promise<{ messages: ChatMessage[]; has_more: boolean }> {
  const { data, error } = await supabase.rpc('child_chat_messages', {
    p_national_id: token, p_enrollment: enrollmentId, p_before: opts.before ?? null, p_limit: opts.limit ?? 50,
  });
  if (error) throw error;
  return data as { messages: ChatMessage[]; has_more: boolean };
}

export async function childSendMessage(
  supabase: SupabaseClient, token: string, enrollmentId: string, body: string, imageUrl?: string | null
): Promise<string> {
  const { data, error } = await supabase.rpc('child_chat_send', {
    p_national_id: token, p_enrollment: enrollmentId, p_body: body, p_image_url: imageUrl ?? null,
  });
  if (error) throw error;
  return data as string;
}

export async function childMarkRead(supabase: SupabaseClient, token: string, enrollmentId: string): Promise<void> {
  await supabase.rpc('child_chat_mark_read', { p_national_id: token, p_enrollment: enrollmentId });
}

// ---------- small helpers ----------
export const KIND_LABELS: Record<ChatKind, string> = {
  child: 'رسالة مباشرة',
  staff: 'رسالة بين الخدام',
  broadcast_children: 'إعلان للمخدومين',
  broadcast_staff: 'إعلان للخدام',
};

/** short relative / absolute time for list rows (Cairo) */
export function fmtChatTime(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  const now = new Date();
  const sameDay = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Cairo' }).format(d)
    === new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Cairo' }).format(now);
  if (sameDay) {
    return new Intl.DateTimeFormat('ar-EG', { timeZone: 'Africa/Cairo', hour: 'numeric', minute: '2-digit', hour12: true }).format(d);
  }
  const diffDays = Math.round((now.getTime() - d.getTime()) / 86_400_000);
  if (diffDays < 7) {
    return new Intl.DateTimeFormat('ar-EG', { timeZone: 'Africa/Cairo', weekday: 'long' }).format(d);
  }
  return new Intl.DateTimeFormat('ar-EG', { timeZone: 'Africa/Cairo', day: 'numeric', month: 'short' }).format(d);
}

/** 'YYYY-MM-DD' Cairo day key for grouping a thread by day */
export function cairoDayKey(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Cairo' }).format(new Date(iso));
}

export function fmtDayHeading(iso: string): string {
  const d = new Date(iso);
  const key = cairoDayKey(iso);
  const today = cairoDayKey(new Date().toISOString());
  const yesterday = cairoDayKey(new Date(Date.now() - 86_400_000).toISOString());
  if (key === today) return 'اليوم';
  if (key === yesterday) return 'أمس';
  return new Intl.DateTimeFormat('ar-EG', { timeZone: 'Africa/Cairo', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(d);
}

export function fmtMsgTime(iso: string): string {
  return new Intl.DateTimeFormat('ar-EG', { timeZone: 'Africa/Cairo', hour: 'numeric', minute: '2-digit', hour12: true }).format(new Date(iso));
}

/** Group a chronologically ordered list into [dayHeading, messages][] */
export function groupByDay(messages: ChatMessage[]): { key: string; heading: string; items: ChatMessage[] }[] {
  const out: { key: string; heading: string; items: ChatMessage[] }[] = [];
  for (const m of messages) {
    const key = cairoDayKey(m.created_at);
    const last = out[out.length - 1];
    if (last && last.key === key) last.items.push(m);
    else out.push({ key, heading: fmtDayHeading(m.created_at), items: [m] });
  }
  return out;
}
