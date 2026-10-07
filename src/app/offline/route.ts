// /offline — the page the service worker shows when there is no connection.
// Rendered on the server so the diocese name / icon come from the branding
// environment variables; the SW pre-caches it at install time.
import { NextResponse } from 'next/server';
import { BRANDING, appIcon } from '@/lib/branding';

export const dynamic = 'force-static';

const esc = (s: string) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function GET() {
  const html = `<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="theme-color" content="${esc(BRANDING.themeColor)}" />
  <title>غير متصل — ${esc(BRANDING.dioceseName)}</title>
  <style>
    body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
           font-family: Cairo, system-ui, sans-serif; background: linear-gradient(#f8fafc, #eef2ff); color: #334155; }
    .card { background: #fff; border-radius: 1.25rem; padding: 2rem 1.5rem; text-align: center;
            box-shadow: 0 10px 30px rgba(30,58,138,.12); max-width: 22rem; margin: 1rem; }
    img { width: 72px; height: 72px; border-radius: 1rem; object-fit: cover; }
    h1 { font-size: 1.2rem; margin: 1rem 0 .5rem; color: ${esc(BRANDING.themeColor)}; }
    h2 { font-size: .95rem; margin: 0 0 .75rem; color: #64748b; font-weight: 600; }
    p { font-size: .9rem; margin: 0 0 1.25rem; }
    button { padding: .7rem 1.4rem; border-radius: .9rem; border: 0; background: ${esc(BRANDING.themeColor)}; color: #fff;
             font-weight: 700; font-size: .95rem; cursor: pointer; }
  </style>
</head>
<body>
  <div class="card">
    <img src="${esc(appIcon(96))}" alt="" />
    <h2>${esc(BRANDING.dioceseName)}</h2>
    <h1>لا يوجد اتصال بالإنترنت</h1>
    <p>التطبيق يحتاج اتصالاً لعرض البيانات. تأكد من الاتصال ثم أعد المحاولة.</p>
    <button onclick="location.reload()">إعادة المحاولة</button>
  </div>
</body>
</html>`;
  return new NextResponse(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=0, must-revalidate' },
  });
}
