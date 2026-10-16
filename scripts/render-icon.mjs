// Renders app/AppIcon.svg into app/AppIcon.iconset (all sizes macOS wants).
// Needs Playwright with a Chromium: PLAYWRIGHT=/path/to/playwright-core/index.mjs CHROME=/path/to/chrome node scripts/render-icon.mjs
import { readFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
const { chromium } = await import(process.env.PLAYWRIGHT ?? 'playwright');
const here = import.meta.dirname;
const svg = readFileSync(path.join(here, '../app/AppIcon.svg'), 'utf8');
const out = path.join(here, '../app/AppIcon.iconset');
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ executablePath: process.env.CHROME });
const sizes = [16, 32, 128, 256, 512];
for (const base of sizes) {
  for (const scale of [1, 2]) {
    const px = base * scale;
    const page = await browser.newPage({ viewport: { width: px, height: px } });
    await page.setContent(`<body style="margin:0;background:transparent"><div style="width:${px}px;height:${px}px">${svg.replace('<svg ', `<svg width="${px}" height="${px}" `)}</div></body>`);
    await page.screenshot({
      path: path.join(out, `icon_${base}x${base}${scale === 2 ? '@2x' : ''}.png`),
      omitBackground: true,
    });
    await page.close();
  }
}
await browser.close();
