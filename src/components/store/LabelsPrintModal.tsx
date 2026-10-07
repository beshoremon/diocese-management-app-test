'use client';

// ---------- Print QR labels for inventory items ----------
// Every label = QR (item code) + name + price in points + code text.
// Label size presets (mm), copies per item (default = 1, or = stock),
// A4 sheet with auto grid. Printing uses the same hidden mm-exact portal
// technique as the card module (body children hidden under @media print).

import { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import QRCode from 'qrcode';
import { X, Printer, Loader2, Tag } from 'lucide-react';
import { LABEL_SIZES, type LabelSize } from '@/lib/store';
import type { StoreItem } from '@/lib/types';

const PAPER = { w: 210, h: 297 }; // A4 portrait
const MARGIN = 8;
const GAP = 3;

export default function LabelsPrintModal({ items, onClose }: { items: StoreItem[]; onClose: () => void }) {
  const [size, setSize] = useState<LabelSize>('medium');
  const [copiesMode, setCopiesMode] = useState<'one' | 'stock' | 'custom'>('one');
  const [custom, setCustom] = useState('2');
  const [showPrice, setShowPrice] = useState(true);
  const [qrs, setQrs] = useState<Record<string, string>>({});
  const [printing, setPrinting] = useState(false);

  // generate QR data URLs once per item
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const out: Record<string, string> = {};
      for (const it of items) {
        try {
          out[it.id] = await QRCode.toDataURL(it.code, { margin: 0, width: 256, errorCorrectionLevel: 'M' });
        } catch { /* skip */ }
      }
      if (!cancelled) setQrs(out);
    })();
    return () => { cancelled = true; };
  }, [items]);

  const copiesOf = (it: StoreItem) =>
    copiesMode === 'one' ? 1 : copiesMode === 'stock' ? Math.max(1, it.stock) : Math.max(1, parseInt(custom, 10) || 1);

  const labels = useMemo(() => {
    const out: StoreItem[] = [];
    for (const it of items) for (let i = 0; i < Math.min(copiesOf(it), 500); i++) out.push(it);
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, copiesMode, custom]);

  const L = LABEL_SIZES[size];
  const cols = Math.max(1, Math.floor((PAPER.w - 2 * MARGIN + GAP) / (L.w + GAP)));
  const rows = Math.max(1, Math.floor((PAPER.h - 2 * MARGIN + GAP) / (L.h + GAP)));
  const perPage = cols * rows;
  const pages = useMemo(() => {
    const p: StoreItem[][] = [];
    for (let i = 0; i < labels.length; i += perPage) p.push(labels.slice(i, i + perPage));
    return p;
  }, [labels, perPage]);

  const ready = items.every((it) => qrs[it.id]);

  const print = () => {
    setPrinting(true);
    setTimeout(() => { window.print(); setPrinting(false); }, 150);
  };

  const Label = ({ it, scale = 1 }: { it: StoreItem; scale?: number }) => (
    <div
      className="store-label"
      style={{
        width: `${L.w * scale}mm`, height: `${L.h * scale}mm`,
        display: 'flex', alignItems: 'center', gap: `${2 * scale}mm`,
        padding: `${1.5 * scale}mm`, boxSizing: 'border-box',
        border: '0.2mm dashed #cbd5e1', borderRadius: `${1.5 * scale}mm`, background: '#fff', overflow: 'hidden',
      }}
      dir="rtl"
    >
      {qrs[it.id] && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={qrs[it.id]} alt={it.code} style={{ width: `${L.qr * scale}mm`, height: `${L.qr * scale}mm`, flexShrink: 0 }} />
      )}
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', justifyContent: 'center', lineHeight: 1.15 }}>
        <div style={{ fontWeight: 800, fontSize: `${Math.max(2.6, L.h * 0.13) * scale}mm`, overflow: 'hidden', textOverflow: 'ellipsis', display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical' }}>
          {it.name}
        </div>
        {showPrice && (
          <div style={{ fontWeight: 800, fontSize: `${Math.max(2.8, L.h * 0.15) * scale}mm`, color: '#c2410c', marginTop: `${0.5 * scale}mm` }}>
            {it.price} نقطة
          </div>
        )}
        <div dir="ltr" style={{ fontFamily: 'monospace', fontSize: `${Math.max(2, L.h * 0.09) * scale}mm`, color: '#64748b', marginTop: `${0.5 * scale}mm`, textAlign: 'right' }}>
          {it.code}
        </div>
      </div>
    </div>
  );

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-0 sm:items-center sm:p-6" onClick={onClose}>
      <div id="labels-print-modal" className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-white p-5 sm:rounded-3xl" onClick={(e) => e.stopPropagation()}>
        <div className="mb-4 flex items-center justify-between">
          <h3 className="flex items-center gap-2 text-lg font-extrabold"><Tag className="h-5 w-5 text-orange-600" /> طباعة ملصقات QR</h3>
          <button type="button" onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-slate-100"><X className="h-5 w-5" /></button>
        </div>

        <p className="mb-3 text-xs font-bold text-slate-500">{items.length} صنف → {labels.length} ملصق · {pages.length} صفحة A4 ({cols}×{rows} في الصفحة)</p>

        <div className="mb-3">
          <label className="mb-1 block text-xs font-bold text-slate-500">مقاس الملصق</label>
          <div className="grid grid-cols-3 gap-2">
            {(Object.keys(LABEL_SIZES) as LabelSize[]).map((k) => (
              <button key={k} type="button" id={`label-size-${k}`} onClick={() => setSize(k)}
                className={`rounded-xl px-2 py-2 text-xs font-extrabold transition ${size === k ? 'bg-orange-600 text-white shadow' : 'border border-slate-200 bg-white text-slate-600'}`}>
                {LABEL_SIZES[k].label}
              </button>
            ))}
          </div>
        </div>

        <div className="mb-3">
          <label className="mb-1 block text-xs font-bold text-slate-500">عدد النسخ لكل صنف</label>
          <div className="grid grid-cols-3 gap-2">
            {([['one', 'نسخة واحدة'], ['stock', 'بعدد الكمية'], ['custom', 'عدد محدد']] as const).map(([k, l]) => (
              <button key={k} type="button" id={`label-copies-${k}`} onClick={() => setCopiesMode(k)}
                className={`rounded-xl px-2 py-2 text-xs font-extrabold transition ${copiesMode === k ? 'bg-primary-600 text-white shadow' : 'border border-slate-200 bg-white text-slate-600'}`}>
                {l}
              </button>
            ))}
          </div>
          {copiesMode === 'custom' && (
            <input type="number" min={1} max={500} inputMode="numeric" className="input-field mt-2 text-center font-extrabold tabular-nums"
              value={custom} onChange={(e) => setCustom(e.target.value)} />
          )}
        </div>

        <label className="mb-4 flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2.5 text-sm font-bold">
          <input type="checkbox" checked={showPrice} onChange={(e) => setShowPrice(e.target.checked)} className="h-4 w-4 accent-orange-600" />
          إظهار السعر بالنقاط على الملصق
        </label>

        {/* preview of the first label */}
        {items[0] && (
          <div className="mb-4 flex justify-center rounded-2xl bg-slate-50 p-3">
            <Label it={items[0]} scale={1.6} />
          </div>
        )}

        <button id="labels-print-btn" type="button" onClick={print} disabled={!ready || labels.length === 0 || printing}
          className="btn-primary flex w-full items-center justify-center gap-2 !from-orange-600 !to-orange-500">
          {printing || !ready ? <Loader2 className="h-5 w-5 animate-spin" /> : <Printer className="h-5 w-5" />}
          طباعة {labels.length} ملصق
        </button>
        <p className="mt-2 text-center text-[11px] font-bold text-slate-400">في نافذة الطباعة: ورق A4 · الهوامش «بلا» · المقياس 100%</p>
      </div>

      {/* hidden print sheet */}
      {typeof document !== 'undefined' && createPortal(
        <div id="store-labels-print-root" dir="rtl">
          <style>{`
            #store-labels-print-root { display: none; }
            @media print {
              body > *:not(#store-labels-print-root) { display: none !important; }
              #store-labels-print-root { display: block !important; }
              @page { size: ${PAPER.w}mm ${PAPER.h}mm; margin: 0; }
              html, body { margin: 0 !important; padding: 0 !important; background: #fff !important; }
              .store-labels-page {
                width: ${PAPER.w}mm; height: ${PAPER.h}mm; box-sizing: border-box;
                padding: ${MARGIN}mm; display: grid;
                grid-template-columns: repeat(${cols}, ${L.w}mm); grid-auto-rows: ${L.h}mm;
                gap: ${GAP}mm; justify-content: start; align-content: start;
                page-break-after: always; break-after: page; overflow: hidden;
              }
              .store-labels-page:last-child { page-break-after: auto; break-after: auto; }
              * { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
            }
          `}</style>
          {pages.map((pg, pi) => (
            <div key={pi} className="store-labels-page">
              {pg.map((it, i) => <Label key={`${it.id}-${i}`} it={it} />)}
            </div>
          ))}
        </div>,
        document.body
      )}
    </div>
  );
}
