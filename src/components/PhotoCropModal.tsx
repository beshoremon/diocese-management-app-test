'use client';

import { useCallback, useState } from 'react';
import Cropper, { type Area } from 'react-easy-crop';
import { X, Check, Loader2, ZoomIn } from 'lucide-react';

/**
 * Crop / zoom / move an image, then export a small square WEBP blob.
 * Output: 512×512 webp, quality lowered until ≤ ~150 KB for minimal storage.
 */

const OUTPUT_SIZE = 512;
const MAX_BYTES = 150 * 1024;

async function cropToWebp(imageSrc: string, area: Area): Promise<Blob> {
  const img = await new Promise<HTMLImageElement>((resolve, reject) => {
    const i = new Image();
    i.onload = () => resolve(i);
    i.onerror = reject;
    i.src = imageSrc;
  });

  const canvas = document.createElement('canvas');
  canvas.width = OUTPUT_SIZE;
  canvas.height = OUTPUT_SIZE;
  const ctx = canvas.getContext('2d')!;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(
    img,
    area.x, area.y, area.width, area.height,
    0, 0, OUTPUT_SIZE, OUTPUT_SIZE
  );

  // Reduce quality until small enough
  for (const q of [0.8, 0.65, 0.5, 0.35, 0.25]) {
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/webp', q)
    );
    if (blob && (blob.size <= MAX_BYTES || q === 0.25)) return blob;
  }
  throw new Error('webp encoding failed');
}

export default function PhotoCropModal({
  src, onDone, onClose,
}: {
  src: string;
  onDone: (blob: Blob) => void;
  onClose: () => void;
}) {
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedArea, setCroppedArea] = useState<Area | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const onCropComplete = useCallback((_: Area, areaPixels: Area) => {
    setCroppedArea(areaPixels);
  }, []);

  const confirm = async () => {
    if (!croppedArea) return;
    setBusy(true);
    setError('');
    try {
      const blob = await cropToWebp(src, croppedArea);
      onDone(blob);
    } catch {
      setError('تعذر معالجة الصورة، جرّب صورة أخرى');
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex flex-col bg-black">
      {/* Header */}
      <div className="flex items-center justify-between p-4 text-white">
        <h3 className="text-base font-extrabold">ضبط الصورة</h3>
        <button onClick={onClose} aria-label="إغلاق" className="rounded-full p-1.5 hover:bg-white/10">
          <X className="h-5 w-5" />
        </button>
      </div>

      {/* Cropper area */}
      <div className="relative flex-1">
        <Cropper
          image={src}
          crop={crop}
          zoom={zoom}
          aspect={1}
          cropShape="round"
          showGrid={false}
          onCropChange={setCrop}
          onZoomChange={setZoom}
          onCropComplete={onCropComplete}
        />
      </div>

      {/* Controls */}
      <div className="space-y-3 p-4">
        <div className="flex items-center gap-3 text-white">
          <ZoomIn className="h-4 w-4 shrink-0" />
          <input
            id="crop-zoom"
            type="range"
            min={1}
            max={4}
            step={0.05}
            value={zoom}
            onChange={(e) => setZoom(Number(e.target.value))}
            className="w-full accent-white"
            aria-label="تكبير"
          />
        </div>

        {error && (
          <p className="rounded-xl bg-red-500/20 px-3 py-2 text-sm font-bold text-red-300">{error}</p>
        )}

        <button
          id="crop-confirm"
          onClick={confirm}
          disabled={busy}
          className="btn-primary w-full flex items-center justify-center gap-2"
        >
          {busy ? <Loader2 className="h-5 w-5 animate-spin" /> : <Check className="h-5 w-5" />}
          تأكيد الصورة
        </button>
      </div>
    </div>
  );
}
