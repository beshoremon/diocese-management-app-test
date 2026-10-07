'use client';

// ---------- Settings tab (control room) ----------
// Read-only summary of the class settings + bindings, «تعديل» opens the
// form modal, and the danger zone (cancel / reschedule / delete).

import Link from 'next/link';
import { Pencil, GraduationCap, CalendarCheck, Ban, RotateCcw, Trash2, Loader2 } from 'lucide-react';
import { fmtDateTime, fmtTime } from '@/components/online/OnlineBits';
import { PLATFORM_LABELS, type OnlineClass } from '@/lib/online-classes';

export default function SettingsTab({
  cls, canWrite, busy, onEdit, onCancel, onUncancel, onDelete,
}: {
  cls: OnlineClass; canWrite: boolean; busy: string | null;
  onEdit: () => void; onCancel: () => void; onUncancel: () => void; onDelete: () => void;
}) {
  return (
    <div className="space-y-3">
      <div className="card">
        <div className="mb-2 flex items-center justify-between">
          <p className="text-sm font-extrabold">إعدادات الفصل</p>
          {canWrite && <button type="button" id="oc-edit" onClick={onEdit} className="flex items-center gap-1 text-xs font-extrabold text-red-600"><Pencil className="h-3.5 w-3.5" /> تعديل</button>}
        </div>
        <dl className="grid grid-cols-2 gap-2 text-xs">
          <Row label="الموعد" value={`${fmtDateTime(cls.starts_at)} – ${fmtTime(cls.ends_at)}`} />
          <Row label="المنصة" value={PLATFORM_LABELS[cls.platform]} />
          <Row label="الرابط" value={cls.stream_url ?? '—'} ltr />
          <Row label="الدردشة" value={cls.chat_enabled ? 'مفعّلة' : 'مغلقة'} />
          <Row label="الحد الأدنى للوقت" value={`${cls.min_time_percent}٪`} />
          <Row label="فحوص الانتباه" value={`${cls.checks_min_success} ناجح من ${cls.checks_required} · مهلة ${cls.check_seconds} ث`} />
          <Row label="الحد الأدنى للإجابات" value={String(cls.min_answers)} />
          <Row label="نقاط الحضور" value={String(cls.attendance_points)} />
        </dl>
        {cls.description && <p className="mt-2 rounded-xl bg-slate-50 px-3 py-2 text-xs text-slate-600">{cls.description}</p>}
      </div>

      <div className="card">
        <p className="mb-2 text-sm font-extrabold">الربط</p>
        <div className="space-y-2">
          <div className="flex items-center gap-2 rounded-xl bg-violet-50 px-3 py-2 text-xs">
            <GraduationCap className="h-4 w-4 shrink-0 text-violet-600" />
            <span className="min-w-0 flex-1 font-bold text-violet-900">{cls.exam_id ? 'امتحان مرتبط — يظهر للمخدوم داخل الفصل' : 'لا امتحان مرتبط'}</span>
            {cls.exam_id ? <Link href={`/exams/${cls.exam_id}`} className="shrink-0 text-[11px] font-extrabold text-violet-700">افتح الامتحان</Link>
              : canWrite && <Link href="/exams" className="shrink-0 text-[11px] font-extrabold text-violet-700">أنشئ امتحاناً</Link>}
          </div>
          <div className="flex items-center gap-2 rounded-xl bg-emerald-50 px-3 py-2 text-xs">
            <CalendarCheck className="h-4 w-4 shrink-0 text-emerald-600" />
            <span className="min-w-0 flex-1 font-bold text-emerald-900">{cls.event_id ? 'الحضور يُسجَّل للمناسبة المرتبطة' : 'الحضور يُسجَّل بدون مناسبة (يظهر باسم الفصل)'}</span>
          </div>
        </div>
        {canWrite && <button type="button" onClick={onEdit} className="mt-2 text-xs font-extrabold text-red-600">تغيير الامتحان / المناسبة</button>}
      </div>

      {canWrite && (
        <div className="card border-red-100">
          <p className="mb-2 text-sm font-extrabold text-red-700">منطقة الخطر</p>
          <div className="flex flex-wrap gap-2">
            {cls.status === 'scheduled' && <button type="button" onClick={onCancel} className="btn-secondary flex items-center gap-1 !py-2 !px-3 text-xs"><Ban className="h-4 w-4" /> إلغاء الفصل</button>}
            {cls.status === 'cancelled' && <button type="button" onClick={onUncancel} className="btn-secondary flex items-center gap-1 !py-2 !px-3 text-xs"><RotateCcw className="h-4 w-4" /> إعادة الجدولة</button>}
            <button type="button" id="oc-delete" disabled={busy === 'delete'} onClick={onDelete} className="flex items-center gap-1 rounded-xl bg-red-600 px-3 py-2 text-xs font-extrabold text-white">
              {busy === 'delete' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />} حذف الفصل
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function Row({ label, value, ltr }: { label: string; value: string; ltr?: boolean }) {
  return (
    <div className="rounded-xl bg-slate-50 px-3 py-2">
      <dt className="text-[10px] font-bold text-slate-400">{label}</dt>
      <dd className={`truncate font-extrabold text-slate-700 ${ltr ? 'text-left' : ''}`} dir={ltr ? 'ltr' : undefined}>{value}</dd>
    </div>
  );
}
