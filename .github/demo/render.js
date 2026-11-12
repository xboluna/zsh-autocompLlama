// Screenshot the demo animation frame by frame. demo.html is deterministic:
// window.render(t) draws the frame at t milliseconds, so the frames are the
// same every time.
//
//   node render.js frames <out dir> [fps]         every frame, as f00000.png ...
//   node render.js stills <out dir> <ms> [<ms>...]  single frames, to look at
//
// Needs playwright-core (npm i playwright-core) and a Chromium: set CHROMIUM
// to its executable if Playwright has not downloaded one itself.
const { chromium } = require('playwright-core');
const path = require('path');
const fs = require('fs');
(async () => {
  const [,, mode, outDir, ...rest] = process.argv;
  const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1.5 });
  // ?flat: without the slow push-in, which a GIF cannot afford (see demo.html).
  await page.goto('file://' + path.resolve(__dirname, 'demo.html') + '?flat');
  await page.evaluate(() => document.fonts.ready);
  const dur = await page.evaluate(() => window.DURATION);
  fs.mkdirSync(outDir, { recursive: true });
  if (mode === 'stills') {
    for (const t of rest.map(Number)) {
      await page.evaluate((t) => window.render(t), t);
      await page.screenshot({ path: `${outDir}/still-${t}.png` });
    }
  } else {
    const fps = Number(rest[0] || 15);
    const n = Math.ceil(dur / 1000 * fps);
    for (let i = 0; i < n; i++) {
      await page.evaluate((t) => window.render(t), i * 1000 / fps);
      await page.screenshot({ path: `${outDir}/f${String(i).padStart(5, '0')}.png` });
    }
  }
  console.log('duration', dur);
  await browser.close();
})();
