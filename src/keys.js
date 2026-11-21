'use strict';
(() => {
  const el = (id) => document.getElementById(id);
  let token = '', admin = false, busy = false;
  const status = (text) => { el('status').textContent = text; };
  const clearKey = () => { el('key').value = ''; el('issued').hidden = true; };
  async function api(path, method = 'GET', body) {
    const response = await fetch(path, {
      method, cache: 'no-store', credentials: 'omit',
      headers: { ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(15000),
    });
    const result = await response.json();
    if (!response.ok || result.success !== true) throw new Error(result.error?.code || '请求失败');
    return result.data;
  }
  async function action(work) {
    if (busy) return;
    busy = true;
    document.querySelectorAll('button').forEach((button) => { button.disabled = true; });
    status('正在处理…');
    try { await work(); } catch (error) { status(`操作未完成：${error.message}。发放或重置超时后请先刷新核对，不要连续提交。`); }
    finally {
      busy = false;
      document.querySelectorAll('button').forEach((button) => { button.disabled = false; });
    }
  }
  const base = () => admin ? '/api/admin/hub' : '/api/web/hub';
  async function refresh() {
    const records = await api(`${base()}/keys`);
    el('records').textContent = JSON.stringify(records, null, 2);
  }
  function issued(data) {
    el('key').value = data.key;
    el('issued').hidden = false;
    status(`Key 已生成，权益 ID：${data.licenseId}。明文仅展示本次，请妥善保存。`);
  }
  el('login').addEventListener('submit', (event) => {
    event.preventDefault();
    action(async () => {
      const form = new FormData(event.target);
      const nextAdmin = form.has('admin');
      const password = event.target.elements.password;
      const credentials = { account: form.get('account'), password: password.value };
      password.value = '';
      const result = await api(`/api/${nextAdmin ? 'admin' : 'web'}/auth/login`, 'POST', credentials);
      credentials.password = '';
      token = result.token;
      admin = nextAdmin;
      el('login').hidden = true;
      el('controls').hidden = false;
      el('member').hidden = admin;
      el('issue').hidden = !admin;
      el('revoke').hidden = !admin;
      if (admin) {
        const catalog = await api('/api/hub/catalog');
        const select = el('issue').elements.gameId;
        select.replaceChildren();
        const seen = new Set();
        for (const script of catalog.scripts) {
          if (!script.enabled || seen.has(script.gameId)) continue;
          seen.add(script.gameId);
          const option = document.createElement('option');
          option.value = script.gameId;
          option.textContent = `${script.nameZh} (${script.gameId})`;
          select.append(option);
        }
      }
      await refresh();
      status('已登录');
    });
  });
  el('refresh').addEventListener('click', () => action(async () => { await refresh(); status('记录已刷新'); }));
  for (const [id, reset] of [['claim', false], ['reset', true]]) {
    el(id).addEventListener('click', () => {
      if (reset && !window.confirm('重置将立即终止旧 Key 和会话，确定继续？')) return;
      action(async () => { clearKey(); issued(await api('/api/web/hub/key', 'POST', { reset })); await refresh(); });
    });
  }
  el('issue').addEventListener('submit', (event) => {
    event.preventDefault();
    action(async () => {
      clearKey();
      issued(await api('/api/admin/hub/keys', 'POST', { gameId: event.target.elements.gameId.value }));
      await refresh();
    });
  });
  el('revoke').addEventListener('submit', (event) => {
    event.preventDefault();
    const id = event.target.elements.id.value.trim();
    if (!/^[0-9a-f-]{36}$/i.test(id) || !window.confirm(`确定吊销权益 ${id}？此操作会终止相关会话。`)) return;
    action(async () => { await api(`/api/admin/hub/licenses/${id}/revoke`, 'POST'); clearKey(); await refresh(); status('权益已吊销'); });
  });
  el('copy').addEventListener('click', () => action(async () => { await navigator.clipboard.writeText(el('key').value); status('已复制，请妥善保存'); }));
  el('clear').addEventListener('click', clearKey);
  el('logout').addEventListener('click', () => {
    token = ''; clearKey();
    el('controls').hidden = true; el('login').hidden = false;
    el('records').textContent = '请先登录'; status('已退出本页');
  });
})();
