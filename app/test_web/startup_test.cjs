const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const html = readFileSync(join(__dirname, '../web/index.html'), 'utf8');
const startup = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .find(match => match[1].includes('window.famcoinStartup ='))[1];
const bootstrap = readFileSync(join(__dirname, '../web/flutter_bootstrap.js'), 'utf8')
  .replace(/\{\{flutter_(?:js|build_config)\}\}/g, '');

function browser({ locale = 'ru', blockedStorage = false, ios = false, ipad = false } = {}) {
  const listeners = new Map();
  const nodes = new Map();
  const timers = new Map();
  let now = 0, timerId = 0, reloads = 0, app = null;
  function target() {
    const handlers = new Map();
    return {
      hidden: false, textContent: '',
      addEventListener(name, callback) { handlers.set(name, callback); },
      fire(name, event = {}) { handlers.get(name)?.(event); },
    };
  }
  for (const id of ['splash', 'startup-status', 'startup-ring', 'startup-retry']) {
    nodes.set('famcoin-' + id, target());
  }
  nodes.get('famcoin-startup-retry').hidden = true;
  const document = Object.assign(target(), {
    visibilityState: 'visible',
    getElementById: id => nodes.get(id),
    querySelector: () => app,
  });
  const context = vm.createContext({
    document,
    navigator: { userAgent: ios ? 'iPhone' : 'Macintosh', platform: 'MacIntel', maxTouchPoints: ipad ? 5 : 0 },
    localStorage: { getItem() { if (blockedStorage) throw Error('Storage blocked'); return JSON.stringify(locale); } },
    location: { reload() { reloads++; } },
    addEventListener: (name, fn) => listeners.set(name, fn),
    setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
    console: { error() {} },
  });
  context.window = context;
  vm.runInContext(startup, context);
  return {
    context, document,
    node: id => nodes.get('famcoin-' + id),
    event: (name, event = {}) => listeners.get(name)?.(event),
    get reloads() { return reloads; },
    set app(value) { app = value; },
    advance(ms) {
      now += ms;
      for (const [id, timer] of timers) if (timer.at <= now) { timers.delete(id); timer.fn(); }
    },
    boot(loader) { context._flutter = { loader: { load: loader } }; return vm.runInContext(bootstrap, context); },
  };
}

test('stalled cold start offers recovery; a late first frame still opens the app', () => {
  const b = browser();
  b.advance(25000);
  assert.equal(b.node('startup-retry').hidden, false);
  assert.match(b.node('startup-status').textContent, /Загрузка затянулась/);
  assert.equal(b.reloads, 0, 'no automatic reload loop on a slow connection');
  b.event('flutter-first-frame');
  assert.equal(b.node('splash').hidden, true);
  b.advance(60000);
  assert.equal(b.node('splash').hidden, true);
});

test('script/network errors and uncaught startup failures show a working retry', () => {
  for (const [event, details] of [['error', { target: { tagName: 'SCRIPT' } }], ['error', { error: Error('Settings') }], ['unhandledrejection', {}]]) {
    const b = browser();
    b.event(event, details);
    assert.equal(b.node('startup-retry').hidden, false);
    assert.match(b.node('startup-status').textContent, /Не удалось/);
    b.node('startup-retry').fire('click');
    assert.equal(b.reloads, 1);
  }
});

test('a working app is not covered by unrelated runtime failures or an old timeout', () => {
  const b = browser();
  b.event('flutter-first-frame');
  b.event('unhandledrejection');
  b.context.famcoinStartup.fail();
  b.advance(60000);
  assert.equal(b.node('splash').hidden, true);
});

test('lost application view on resume offers recovery without losing input automatically', () => {
  const b = browser();
  b.app = {};
  b.event('flutter-first-frame');
  b.document.fire('visibilitychange');
  b.advance(3000);
  assert.equal(b.node('splash').hidden, true);
  b.app = null;
  b.document.fire('visibilitychange');
  b.advance(3000);
  assert.equal(b.node('splash').hidden, false);
  assert.equal(b.reloads, 0);
});

test('recovery works in Kazakh and when the browser denies access to storage', () => {
  const kk = browser({ locale: 'kk' });
  kk.context.famcoinStartup.fail();
  assert.equal(kk.node('startup-retry').textContent, 'Қайта ашу');
  assert.match(kk.node('startup-status').textContent, /FamCoin ашылмады/);
  const denied = browser({ blockedStorage: true });
  denied.advance(25000);
  assert.equal(denied.node('startup-retry').hidden, false);
});

for (const device of [{ ios: true }, { ipad: true }, {}]) {
  test(`engine and loader share local assets configuration: ${JSON.stringify(device)}`, async () => {
    const b = browser(device);
    let initialized = false, ran = false;
    b.boot(async options => {
      assert.equal(options.config.canvasKitBaseUrl, 'canvaskit/');
      assert.equal(options.config.renderer, device.ios || device.ipad ? 'canvaskit' : undefined);
      await options.onEntrypointLoaded({
        async initializeEngine(config) {
          initialized = true;
          assert.equal(config, options.config, 'custom callback must forward the configuration');
          return { async runApp() { ran = true; } };
        },
      });
    });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(initialized && ran, true);
  });
}

test('loader, engine and Dart entrypoint failures all reach the HTML recovery screen', async () => {
  for (const stage of ['loader', 'engine', 'app']) {
    const b = browser({ ios: true });
    b.boot(async options => {
      if (stage === 'loader') throw Error('Network failed');
      await options.onEntrypointLoaded({
        async initializeEngine() {
          if (stage === 'engine') throw Error('Engine failed');
          return { async runApp() { throw Error('App failed'); } };
        },
      });
    });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(b.node('startup-retry').hidden, false, stage);
    assert.equal(b.reloads, 0);
  }
});
