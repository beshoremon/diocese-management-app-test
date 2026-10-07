'use client';

// ---------- Child portal — birthday banner (أعياد الميلاد, 0028) ----------
// On the child's birthday: a festive banner with his birthday card (the
// template of his scope) that he can save as a picture, plus the gift he
// received. In the 7 days before: a small countdown («باقي N أيام»).

import { useEffect, useMemo, useRef, useState } from 'react';
import { Cake, Download, Gift, Loader2, PartyPopper } from 'lucide-react';
import CardCanvas, { type CardConstantsData, type CardPersonData } from '@/components/cards/CardCanvas';
import { normalizeDesign, type CardDesign, GOOGLE_FONTS } from '@/lib/card-types';
import type { ChildBirthday } from '@/lib/child-portal';

export default function BirthdayBanner({
  data, person,
}: {
  data: ChildBirthday | null;
  person: { name: string; national_id: string; birthdate: string | null; phone: string | null; address: string | null; image_url: string | null };
}) {
  const cardRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);
  const [boxW, setBoxW] = useState(300);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const el = boxRef.current; if (!el) return;
    const ro = new ResizeObserver(() => setBoxW(el.clientWidth - 16));
    ro.observe(el); setBoxW(el.clientWidth - 16);
    return () => ro.disconnect();
  }, [data?.is_birthday]);

  const design: CardDesign | null = useMemo(
    () => (data?.card?.design ? normalizeDesign(data.card.design as Partial<CardDesign>) : null),
    [data?.card]
  );
  const fontsHref = useMemo(
    () => `https://fonts.googleapis.com/css2?${GOOGLE_FONTS.map((f) => `family=${f.replace(/ /g, '+')}:wght@400;700;800`).join('&')}&display=swap`,
    []
  );

  if (!data || !data.birthdate) return null;

  const year = new Date().getFullYear();
  const first = person.name.trim().split(/\s+/)[0] ?? '';

  // countdown (only in the last 7 days, not on the day)
  if (!data.is_birthday) {
    if (data.days_left == null || data.days_left > 7) return null;
    return (
      <section id="child-birthday-soon" className="card mb-4 flex items-center gap-3 !p-3 bg-gradient-to-l from-pink-50 to-white">
        <span className="rounded-2xl bg-pink-100 p-2 text-pink-600"><Cake className="h-6 w-6" /></span>
        <span className="min-w-0 flex-1">
          <span className="block text-sm font-extrabold text-pink-800">عيد ميلادك قريب 🎈</span>
          <span className="block text-xs font-bold text-slate-500">
            {data.days_left === 1 ? 'غداً' : `باقي ${data.days_left} أيام`} — تُتمّ {data.turns_age} سنة
          </span>
        </span>
      </section>
    );
  }

  const cardPerson: CardPersonData = { ...person, birthday_year: year, gift_points: data.gift?.points ?? null };
  const constants: CardConstantsData = data.constants ?? { church_name: '', service_name: '', class_name: '', church_logo_url: null };
  const scale = design ? boxW / design.width : 1;

  const download = async () => {
    if (!cardRef.current || !design) return;
    setBusy(true);
    try {
      const { domToBlob } = await import('modern-screenshot');
      const blob = await domToBlob(cardRef.current, { scale: (300 / 25.4) / scale, type: 'image/png', fetch: { requestInit: { mode: 'cors' } } });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a'); a.href = url; a.download = `birthday-${first}-${year}.png`; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 3000);
    } catch { /* ignore */ }
    finally { setBusy(false); }
  };

  return (
    <section id="child-birthday" className="card mb-4 overflow-hidden !p-0 ring-2 ring-pink-300">
      {/* eslint-disable-next-line @next/next/no-page-custom-font */}
      <link rel="stylesheet" href={fontsHref} />
      <div className="bg-gradient-to-l from-pink-600 to-rose-500 px-4 py-4 text-white">
        <p className="flex items-center gap-2 text-xs font-bold text-pink-100"><PartyPopper className="h-4 w-4" /> اليوم عيد ميلادك!</p>
        <h3 className="text-xl font-extrabold">كل سنة وأنت طيب يا {first} 🎂</h3>
        <p className="text-xs font-bold text-pink-100">تُتمّ اليوم {data.turns_age} سنة — ربنا يفرّح قلبك</p>
      </div>
      {data.gift && (
        <p className="flex items-center gap-2 bg-amber-50 px-4 py-2 text-xs font-extrabold text-amber-800">
          <Gift className="h-4 w-4" /> هديتك: <span className="text-base tabular-nums">+{data.gift.points}</span> نقطة أُضيفت لرصيدك 🎁
        </p>
      )}
      {design ? (
        <div ref={boxRef} className="p-2">
          <div ref={cardRef} style={{ display: 'inline-block' }}>
            <CardCanvas design={design} scale={scale} person={cardPerson} constants={constants} />
          </div>
          <button onClick={download} disabled={busy} className="mt-2 flex w-full items-center justify-center gap-2 rounded-xl bg-pink-600 py-2.5 text-sm font-extrabold text-white active:scale-95">
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />} احفظ كارت عيد ميلادك
          </button>
        </div>
      ) : (
        <p className="px-4 py-3 text-center text-xs font-bold text-slate-400">🎉 خدّامك يهنّئونك ويصلّون من أجلك</p>
      )}
    </section>
  );
}
