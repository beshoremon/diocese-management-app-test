'use client';

// ---------- Award an achievement to ONE child (servant side) ----------
// Lists every achievement that applies to the child's enrollment with its
// progress / block reason (achievement_enrollment_progress RPC) and his
// earned ones. «منح» calls achievement_award (the DB re-checks every rule).
// Attendance achievements are shown with their progress bar and are
// awarded automatically — the manual button stays available for managers'
// convenience (same rules apply).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { X, Loader2, Trophy, Star, Award, Zap, Undo2, Lock } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useAuth } from '@/lib/auth-context';
import { useModuleVisible } from '@/lib/modules-context';
import {
  fetchAchievements, fetchEnrollmentProgress, fetchEnrollmentAwards, awardAchievement, revokeAchievement,
  achievementErrorMessage, isMigrationMissing, MIGRATION_HINT, achievementAppliesTo, ruleLabel, awardModeLabel,
  BLOCK_LABELS, KIND_LABELS,
  type Achievement, type EnrollmentProgress, type UserAchievement,
} from '@/lib/achievements';
import { AchievementThumb, ProgressBar, EarnedCard } from '@/components/achievements/AchievementBits';
import type { EnrollmentWithPerson } from '@/lib/types';

export default function AwardModal({ enrollment, onClose, onAwarded }: {
  enrollment: EnrollmentWithPerson;
  onClose: () => void;
  /** called after every award / revoke with the new balance */
  onAwarded?: (balanceAfter: number) => void;
}) {
  const { profile } = useAuth();
  const [supabase] = useState(() => createClient());
  const visible = useModuleVisible('achievements');
  const [items, setItems] = useState<Achievement[] | null>(null);
  const [progress, setProgress] = useState<Map<string, EnrollmentProgress>>(new Map());
  const [awards, setAwards] = useState<UserAchievement[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [hint, setHint] = useState('');

  const load = useCallback(async () => {
    try {
      const [all, pr, aw] = await Promise.all([
        fetchAchievements(supabase, { church: enrollment.church_id }),
        fetchEnrollmentProgress(supabase, enrollment.id),
        fetchEnrollmentAwards(supabase, enrollment.id),
      ]);
      setItems(all.filter((a) => achievementAppliesTo(a, enrollment)));
      setProgress(new Map(pr.map((p) => [p.achievement_id, p])));
      setAwards(aw);
    } catch (e) {
      setItems([]);
      setHint(isMigrationMissing(e) ? MIGRATION_HINT : achievementErrorMessage(e));
    }
  }, [supabase, enrollment]);
  useEffect(() => { if (visible) load(); }, [visible, load]);

  const byId = useMemo(() => new Map((items ?? []).map((a) => [a.id, a])), [items]);
  const isManager = !!profile && ['owner', 'church_manager', 'service_manager'].includes(profile.role);

  const award = async (a: Achievement) => {
    setBusy(a.id); setError('');
    try {
      const r = await awardAchievement(supabase, a.id, enrollment.id);
      onAwarded?.(r.balance_after);
      await load();
    } catch (e) { setError(achievementErrorMessage(e, 'تعذر المنح')); }
    finally { setBusy(null); }
  };

  const revoke = async (ua: UserAchievement) => {
    const a = byId.get(ua.achievement_id);
    if (!confirm(`إلغاء إنجاز «${a?.name ?? ''}»؟ سيُخصم ${ua.points_awarded} نقطة.`)) return;
    setBusy(ua.id); setError('');
    try {
      const r = await revokeAchievement(supabase, ua.id);
      onAwarded?.(r.balance_after);
      await load();
    } catch (e) { setError(achievementErrorMessage(e, 'تعذر الإلغاء')); }
    finally { setBusy(null); }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-6" onClick={onClose}>
      <div id="award-modal" className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-white p-5 sm:rounded-3xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h3 className="flex items-center gap-2 text-lg font-extrabold"><Trophy className="h-5 w-5 text-amber-600" /> إنجازات {enrollment.person.name}</h3>
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        {visible === false && <p className="rounded-xl bg-amber-50 px-3 py-2 text-xs font-bold text-amber-700">وحدة الإنجازات غير مفعّلة لنطاقك</p>}
        {hint && <p className="mb-2 rounded-xl bg-amber-50 px-3 py-2 text-xs font-bold text-amber-700">⚠️ {hint}</p>}
        {error && <p className="mb-2 rounded-xl bg-red-50 px-3 py-2 text-xs font-bold text-red-600">{error}</p>}

        {items === null ? (
          <div className="flex justify-center py-10"><Loader2 className="h-7 w-7 animate-spin text-amber-500" /></div>
        ) : (
          <>
            {/* earned */}
            <p className="mb-1.5 text-xs font-extrabold text-slate-500">الإنجازات المكتسبة ({awards.length})</p>
            {awards.length === 0 ? (
              <p className="mb-3 rounded-2xl bg-slate-50 px-3 py-3 text-center text-xs font-bold text-slate-400">لم يحصل على إنجازات بعد</p>
            ) : (
              <div className="mb-3 space-y-2">
                {awards.map((ua) => {
                  const a = byId.get(ua.achievement_id);
                  const canRevoke = isManager || ua.awarded_by === profile?.id;
                  return (
                    <EarnedCard key={ua.id} id={`award-earned-${ua.id}`} name={a?.name ?? 'إنجاز محذوف'} image_url={a?.image_url ?? null}
                      points={ua.points_awarded} awarded_at={ua.awarded_at}
                      sub={ua.source === 'attendance' ? 'مُنح تلقائياً بالحضور' : 'مُنح يدوياً'}
                      action={canRevoke ? (
                        <button type="button" aria-label="إلغاء" title="إلغاء الإنجاز" disabled={busy === ua.id} onClick={() => revoke(ua)}
                          className="rounded-full bg-red-50 p-2 text-red-500 hover:bg-red-100 disabled:opacity-40">
                          {busy === ua.id ? <Loader2 className="h-4 w-4 animate-spin" /> : <Undo2 className="h-4 w-4" />}
                        </button>
                      ) : undefined}
                    />
                  );
                })}
              </div>
            )}

            {/* available */}
            <p className="mb-1.5 text-xs font-extrabold text-slate-500">الإنجازات المتاحة</p>
            {items.length === 0 ? (
              <p className="rounded-2xl bg-slate-50 px-3 py-3 text-center text-xs font-bold text-slate-400">لا توجد إنجازات تنطبق على فصل هذا المخدوم</p>
            ) : (
              <ul id="award-list" className="space-y-2">
                {items.map((a) => {
                  const pr = progress.get(a.id);
                  const blocked = !a.is_active ? 'inactive' : pr?.block ?? null;
                  const canAward = !blocked;
                  return (
                    <li key={a.id} id={`award-item-${a.id}`} className={`card !p-3 ${blocked ? 'opacity-70' : ''}`}>
                      <div className="flex items-center gap-3">
                        <AchievementThumb url={a.image_url} name={a.name} size={48} muted={!!blocked} />
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-extrabold text-sm">{a.name}</p>
                          <p className="flex flex-wrap items-center gap-x-1.5 text-[11px] font-bold text-slate-400">
                            <span className="badge bg-gold-100 text-gold-700 !py-0"><Star className="h-3 w-3" /> {a.points}</span>
                            <span>{KIND_LABELS[a.kind]}{a.kind === 'attendance' ? ` · ${ruleLabel(a)}` : ''}</span>
                            <span>· {awardModeLabel(a)}</span>
                            {pr && pr.awards_count > 0 && <span>· حصل عليه {pr.awards_count}×</span>}
                          </p>
                          {a.kind === 'attendance' && pr && !blocked && (
                            <ProgressBar current={pr.current_value} target={pr.target_value} label={pr.eligible ? 'الشرط مكتمل' : 'التقدم'} />
                          )}
                          {blocked && <p className="mt-1 flex items-center gap-1 text-[11px] font-bold text-slate-400"><Lock className="h-3 w-3" /> {BLOCK_LABELS[blocked]}</p>}
                        </div>
                        <button type="button" id={`award-btn-${a.id}`} disabled={!canAward || busy === a.id} onClick={() => award(a)}
                          className="btn-primary flex shrink-0 items-center gap-1 !py-2 !px-3 text-xs !from-amber-600 !to-amber-500 disabled:opacity-40">
                          {busy === a.id ? <Loader2 className="h-4 w-4 animate-spin" /> : a.kind === 'attendance' ? <Zap className="h-4 w-4" /> : <Award className="h-4 w-4" />}
                          منح
                        </button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </>
        )}
      </div>
    </div>
  );
}
