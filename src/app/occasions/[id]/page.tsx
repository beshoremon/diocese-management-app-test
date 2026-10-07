'use client';

// ---------- OCCASION DETAIL (leader) ----------
// Cover + info · dashboard counters · 4 tabs:
//   المشاركون  — list (filter by status · search), add, open a participant
//                sheet (status / checklist / ticket / remove)
//   الدخول     — QR scanner (ticket or card) + manual + name fallback
//   التحقق     — define the checklist items + progress per item
//   الإعلانات  — announcements / reminders + automatic status log
// Realtime on the occasion, its registrations, marks, items and
// notifications (debounced).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import {
  Loader2, Pencil, Trash2, Users, ScanLine, ListChecks, Megaphone, UserPlus, Search, ChevronLeft, Share2, Download, Check,
} from 'lucide-react';
import AppShell from '@/components/AppShell';
import {
  OccasionsHeader, OccasionCover, KindBadge, OccasionStatusBadge, OccasionInfoList, StatsRow, RegStatusBadge, PersonAvatar, Toast, scopeLabel,
} from '@/components/occasions/OccasionBits';
import OccasionFormModal from '@/components/occasions/OccasionFormModal';
import AddParticipantModal from '@/components/occasions/AddParticipantModal';
import ParticipantSheet from '@/components/occasions/ParticipantSheet';
import CheckinTab from '@/components/occasions/CheckinTab';
import ChecklistTab from '@/components/occasions/ChecklistTab';
import AnnouncementsTab from '@/components/occasions/AnnouncementsTab';
import { useStoreLookups } from '@/components/store/StoreBits';
import { useAuth } from '@/lib/auth-context';
import { createClient } from '@/lib/supabase/client';
import { useDebouncedRealtime } from '@/lib/realtime';
import {
  fetchOccasion, fetchParticipants, fetchChecklistItems, fetchNotifications, fetchOccasionCounts, fetchOccasionPermissions,
  deleteOccasion, occasionErrorMessage, remainingSeats, REG_STATUS_LABELS, NO_PERMISSIONS, ZERO_COUNTS, fmtDateShort,
  type Occasion, type Participant, type ChecklistItem, type OccasionNotification, type OccasionCounts, type OccasionPermissions, type RegistrationStatus,
} from '@/lib/occasions';

type Tab = 'participants' | 'checkin' | 'checklist' | 'announcements';
type PFilter = 'active' | RegistrationStatus | 'all';

