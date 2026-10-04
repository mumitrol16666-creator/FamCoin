const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

// Run the helper shipped in index.html, not a copy of its implementation.
const html = readFileSync(join(__dirname, '../web/index.html'), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .find((match) => match[1].includes('window.famcoinPush ='))[1];

function browser({ permission = 'default', answer = 'granted', ios = false } = {}) {
  const storage = new Map();
  const calls = { permission: 0, register: 0, subscribe: 0 };
  let subscription = null;
  let failSubscription = false;
  const registration = {
    pushManager: {
      getSubscription: async () => subscription,
      subscribe: async ({ userVisibleOnly, applicationServerKey }) => {
        calls.subscribe++;
        if (failSubscription) throw new Error('Push service unavailable');
        assert.equal(userVisibleOnly, true);
        assert.deepEqual([...applicationServerKey], [1, 2, 3]);
        subscription = {
          endpoint: 'https://push.example.test/device',
          toJSON: () => ({ endpoint: subscription.endpoint, keys: { p256dh: 'key', auth: 'auth' } }),
          unsubscribe: async () => { subscription = null; return true; },
        };
        return subscription;
      },
    },
  };
  const context = vm.createContext({
    navigator: {
      userAgent: ios ? 'iPhone' : 'Safari',
      platform: 'MacIntel',
      maxTouchPoints: 0,
      serviceWorker: {
        register: () => { calls.register++; return Promise.resolve(registration); },
        ready: Promise.resolve(registration),
      },
    },
    Notification: {
      permission,
      requestPermission() {
        calls.permission++;
        this.permission = answer;
        return Promise.resolve(answer);
      },
    },
    PushManager: function () {},
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
    atob: (value) => Buffer.from(value, 'base64').toString('binary'),
  });
  context.window = context;
  vm.runInContext(script, context);
  return {
    context, calls, storage,
    get push() { return context.famcoinPush; },
    reload() { vm.runInContext(script, context); },
    failSubscription(value) { failSubscription = value; },
  };
}

test('Mac permission prompt runs synchronously before registering the service worker', async () => {
  const b = browser();
  const result = b.push.requestPermission();
  assert.equal(b.calls.permission, 1);
  assert.equal(b.calls.register, 0);
  assert.equal(await result, 'granted');
  assert.equal(await b.push.requestPermission(), 'granted');
  assert.equal(b.calls.permission, 1);
});

for (const permission of ['denied', 'default']) {
  test(`${permission}: no subscription when permission is not granted`, async () => {
    const b = browser({ permission, answer: permission });
    assert.equal(await b.push.requestPermission(), permission);
    assert.equal(await b.push.enable('AQID'), '');
    assert.equal(b.calls.register, 0);
    assert.equal(b.calls.subscribe, 0);
  });
}

test('server confirmation is required; reload and retry keep the existing subscription', async () => {
  const b = browser({ permission: 'granted' });
  const first = JSON.parse(await b.push.enable('AQID'));
  assert.deepEqual(first, { endpoint: 'https://push.example.test/device', p256dh: 'key', auth: 'auth' });
  assert.equal(await b.push.status(), 'off');
  b.reload();
  assert.equal(await b.push.status(), 'off');
  assert.deepEqual(JSON.parse(await b.push.enable('AQID')), first);
  assert.equal(b.calls.subscribe, 1);
  b.push.confirmEnabled();
  assert.equal(await b.push.status(), 'on');
  assert.equal(await b.push.disable(), first.endpoint);
  assert.equal(await b.push.status(), 'off');
});

test('push service failure remains retryable without another permission prompt', async () => {
  const b = browser({ permission: 'granted' });
  b.failSubscription(true);
  await assert.rejects(b.push.enable('AQID'), /unavailable/);
  assert.equal(await b.push.status(), 'off');
  b.failSubscription(false);
  await b.push.enable('AQID');
  b.push.confirmEnabled();
  assert.equal(await b.push.status(), 'on');
  assert.equal(b.calls.permission, 0);
});

test('iPhone browser and browsers without push do not request unusable permissions', async () => {
  const ios = browser({ ios: true });
  assert.equal(await ios.push.requestPermission(), 'needs-install');
  assert.equal(ios.calls.permission, 0);
  const unsupported = browser();
  delete unsupported.context.PushManager;
  assert.equal(await unsupported.push.requestPermission(), 'unsupported');
  assert.equal(unsupported.calls.permission, 0);
});
