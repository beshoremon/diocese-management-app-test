'use client';

// ---------- Chart primitives for the الإحصائيات tab ----------
// Pure SVG + Tailwind, RTL-aware, no chart library. Every component is
// presentational: it receives already-aggregated numbers.
//
//   KpiTile          — headline number with icon, caption and optional delta
//   StackedBarChart  — multi-series timeline (stacked or grouped), legend,
//                      tap a bucket to inspect the exact per-series values
//   RankedBars       — horizontal bars sorted by value (by event / by cause)
//   DonutRing        — single ratio (e.g. attendees / enrolled)
//   SectionCard      — consistent card header used by every stats section

import { useMemo, useState, type ReactNode } from 'react';
import type { LucideIcon } from 'lucide-react';
import { seriesColor, type Series } from '@/lib/stats';

// ---------- Number formatting (Arabic-Egypt digits handled by the UA) ----------
export const fmtNum = (n: number) => new Intl.NumberFormat('ar-EG', { maximumFractionDigits: 0 }).format(n);
export const fmtSigned = (n: number) => (n > 0 ? `+${fmtNum(n)}` : n < 0 ? `−${fmtNum(-n)}` : fmtNum(0));

// =====================================================================
// SectionCard
// =====================================================================
export function SectionCard({
  id, icon: Icon, title, subtitle, actions, children, tone = 'primary',
}: {
  id?: string;
  icon: LucideIcon;
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
  tone?: 'primary' | 'emerald' | 'gold' | 'sky' | 'violet' | 'rose';
}) {
  const tones = {
    primary: 'bg-primary-100 text-primary-700',
    emerald: 'bg-emerald-100 text-emerald-700',
    gold: 'bg-gold-100 text-gold-700',
    sky: 'bg-sky-100 text-sky-700',
    violet: 'bg-violet-100 text-violet-700',
    rose: 'bg-rose-100 text-rose-700',
  } as const;
  return (
    <section id={id} className="card !p-0 overflow-hidden">
      <header className="flex items-center gap-3 border-b border-slate-100 px-4 py-3">
        <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${tones[tone]}`}>
          <Icon className="h-5 w-5" />
        </span>
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-sm font-extrabold text-slate-800">{title}</h3>
          {subtitle && <p className="truncate text-[11px] font-bold text-slate-400">{subtitle}</p>}
        </div>
        {actions && <div className="flex shrink-0 items-center gap-1.5">{actions}</div>}
      </header>
      <div className="p-4">{children}</div>
    </section>
  );
}

// =====================================================================
// KpiTile
// =====================================================================
export function KpiTile({
  id, icon: Icon, value, label, hint, tone = 'primary', compact = false,
}: {
  id?: string;
  icon: LucideIcon;
  value: string | number;
  label: string;
  hint?: string;
  tone?: 'primary' | 'emerald' | 'gold' | 'sky' | 'violet' | 'rose' | 'slate';
  compact?: boolean;
}) {
  const tones = {
    primary: 'from-primary-600 to-primary-500 text-white',
    emerald: 'from-emerald-600 to-emerald-500 text-white',
    gold: 'from-gold-500 to-gold-400 text-primary-900',
    sky: 'from-sky-600 to-sky-500 text-white',
    violet: 'from-violet-600 to-violet-500 text-white',
    rose: 'from-rose-600 to-rose-500 text-white',
    slate: 'from-slate-700 to-slate-600 text-white',
  } as const;
  return (
    <div
      id={id}
      className={`relative overflow-hidden rounded-2xl bg-gradient-to-br shadow-card ${tones[tone]} ${compact ? 'p-3' : 'p-4'}`}
    >
      <Icon className={`absolute -left-2 -bottom-2 opacity-15 ${compact ? 'h-14 w-14' : 'h-20 w-20'}`} />
      <div className="relative">
        <p className={`tabular-nums font-extrabold leading-none ${compact ? 'text-xl' : 'text-3xl'}`}>
          {typeof value === 'number' ? fmtNum(value) : value}
        </p>
        <p className={`mt-1.5 font-bold opacity-90 ${compact ? 'text-[11px]' : 'text-xs'}`}>{label}</p>
        {hint && <p className="mt-0.5 text-[10px] font-bold opacity-75">{hint}</p>}
      </div>
    </div>
  );
}

// =====================================================================
// Legend
// =====================================================================
export function Legend({
  series, hidden, onToggle,
}: {
  series: Series[];
  hidden: Set<string>;
  onToggle: (key: string) => void;
}) {
  if (series.length === 0) return null;
  return (
    <ul className="mt-3 flex flex-wrap gap-1.5">
      {series.map((s, i) => {
        const off = hidden.has(s.key);
        return (
          <li key={s.key}>
            <button
              type="button"
              onClick={() => onToggle(s.key)}
              aria-pressed={!off}
              className={`flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-extrabold transition active:scale-95 ${
                off ? 'border-slate-200 bg-white text-slate-400 line-through' : 'border-transparent bg-slate-100 text-slate-700'
              }`}
            >
              <span className="h-2.5 w-2.5 rounded-full" style={{ background: off ? '#cbd5e1' : seriesColor(i) }} />
              <span className="max-w-[9rem] truncate">{s.label}</span>
              <span className="tabular-nums text-slate-400">{fmtNum(s.total)}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

// =====================================================================
// StackedBarChart — multi-series timeline
// =====================================================================
export function StackedBarChart({
  id, series, labels, longLabels, mode = 'stacked', height = 190, emptyText = 'لا توجد بيانات في هذه الفترة',
}: {
  id?: string;
  series: Series[];
  labels: string[]; // short x labels aligned with series[].values
  longLabels?: string[]; // detail label per bucket
  mode?: 'stacked' | 'grouped';
  height?: number;
  emptyText?: string;
}) {
  const [hidden, setHidden] = useState<Set<string>>(new Set());
  const [active, setActive] = useState<number | null>(null);

  const visible = useMemo(() => series.filter((s) => !hidden.has(s.key)), [series, hidden]);
  const colorOf = useMemo(() => {
    const m = new Map<string, string>();
    series.forEach((s, i) => m.set(s.key, seriesColor(i)));
    return m;
  }, [series]);

  const n = labels.length;
  const totals = useMemo(
    () => labels.map((_, i) => visible.reduce((acc, s) => acc + (s.values[i] ?? 0), 0)),
    [labels, visible]
  );
  const maxStack = Math.max(1, ...totals);
  const maxSingle = Math.max(1, ...visible.flatMap((s) => s.values));
  const max = mode === 'stacked' ? maxStack : maxSingle;

  // "nice" y-axis ticks: 4 gridlines
  const ticks = useMemo(() => {
    const step = niceStep(max / 4);
    const top = Math.ceil(max / step) * step;
    const out: number[] = [];
    for (let v = 0; v <= top; v += step) out.push(v);
    return { values: out, top: Math.max(top, step) };
  }, [max]);

  const W = 100; // viewBox width in % units
  const H = height;
  const padL = 0;
  const padB = 22;
  const plotH = H - padB - 6;
  const slot = W / Math.max(1, n);
  const gap = Math.min(slot * 0.25, 2.2);
  const barW = slot - gap;

  const toggle = (key: string) =>
    setHidden((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const isEmpty = series.length === 0 || totals.every((t) => t === 0);
  const showEvery = n > 14 ? Math.ceil(n / 7) : 1;

  return (
    <div id={id}>
      {isEmpty ? (
        <div className="flex h-40 items-center justify-center rounded-xl bg-slate-50 text-sm font-bold text-slate-400">
          {emptyText}
        </div>
      ) : (
        <div className="relative select-none" dir="ltr">
          {/* y-axis labels (absolute, right side for RTL reading) */}
          <div className="pointer-events-none absolute inset-y-0 right-0 z-10 flex flex-col justify-between pb-[22px] pt-[6px] text-[9px] font-bold tabular-nums text-slate-400">
            {[...ticks.values].reverse().map((v) => (
              <span key={v} className="bg-white/80 px-0.5 leading-none">{fmtNum(v)}</span>
            ))}
          </div>
          <svg
            viewBox={`0 0 ${W} ${H}`}
            preserveAspectRatio="none"
            className="h-[var(--h)] w-full"
            style={{ ['--h' as string]: `${H}px` }}
            onMouseLeave={() => setActive(null)}
          >
            {/* gridlines */}
            {ticks.values.map((v) => {
              const y = 6 + plotH - (v / ticks.top) * plotH;
              return (
                <line key={v} x1={padL} x2={W} y1={y} y2={y} stroke="#e2e8f0" strokeWidth={0.4} vectorEffect="non-scaling-stroke" />
              );
            })}
            {/* bars */}
            {labels.map((_, i) => {
              const x0 = padL + i * slot + gap / 2;
              let cursor = 0;
              const isActive = active === i;
              return (
                <g
                  key={i}
                  onMouseEnter={() => setActive(i)}
                  onClick={() => setActive(active === i ? null : i)}
                  style={{ cursor: 'pointer' }}
                >
                  {/* hit area */}
                  <rect x={padL + i * slot} y={0} width={slot} height={H - padB} fill={isActive ? '#f1f5f9' : 'transparent'} />
                  {mode === 'stacked'
                    ? visible.map((s) => {
                        const v = s.values[i] ?? 0;
                        const h = (v / ticks.top) * plotH;
                        const y = 6 + plotH - cursor - h;
                        cursor += h;
                        return v > 0 ? (
                          <rect
                            key={s.key}
                            x={x0}
                            y={y}
                            width={barW}
                            height={h}
                            fill={colorOf.get(s.key)}
                            opacity={active === null || isActive ? 1 : 0.45}
                            rx={0.4}
                          />
                        ) : null;
                      })
                    : visible.map((s, si) => {
                        const v = s.values[i] ?? 0;
                        const h = (v / ticks.top) * plotH;
                        const gw = barW / Math.max(1, visible.length);
                        return v > 0 ? (
                          <rect
                            key={s.key}
                            x={x0 + si * gw}
                            y={6 + plotH - h}
                            width={Math.max(0.3, gw - 0.2)}
                            height={h}
                            fill={colorOf.get(s.key)}
                            opacity={active === null || isActive ? 1 : 0.45}
                            rx={0.3}
                          />
                        ) : null;
                      })}
                  {/* total label above the bar */}
                  {totals[i] > 0 && (isActive || n <= 12) && (
                    <text
                      x={x0 + barW / 2}
                      y={Math.max(5, 6 + plotH - (totals[i] / ticks.top) * plotH - 2)}
                      textAnchor="middle"
                      fontSize={n > 20 ? 2.6 : 3.2}
                      fontWeight={800}
                      fill="#334155"
                      style={{ fontFamily: 'inherit' }}
                    >
                      {fmtNum(mode === 'stacked' ? totals[i] : Math.max(...visible.map((s) => s.values[i] ?? 0)))}
                    </text>
                  )}
                </g>
              );
            })}
            {/* x labels */}
            {labels.map((l, i) =>
              i % showEvery === 0 || i === n - 1 ? (
                <text
                  key={i}
                  x={padL + i * slot + slot / 2}
                  y={H - 6}
                  textAnchor="middle"
                  fontSize={n > 20 ? 2.5 : 3}
                  fontWeight={700}
                  fill={active === i ? '#4f46e5' : '#94a3b8'}
                  style={{ fontFamily: 'inherit' }}
                >
                  {l}
                </text>
              ) : null
            )}
          </svg>

          {/* Inspector for the tapped bucket */}
          {active !== null && (
            <div dir="rtl" className="mt-2 rounded-xl border border-primary-100 bg-primary-50/60 px-3 py-2 text-xs">
              <p className="mb-1 flex items-center justify-between font-extrabold text-primary-800">
                <span>{longLabels?.[active] ?? labels[active]}</span>
                <span className="tabular-nums">الإجمالي {fmtNum(totals[active])}</span>
              </p>
              <ul className="grid grid-cols-1 gap-0.5 xs:grid-cols-2">
                {visible
                  .map((s) => ({ s, v: s.values[active] ?? 0 }))
                  .filter(({ v }) => v > 0)
                  .sort((a, b) => b.v - a.v)
                  .map(({ s, v }) => (
                    <li key={s.key} className="flex items-center gap-1.5 font-bold text-slate-600">
                      <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: colorOf.get(s.key) }} />
                      <span className="min-w-0 flex-1 truncate">{s.label}</span>
                      <span className="tabular-nums">{fmtNum(v)}</span>
                    </li>
                  ))}
                {visible.every((s) => (s.values[active] ?? 0) === 0) && (
                  <li className="text-slate-400">لا يوجد حضور</li>
                )}
              </ul>
            </div>
          )}
        </div>
      )}
      <Legend series={series} hidden={hidden} onToggle={toggle} />
    </div>
  );
}

function niceStep(raw: number): number {
  if (raw <= 0) return 1;
  const pow = Math.pow(10, Math.floor(Math.log10(raw)));
  const f = raw / pow;
  const nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
  return Math.max(1, nice * pow);
}

// =====================================================================
// RankedBars — horizontal bars sorted by value
// =====================================================================
export interface RankedItem {
  key: string;
  label: string;
  sublabel?: string;
  value: number;
  secondary?: string; // e.g. "12 من 20 · 60%"
  color?: string;
  badge?: ReactNode;
}

export function RankedBars({
  id, items, emptyText = 'لا توجد بيانات', valueLabel,
}: {
  id?: string;
  items: RankedItem[];
  emptyText?: string;
  valueLabel?: (v: number) => string;
}) {
  const max = Math.max(1, ...items.map((i) => Math.abs(i.value)));
  if (items.length === 0) {
    return (
      <div id={id} className="flex h-24 items-center justify-center rounded-xl bg-slate-50 text-sm font-bold text-slate-400">
        {emptyText}
      </div>
    );
  }
  return (
    <ul id={id} className="space-y-2.5">
      {items.map((it, i) => (
        <li key={it.key}>
          <div className="mb-1 flex items-center gap-2 text-xs">
            <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md bg-slate-100 text-[10px] font-extrabold text-slate-500">
              {i + 1}
            </span>
            <span className="min-w-0 flex-1 truncate font-extrabold text-slate-700">{it.label}</span>
            {it.badge}
            <span className="tabular-nums font-extrabold text-slate-800">
              {valueLabel ? valueLabel(it.value) : fmtNum(it.value)}
            </span>
          </div>
          <div className="h-2.5 w-full overflow-hidden rounded-full bg-slate-100">
            <div
              className="h-full rounded-full transition-all duration-500"
              style={{
                width: `${Math.max(2, (Math.abs(it.value) / max) * 100)}%`,
                background: it.color ?? seriesColor(i),
              }}
            />
          </div>
          {(it.sublabel || it.secondary) && (
            <div className="mt-1 flex items-center justify-between text-[10px] font-bold text-slate-400">
              <span className="truncate">{it.sublabel}</span>
              <span className="tabular-nums">{it.secondary}</span>
            </div>
          )}
        </li>
      ))}
    </ul>
  );
}

// =====================================================================
// DonutRing — single ratio
// =====================================================================
export function DonutRing({
  value, total, label, size = 96, color = '#10b981', track = '#e2e8f0',
}: {
  value: number;
  total: number;
  label: string;
  size?: number;
  color?: string;
  track?: string;
}) {
  const r = 40;
  const c = 2 * Math.PI * r;
  const p = total > 0 ? Math.min(1, value / total) : 0;
  return (
    <div className="flex flex-col items-center">
      <svg width={size} height={size} viewBox="0 0 100 100" className="-rotate-90">
        <circle cx={50} cy={50} r={r} fill="none" stroke={track} strokeWidth={12} />
        <circle
          cx={50} cy={50} r={r} fill="none" stroke={color} strokeWidth={12}
          strokeDasharray={`${c * p} ${c * (1 - p)}`} strokeLinecap="round"
          className="transition-all duration-700"
        />
        <text
          x={50} y={50} textAnchor="middle" dominantBaseline="central"
          className="rotate-90" style={{ transformOrigin: '50px 50px', fontFamily: 'inherit' }}
          fontSize={20} fontWeight={800} fill="#1e293b"
        >
          {Math.round(p * 100)}%
        </text>
      </svg>
      <p className="mt-1 text-[11px] font-extrabold text-slate-500">{label}</p>
      <p className="text-[10px] font-bold tabular-nums text-slate-400">
        {fmtNum(value)} من {fmtNum(total)}
      </p>
    </div>
  );
}

// =====================================================================
// MiniStat — small inline stat used inside sections
// =====================================================================
export function MiniStat({ label, value, tone = 'slate' }: { label: string; value: string | number; tone?: 'slate' | 'emerald' | 'gold' | 'rose' | 'primary' }) {
  const tones = {
    slate: 'bg-slate-50 text-slate-700',
    emerald: 'bg-emerald-50 text-emerald-700',
    gold: 'bg-gold-50 text-gold-700',
    rose: 'bg-rose-50 text-rose-700',
    primary: 'bg-primary-50 text-primary-700',
  } as const;
  return (
    <div className={`rounded-xl px-3 py-2 ${tones[tone]}`}>
      <p className="text-lg font-extrabold tabular-nums leading-none">{typeof value === 'number' ? fmtNum(value) : value}</p>
      <p className="mt-1 text-[10px] font-bold opacity-80">{label}</p>
    </div>
  );
}
