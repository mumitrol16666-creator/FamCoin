// Покадровый рендер сторис: headless Chrome по протоколу DevTools (без npm-пакетов),
// window.seek(t) на каждый кадр, затем ffmpeg → MP4 1080×1920.
//   node render.mjs story01.html out/story01.mp4 20 [30] [озвучка.m4a]
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const [, , html, out, durArg, fpsArg, audio] = process.argv;
if (!html || !out) { console.error('node render.mjs story.html out.mp4 [секунды] [fps] [audio]'); process.exit(1); }
const dur = Number(durArg || 20), fps = Number(fpsArg || 30), frames = Math.round(dur * fps);
const work = mkdtempSync(join(process.env.TMPDIR || tmpdir(), 'famcoin-story-'));
const port = 9300 + Math.floor(Math.random() * 600);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${join(work, 'profile')}`,
  '--hide-scrollbars', '--force-device-scale-factor=1', '--window-size=1080,1920',
  '--allow-file-access-from-files', '--disable-gpu-vsync', '--no-first-run', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chromeExited = new Promise((r) => chrome.once('exit', r));
// Chrome пишет профиль до самого выхода — ждём его, потом убираем папку.
async function cleanup() {
  try { ws.close(); } catch {}
  chrome.kill();
  await Promise.race([chromeExited, sleep(5000)]);
  try { rmSync(work, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch {}
}
let target;
for (let i = 0; i < 100 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); } catch { await sleep(100); }
}
if (!target) { chrome.kill(); throw new Error('Chrome не запустился'); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let seq = 0; const waiting = new Map(); const events = [];
ws.addEventListener('message', (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && waiting.has(msg.id)) { const { ok, fail } = waiting.get(msg.id); waiting.delete(msg.id); msg.error ? fail(new Error(msg.error.message)) : ok(msg.result); }
  else if (msg.method) events.push(msg.method);
});
const cdp = (method, params = {}) => new Promise((ok, fail) => { const id = ++seq; waiting.set(id, { ok, fail }); ws.send(JSON.stringify({ id, method, params })); });

await cdp('Page.enable');
await cdp('Emulation.setDeviceMetricsOverride', { width: 1080, height: 1920, deviceScaleFactor: 1, mobile: false });
await cdp('Page.navigate', { url: pathToFileURL(resolve(html)).href });
for (let i = 0; i < 200 && !events.includes('Page.loadEventFired'); i++) await sleep(50);
await cdp('Runtime.evaluate', { expression: 'document.fonts.ready.then(() => Promise.all([...document.images].map(i => i.decode().catch(() => {}))))', awaitPromise: true });

// Отдельные кадры для проверки: STILLS="2.5,7,16" node render.mjs story.html папка
if (process.env.STILLS) {
  mkdirSync(resolve(out), { recursive: true });
  for (const t of process.env.STILLS.split(',').map(Number)) {
    await cdp('Runtime.evaluate', { expression: `seek(${t})` });
    const { data } = await cdp('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(resolve(out), `t${t}.png`), Buffer.from(data, 'base64'));
  }
  await cleanup();
  console.log('кадры:', resolve(out));
  process.exit(0);
}

// Звуковые подсказки сцены (<script id="sfx">) → WAV через sfx.py.
const cuesRes = await cdp('Runtime.evaluate', { expression: `(document.getElementById('sfx') || {}).textContent || ''`, returnByValue: true });
let sfxWav = null;
if (cuesRes.result.value.trim()) {
  writeFileSync(join(work, 'cues.json'), cuesRes.result.value);
  sfxWav = join(work, 'sfx.wav');
  execFileSync('python3', [join(dirname(fileURLToPath(import.meta.url)), 'sfx.py'), join(work, 'cues.json'), String(dur), sfxWav], { stdio: 'inherit' });
}

const dir = join(work, 'frames'); mkdirSync(dir);
const t0 = Date.now();
for (let f = 0; f < frames; f++) {
  await cdp('Runtime.evaluate', { expression: `seek(${(f / fps).toFixed(4)})` });
  const { data } = await cdp('Page.captureScreenshot', { format: 'jpeg', quality: 94, captureBeyondViewport: false });
  writeFileSync(join(dir, String(f).padStart(5, '0') + '.jpg'), Buffer.from(data, 'base64'));
  if (f % fps === 0) process.stdout.write(`\r${Math.round((f / frames) * 100)}%`);
}
process.stdout.write(`\r100% — ${frames} кадров за ${((Date.now() - t0) / 1000).toFixed(0)} с\n`);

mkdirSync(dirname(resolve(out)), { recursive: true });
const args = ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(dir, '%05d.jpg')];
if (sfxWav) args.push('-i', sfxWav);
if (audio) args.push('-i', audio);
if (sfxWav && audio) {
  // Голос главный: эффекты приглушаются, пока он звучит.
  args.push('-filter_complex', '[2:a]aresample=48000,volume=1.0,asplit=2[v1][v2];[1:a][v1]sidechaincompress=threshold=0.03:ratio=8:attack=15:release=350[fx];[fx][v2]amix=inputs=2:normalize=0,alimiter=limit=0.95[a]', '-map', '0:v', '-map', '[a]');
} else if (sfxWav || audio) {
  args.push('-map', '0:v', '-map', '1:a');
}
if (sfxWav || audio) args.push('-c:a', 'aac', '-b:a', '192k', '-t', String(dur));
args.push('-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', resolve(out));
execFileSync('ffmpeg', args, { stdio: 'inherit' });
await cleanup();
console.log('готово:', resolve(out));