export default function OccasionDetailPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const approved = profile?.status === 'approved';
  const { churches, services, classes } = useStoreLookups(supabase, approved);

  const [occ, setOcc] = useState<Occasion | null>(null);
  const [participants, setParticipants] = useState<Participant[]>([]);
  const [items, setItems] = useState<ChecklistItem[]>([]);
  const [notifs, setNotifs] = useState<OccasionNotification[]>([]);
  const [counts, setCounts] = useState<Omit<OccasionCounts, 'occasion_id'>>(ZERO_COUNTS);
  const [perms, setPerms] = useState<OccasionPermissions>(NO_PERMISSIONS);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [tab, setTab] = useState<Tab>('participants');
  const [pFilter, setPFilter] = useState<PFilter>('active');
  const [search, setSearch] = useState('');
  const [edit, setEdit] = useState(false);
  const [adding, setAdding] = useState(false);
  const [sheet, setSheet] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const flash = useCallback((m: string) => { setToast(m); setTimeout(() => setToast(null), 2500); }, []);

  const load = useCallback(async () => {
    try {
      const o = await fetchOccasion(supabase, id);
      if (!o) { setNotFound(true); setLoading(false); return; }
      setOcc(o);
      const [ps, its, ns, cs, pm] = await Promise.all([
        fetchParticipants(supabase, id), fetchChecklistItems(supabase, id), fetchNotifications(supabase, id),
        fetchOccasionCounts(supabase, [id]), fetchOccasionPermissions(supabase),
      ]);
      setParticipants(ps); setItems(its); setNotifs(ns); setPerms(pm);
      setCounts(cs.get(id) ?? ZERO_COUNTS);
    } catch (e) {
      flash(occasionErrorMessage(e, 'تعذر تحميل الفعالية'));
    } finally { setLoading(false); }
  }, [supabase, id, flash]);

  useEffect(() => { if (approved) load(); }, [approved, load]);
  useDebouncedRealtime(supabase, `occasion-${id}`, [
    { table: 'occasions', filter: `id=eq.${id}` },
    { table: 'occasion_registrations', filter: `occasion_id=eq.${id}` },
    { table: 'occasion_checklist_items', filter: `occasion_id=eq.${id}` },
    { table: 'occasion_checklist_marks' },
    { table: 'occasion_notifications', filter: `occasion_id=eq.${id}` },
  ], load, { enabled: approved, delayMs: 800 });

  // can the caller EDIT the occasion itself? (mirror of SQL scope_contains)
  const canEdit = useMemo(() => {
    if (!occ || !profile || !perms.edit) return false;
    if (profile.role === 'owner') return true;
    if (occ.church_id !== profile.church_id) return false;
    if (profile.role === 'church_manager') return true;
    if (profile.service_id && occ.service_id !== profile.service_id) return false;
    if (profile.role === 'service_manager') return true;
    return !profile.class_id || occ.class_id === profile.class_id;
  }, [occ, profile, perms.edit]);
  const canDelete = canEdit && perms.delete;

  const visibleParticipants = useMemo(() => {
    const s = search.trim().toLowerCase();
    return participants.filter((p) =>
      (pFilter === 'all' || (pFilter === 'active' ? p.status !== 'cancelled' : p.status === pFilter)) &&
      (!s || p.person_name.toLowerCase().includes(s) || p.national_id.includes(s) || (p.phone ?? '').includes(s) || p.class_name.toLowerCase().includes(s)));
  }, [participants, pFilter, search]);

  const patchParticipant = (p: Partial<Participant> & { id: string }) =>
    setParticipants((l) => l.map((x) => (x.id === p.id ? { ...x, ...p } : x)));

  const remove = async () => {
    if (!occ) return;
    if (!confirm(`حذف الفعالية «${occ.title}» نهائياً مع كل التسجيلات والتذاكر؟`)) return;
    setBusy(true);
    try { await deleteOccasion(supabase, occ.id); router.replace('/occasions'); }
    catch (e) { flash(occasionErrorMessage(e, 'تعذر الحذف')); setBusy(false); }
  };

  const exportCsv = () => {
    if (!occ) return;
    const head = ['الاسم', 'الفصل', 'الحالة', 'كود التذكرة', 'الهاتف', 'قائمة التحقق', 'ملاحظة'];
    const rows = participants.map((p) => [p.person_name, p.class_name, REG_STATUS_LABELS[p.status], p.ticket_code, p.phone ?? '', `${p.checklist_done}/${items.length}`, p.note ?? '']);
    const csv = '\uFEFF' + [head, ...rows].map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    a.download = `${occ.title}-${fmtDateShort(occ.starts_at)}.csv`;
    a.click();
  };

  const share = async () => {
    if (!occ) return;
    const text = `${occ.title}\n${occ.location ? `📍 ${occ.location}\n` : ''}🗓 ${fmtDateShort(occ.starts_at)}\nسجّل من بوابة المخدوم ← الفعاليات`;
    try {
      if (navigator.share) await navigator.share({ title: occ.title, text });
      else { await navigator.clipboard.writeText(text); flash('تم نسخ التفاصيل'); }
    } catch { /* cancelled */ }
  };

  if (loading) return <AppShell><div className="flex justify-center py-16"><Loader2 className="h-8 w-8 animate-spin text-cyan-500" /></div></AppShell>;
  if (notFound || !occ) {
    return (
      <AppShell>
        <OccasionsHeader back="/occasions" />
        <div className="card py-12 text-center text-slate-400">
          <p className="font-bold">الفعالية غير موجودة أو خارج نطاقك</p>
          <Link href="/occasions" className="btn-primary mt-4 inline-flex !py-2 !px-4 text-sm !from-cyan-600 !to-cyan-500">رجوع إلى اللوحة</Link>
        </div>
      </AppShell>
    );
  }

  const remaining = remainingSeats(occ, counts.active);
  const TABS: { key: Tab; label: string; icon: React.ReactNode; badge?: number }[] = [
    { key: 'participants', label: 'المشاركون', icon: <Users className="h-4 w-4" />, badge: counts.active },
    { key: 'checkin', label: 'الدخول', icon: <ScanLine className="h-4 w-4" />, badge: counts.checked_in },
    { key: 'checklist', label: 'التحقق', icon: <ListChecks className="h-4 w-4" />, badge: items.length },
    { key: 'announcements', label: 'الإعلانات', icon: <Megaphone className="h-4 w-4" />, badge: notifs.filter((n) => !n.registration_id).length },
  ];
  const P_FILTERS: { value: PFilter; label: string }[] = [
    { value: 'active', label: 'النشطون' }, { value: 'pending', label: REG_STATUS_LABELS.pending }, { value: 'confirmed', label: REG_STATUS_LABELS.confirmed },
    { value: 'checked_in', label: REG_STATUS_LABELS.checked_in }, { value: 'cancelled', label: REG_STATUS_LABELS.cancelled }, { value: 'all', label: 'الكل' },
  ];
  const selected = sheet ? participants.find((p) => p.id === sheet) ?? null : null;

  return (
    <AppShell>
      <OccasionsHeader title={occ.title} back="/occasions"
        action={
          <div className="flex gap-1">
            <button type="button" onClick={share} aria-label="مشاركة" className="rounded-full bg-slate-100 p-2 text-slate-600"><Share2 className="h-4 w-4" /></button>
            {canEdit && <button id="occ-edit" type="button" onClick={() => setEdit(true)} aria-label="تعديل" className="rounded-full bg-primary-50 p-2 text-primary-600"><Pencil className="h-4 w-4" /></button>}
            {canDelete && <button id="occ-delete" type="button" disabled={busy} onClick={remove} aria-label="حذف" className="rounded-full bg-red-50 p-2 text-red-500"><Trash2 className="h-4 w-4" /></button>}
          </div>
        } />

      <OccasionCover url={occ.image_url} title={occ.title} kind={occ.kind} className="mb-3 h-44 w-full rounded-3xl shadow-card">
        <div className="absolute inset-x-0 top-0 flex items-start justify-between p-3">
          <KindBadge kind={occ.kind} />
          <OccasionStatusBadge status={occ.status} o={occ} />
        </div>
        <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/75 to-transparent px-4 pb-3 pt-10 text-white">
          <p className="text-xl font-extrabold drop-shadow">{occ.title}</p>
          <p className="truncate text-xs text-white/80">{scopeLabel(occ, churches, services, classes)}</p>
        </div>
      </OccasionCover>

      <StatsRow id="occ-stats" counts={counts} capacity={occ.capacity} />

      <div className="mb-3">
        <OccasionInfoList o={occ} remaining={remaining} active={counts.active} />
        {occ.description && <p className="card mt-2 whitespace-pre-wrap text-sm font-bold text-slate-600">{occ.description}</p>}
      </div>

      <nav id="occ-tabs" className="mb-3 grid grid-cols-4 gap-1.5">
        {TABS.map((t) => (
          <button key={t.key} type="button" onClick={() => setTab(t.key)} aria-pressed={tab === t.key}
            className={`relative flex h-12 flex-col items-center justify-center gap-0.5 rounded-xl text-[11px] font-extrabold transition active:scale-95 ${tab === t.key ? 'bg-cyan-600 text-white shadow ring-2 ring-cyan-300' : 'bg-white text-slate-600 border border-slate-200'}`}>
            {t.icon}{t.label}
            {!!t.badge && <span className={`absolute -top-1.5 -left-1 rounded-full px-1.5 text-[10px] tabular-nums ${tab === t.key ? 'bg-white text-cyan-700' : 'bg-cyan-600 text-white'}`}>{t.badge}</span>}
          </button>
        ))}
      </nav>

      {tab === 'participants' && (
        <div className="space-y-2">
          <div className="flex gap-2">
            <div className="relative flex-1">
              <Search className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
              <input id="occ-p-search" className="input-field pr-9 text-sm" placeholder="ابحث في المشاركين…" value={search} onChange={(e) => setSearch(e.target.value)} />
            </div>
            {perms.manage && (
              <button id="occ-p-add" type="button" onClick={() => setAdding(true)} className="btn-primary flex items-center gap-1.5 !from-cyan-600 !to-cyan-500 !px-3 !py-2 text-sm"><UserPlus className="h-4 w-4" /> إضافة</button>
            )}
            <button type="button" onClick={exportCsv} aria-label="تصدير CSV" className="btn-secondary !px-3 !py-2"><Download className="h-4 w-4" /></button>
          </div>
          <div id="occ-p-filters" className="flex flex-wrap gap-1">
            {P_FILTERS.map((f) => (
              <button key={f.value} type="button" onClick={() => setPFilter(f.value)} aria-pressed={pFilter === f.value}
                className={`rounded-full px-3 py-1 text-xs font-extrabold ${pFilter === f.value ? 'bg-cyan-600 text-white' : 'bg-white text-slate-500 border border-slate-200'}`}>{f.label}</button>
            ))}
          </div>
          {visibleParticipants.length === 0 ? (
            <div className="card py-10 text-center text-slate-400"><Users className="mx-auto mb-2 h-8 w-8 text-cyan-200" /><p className="text-sm font-bold">{participants.length === 0 ? 'لا مشاركين بعد — أضف أو انتظر تسجيل المخدومين' : 'لا نتائج'}</p></div>
          ) : (
            <div id="occ-p-list" className="card !p-0 divide-y divide-indigo-50 overflow-hidden">
              {visibleParticipants.map((p, i) => (
                <button key={p.id} id={`occ-p-${p.id}`} type="button" onClick={() => setSheet(p.id)}
                  className={`flex w-full items-center gap-2.5 px-3 py-2.5 text-right hover:bg-cyan-50/40 ${p.status === 'cancelled' ? 'opacity-60' : ''}`}>
                  <span className="w-5 shrink-0 text-center text-[11px] font-extrabold text-slate-300 tabular-nums">{i + 1}</span>
                  <PersonAvatar url={p.person_image} name={p.person_name} size={40} />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-extrabold">{p.person_name}</p>
                    <p className="truncate text-[11px] font-bold text-slate-400">
                      {p.class_name}
                      {items.length > 0 && <> · <Check className="inline h-3 w-3" /> {p.checklist_done}/{items.length}</>}
                      {p.note ? ` · ${p.note}` : ''}
                    </p>
                  </div>
                  <RegStatusBadge status={p.status} />
                  <ChevronLeft className="h-4 w-4 shrink-0 text-slate-300" />
                </button>
              ))}
            </div>
          )}
        </div>
      )}

      {tab === 'checkin' && (
        <CheckinTab occasion={occ} participants={participants} canManage={perms.manage}
          onCheckedIn={(r) => {
            patchParticipant({ id: r.registration_id, status: 'checked_in', checked_in_at: r.checked_in_at });
            setCounts((c) => ({
              ...c, checked_in: c.checked_in + 1,
              confirmed: Math.max(0, c.confirmed - (r.previous_status === 'confirmed' ? 1 : 0)),
              pending: Math.max(0, c.pending - (r.previous_status === 'pending' ? 1 : 0)),
            }));
          }} />
      )}
      {tab === 'checklist' && <ChecklistTab occasion={occ} items={items} participants={participants} canEdit={canEdit} onChanged={setItems} flash={flash} />}
      {tab === 'announcements' && <AnnouncementsTab occasion={occ} notifications={notifs} participants={participants} canEdit={canEdit} onChanged={setNotifs} flash={flash} />}

      {edit && (
        <OccasionFormModal item={occ} churches={churches} services={services} classes={classes}
          onClose={() => setEdit(false)} onSaved={(saved) => { setOcc(saved); setEdit(false); flash('تم حفظ التعديلات'); }} />
      )}
      {adding && (
        <AddParticipantModal occasion={occ} participants={participants} classes={classes} onClose={() => setAdding(false)}
          onAdded={() => { flash('تمت إضافة المشارك'); load(); }} />
      )}
      {selected && (
        <ParticipantSheet occasion={occ} participant={selected} items={items} canManage={perms.manage}
          onClose={() => setSheet(null)} onChanged={(p) => { patchParticipant(p); if (p.status) load(); }}
          onRemoved={(rid) => { setParticipants((l) => l.filter((x) => x.id !== rid)); load(); }} flash={flash} />
      )}
      <Toast msg={toast} />
    </AppShell>
  );
}
