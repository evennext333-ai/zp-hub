import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';

const origin = process.env.HUB_BROWSER_TEST_ORIGIN;
test('Key page empty-body actions omit JSON Content-Type', async () => {
  const nodes = new Map(), requests = [], button = { disabled: false };
  function element(id) {
    if (!nodes.has(id)) nodes.set(id, {
      value: '', elements: {}, listeners: {},
      addEventListener(name, callback) { this.listeners[name] = callback; },
    });
    return nodes.get(id);
  }
  const context = vm.createContext({
    document: { getElementById: element, querySelectorAll: () => [button] },
    window: { confirm: () => true }, AbortSignal,
    fetch: async (path, options) => {
      requests.push({ path, options });
      return { ok: true, json: async () => ({ success: true, data: path.endsWith('/keys') ? [] : null }) };
    },
  });
  vm.runInContext(readFileSync(new URL('../src/keys.js', import.meta.url), 'utf8'), context);
  const form = element('revoke');
  form.elements.id = { value: randomUUID() };
  form.listeners.submit({ target: form, preventDefault() {} });
  for (let i = 0; i < 50 && button.disabled; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(button.disabled, false);
  assert.equal(requests.length, 2);
  assert.match(requests[0].path, /\/revoke$/);
  assert.equal(requests[0].options.method, 'POST');
  assert.equal(requests[0].options.body, undefined);
  assert.equal(requests[0].options.headers['Content-Type'], undefined);
  assert.equal(element('status').textContent, '权益已吊销');
});

test('Key page actions against isolated real API', { skip: !origin }, async () => {
  const url = new URL(origin);
  assert.ok(['127.0.0.1', 'localhost'].includes(url.hostname), '仅允许隔离本地测试服务');
  function element() {
    return {
      hidden: false, value: '', textContent: '', checked: false, elements: {}, listeners: {}, children: [],
      addEventListener(name, callback) { this.listeners[name] = callback; },
      replaceChildren() { this.children = []; this.value = ''; },
      append(child) { this.children.push(child); if (!this.value) this.value = child.value; },
      fire(name) { this.listeners[name]({ target: this, preventDefault() {} }); },
    };
  }
  const ids = ['login', 'controls', 'status', 'issued', 'key', 'records', 'member', 'issue', 'revoke',
    'refresh', 'logout', 'claim', 'reset', 'copy', 'clear'];
  const elements = Object.fromEntries(ids.map((id) => [id, element()]));
  const buttons = [element(), element()];
  elements.login.elements = { account: element(), password: element(), admin: element() };
  elements.issue.elements.gameId = element();
  elements.revoke.elements.id = element();
  let copied = '';
  class FormDataFixture {
    constructor(form) { this.form = form; }
    get(name) { return this.form.elements[name].value; }
    has(name) { return this.form.elements[name].checked; }
  }
  const context = vm.createContext({
    document: {
      getElementById: (id) => elements[id], querySelectorAll: () => buttons, createElement: element,
    },
    FormData: FormDataFixture, AbortSignal, window: { confirm: () => true },
    navigator: { clipboard: { writeText: async (text) => { copied = text; } } },
    fetch: (path, options) => fetch(new URL(path, origin), {
      ...options, headers: { ...options.headers, Origin: origin },
    }),
    localStorage: { setItem() { throw new Error('凭据禁止写入本地存储'); } },
  });
  vm.runInContext(readFileSync(new URL('../src/keys.js', import.meta.url), 'utf8'), context);
  async function settle() {
    for (let i = 0; i < 200 && buttons[0].disabled; i++) await new Promise((resolve) => setTimeout(resolve, 20));
    assert.ok(!buttons[0].disabled, '页面操作未完成');
    assert.ok(!elements.status.textContent.startsWith('操作未完成'), elements.status.textContent);
  }
  async function login(account, admin) {
    elements.login.elements.account.value = account;
    elements.login.elements.password.value = 'BrowserFixture123!';
    elements.login.elements.admin.checked = admin;
    elements.login.fire('submit'); await settle();
    assert.equal(elements.login.elements.password.value, '');
    assert.equal(elements.login.hidden, true);
  }
  async function api(path, token, body) {
    if (path === '/api/hub/sessions') body = { ...body, universeId: 1, placeId: 2 };
    const response = await fetch(new URL(path, origin), {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  }
  const page = await fetch(new URL('/hub/keys', origin));
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal(page.headers.get('cache-control'), 'no-store');
  await login('hub-browser-admin', true);
  assert.equal(elements.member.hidden, true);
  const catalogResponse = await fetch(new URL('/api/hub/catalog', origin));
  assert.equal(catalogResponse.status, 200);
  const catalog = (await catalogResponse.json()).data;
  const script = catalog.scripts.find((entry) => entry.enabled && (entry.universal
    || entry.placeIds.includes(2) || (!entry.placeIds.length && entry.universeIds.includes(1))));
  assert.ok(script, '本地大厅夹具需启用适配测试游戏的 Hub 脚本');
  assert.ok(elements.issue.elements.gameId.children.some((option) => option.value === script.gameId));
  elements.issue.elements.gameId.value = script.gameId;
  elements.issue.fire('submit'); await settle();
  const gameKey = elements.key.value;
  assert.match(gameKey, /^RSH_[A-Za-z0-9_-]{43}$/);
  const licenseId = JSON.parse(elements.records.textContent).find((item) => item.keys.some((key) => gameKey.startsWith(key.prefix))).id;
  const a = await api('/api/hub/sessions', null, { key: gameKey, hwid: 'device-a', requestId: randomUUID() });
  const b = await api('/api/hub/sessions', null, { key: gameKey, hwid: 'device-a', requestId: randomUUID() });
  assert.equal(a.status, 200); assert.equal(b.status, 200);
  assert.equal((await api('/api/hub/sessions/heartbeat', a.body.data.token, { sequence: 1 })).status, 401);
  assert.equal((await api(`/api/hub/scripts/${script.id}/load`, b.body.data.token, {})).status, 200);
  elements.revoke.elements.id.value = licenseId;
  elements.revoke.fire('submit'); await settle();
  assert.equal((await api('/api/hub/sessions/heartbeat', b.body.data.token, { sequence: 2 })).status, 401);
  elements.logout.fire('click');
  await login('hub-browser-member', false);
  assert.equal(elements.member.hidden, false);
  elements.claim.fire('click'); await settle();
  const old = elements.key.value;
  elements.reset.fire('click'); await settle();
  const next = elements.key.value;
  assert.notEqual(next, old);
  assert.equal((await api('/api/hub/sessions', null, { key: old, hwid: 'a', requestId: randomUUID() })).status, 401);
  assert.equal((await api('/api/hub/sessions', null, { key: next, hwid: 'b', requestId: randomUUID() })).status, 200);
  elements.copy.fire('click'); await settle();
  assert.equal(copied, next);
  elements.clear.fire('click');
  assert.equal(elements.key.value, '');
  elements.logout.fire('click');
  assert.equal(elements.controls.hidden, true);
});
