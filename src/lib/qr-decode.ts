'use client';

// ---------- QR decoding helpers ----------
// Camera: prefer the native BarcodeDetector (fast, Android Chrome); fall
// back to jsQR on a canvas frame everywhere else (iOS Safari, desktop).
// Gallery: draw the picked image on a canvas (down-scaled) and run jsQR.

import jsQR from 'jsqr';

type BarcodeDetectorCtor = new (opts: { formats: string[] }) => {
  detect: (src: HTMLVideoElement | HTMLCanvasElement | ImageBitmap) => Promise<{ rawValue: string }[]>;
};

export function nativeDetector(): InstanceType<BarcodeDetectorCtor> | null {
  const BD = (window as unknown as { BarcodeDetector?: BarcodeDetectorCtor }).BarcodeDetector;
  if (!BD) return null;
  try {
    return new BD({ formats: ['qr_code'] });
  } catch {
    return null;
  }
}

/** Decode a QR from a canvas via jsQR (returns null when nothing found) */
export function decodeCanvas(canvas: HTMLCanvasElement): string | null {
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx || canvas.width === 0 || canvas.height === 0) return null;
  const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const res = jsQR(img.data, img.width, img.height, { inversionAttempts: 'attemptBoth' });
  return res?.data ?? null;
}

/** Draw the current video frame on `canvas` (down-scaled) and decode it */
export function decodeVideoFrame(video: HTMLVideoElement, canvas: HTMLCanvasElement): string | null {
  const vw = video.videoWidth;
  const vh = video.videoHeight;
  if (!vw || !vh) return null;
  const scale = Math.min(1, 640 / Math.max(vw, vh));
  canvas.width = Math.round(vw * scale);
  canvas.height = Math.round(vh * scale);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return null;
  ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
  return decodeCanvas(canvas);
}

/** Decode a QR from an image file picked from the gallery */
export async function decodeImageFile(file: File): Promise<string | null> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const i = new Image();
      i.onload = () => resolve(i);
      i.onerror = reject;
      i.src = url;
    });
    // Try a few sizes: large photos decode better when down-scaled, tiny
    // screenshots when kept as-is.
    const sizes = [1000, 1600, 600, img.naturalWidth];
    const canvas = document.createElement('canvas');
    for (const max of sizes) {
      const scale = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
      canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
      canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) continue;
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      const code = decodeCanvas(canvas);
      if (code) return code;
    }
    // last try: native detector on the full image (Android)
    const det = nativeDetector();
    if (det) {
      try {
        const bmp = await createImageBitmap(img);
        const codes = await det.detect(bmp);
        if (codes.length) return codes[0].rawValue;
      } catch {
        /* ignore */
      }
    }
    return null;
  } finally {
    URL.revokeObjectURL(url);
  }
}
