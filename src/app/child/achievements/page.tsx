'use client';

// ---------- Child portal — الإنجازات ----------
// Earned achievements as cards (🏆 picture · name · +N points · date) and
// simple progress bars for the attendance achievements still in reach
// («Faithful Attender — 3 / 5»). Data comes from the shared ChildProvider
// (child_portal_achievements RPC, realtime on user_achievements).

import { Trophy, Star, Loader2, Flag, Zap, Hand } from 'lucide-react';
import ChildShell, { useChildAchievements } from '@/components/child/ChildShell';
import { EarnedCard, ProgressBar, AchievementThumb } from '@/components/achievements/AchievementBits';
import { useChild } from '@/lib/child-context';
import { ruleLabel } from '@/lib/achievements';

export default function ChildAchievementsPage() {
  return (
    <ChildShell>
      <Content />
    </ChildShell>
  );
}

function Content() {
  const { profile } = useChild();
  const { data, earnedCount } = useChildAchievements();
  const multi = (profile?.enrollments.length ?? 0) > 1;
  const totalPoints = (data?.earned ?? []).reduce((s, e) => s + e.points, 0);

  return (
    <>
      <section className="mb-4 flex items-center gap-2">
        <h2 className="flex items-center gap-2 text-lg font-extrabold">
          <Trophy className="h-5 w-5 text-amber-600" /> إنجازاتي
        </h2>
        {data && <span className="badge bg-amber-100 text-amber-700 tabular-nums">{earnedCount}</span>}
      </section>

      {!data ? (
        <div className="flex justify-center py-16"><Loader2 className="h-8 w-8 animate-spin text-amber-500" /></div>
      ) : (
        <>
          {/* KPIs */}
          <section className="mb-4 grid grid-cols-2 gap-3">
            <div className="card border border-amber-100 bg-amber-50 !p-3">
              <p className="text-2xl font-extrabold tabular-nums text-amber-700">{earnedCount}</p>
              <p className="text-xs font-bold text-slate-500">إنجاز حصلت عليه</p>
            </div>
            <div className="card border border-gold-100 bg-gold-50 !p-3">
              <p className="text-2xl font-extrabold tabular-nums text-gold-700">+{totalPoints}</p>
              <p className="text-xs font-bold text-slate-500">نقطة من الإنجازات</p>
            </div>
          </section>

          {/* progress */}
          {data.progress.length > 0 && (
            <section className="mb-4">
              <h3 className="mb-2 flex items-center gap-1.5 text-sm font-extrabold text-slate-500"><Flag className="h-4 w-4" /> في الطريق</h3>
              <div id="child-ach-progress" className="space-y-2">
                {data.progress.map((p) => {
                  const done = p.current >= p.target;
                  return (
                    <div key={`${p.achievement_id}-${p.enrollment_id}`} id={`child-ach-progress-${p.achievement_id}`} className="card !p-3">
                      <div className="flex items-center gap-3">
                        <AchievementThumb url={p.image_url} name={p.name} size={48} />
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-extrabold">{p.name}</p>
                          <p className="truncate text-[11px] font-bold text-slate-400">
                            {ruleLabel({ attendance_rule: p.rule, attendance_target: p.target })}
                            {p.event_name ? ` · ${p.event_name}` : ''}
                            {multi ? ` · ${p.class_name}` : ''}
                            {p.awards_count > 0 ? ` · حصلت عليه ${p.awards_count}× قبل ذلك` : ''}
                          </p>
                        </div>
                        <span className="badge shrink-0 bg-gold-100 text-gold-700"><Star className="h-3 w-3" /> +{p.points}</span>
                      </div>
                      <ProgressBar current={p.current} target={p.target}
                        label={done ? 'اكتمل الشرط 🎉' : p.rule === 'streak' ? 'حضور متتالٍ' : 'الحضور'} />
                    </div>
                  );
                })}
              </div>
            </section>
          )}

          {/* earned */}
          <section className="mb-4">
            <h3 className="mb-2 flex items-center gap-1.5 text-sm font-extrabold text-slate-500"><Trophy className="h-4 w-4" /> حصلت عليها</h3>
            {data.earned.length === 0 ? (
              <div className="card py-10 text-center text-slate-400">
                <Trophy className="mx-auto mb-3 h-10 w-10 text-amber-200" />
                <p className="font-bold">لم تحصل على إنجازات بعد</p>
                <p className="mt-1 text-xs font-bold">واظب على الحضور وشارك في المناسبات!</p>
              </div>
            ) : (
              <div id="child-ach-earned" className="space-y-2">
                {data.earned.map((e) => (
                  <EarnedCard key={e.id} id={`child-ach-earned-${e.id}`} name={e.name} image_url={e.image_url} points={e.points} awarded_at={e.awarded_at}
                    sub={[
                      e.source === 'attendance' ? 'بالحضور' : 'من خادمك',
                      e.event_name,
                      multi ? e.class_name : null,
                    ].filter(Boolean).join(' · ')}
                    action={e.source === 'attendance'
                      ? <Zap className="h-4 w-4 shrink-0 text-emerald-500" aria-label="تلقائي" />
                      : <Hand className="h-4 w-4 shrink-0 text-primary-500" aria-label="يدوي" />}
                  />
                ))}
              </div>
            )}
          </section>
        </>
      )}
    </>
  );
}
