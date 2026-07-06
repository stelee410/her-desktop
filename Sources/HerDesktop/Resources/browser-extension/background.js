// Her Desktop browser bridge — MV3 service worker.
//
// Polls Her's loopback bridge for a command, runs it in the active tab
// using the standard extension APIs (no debugger banner), and posts the
// result back. Because everything happens inside the user's own Chrome
// with their real profile, there is no automation driver to detect.
//
// The bridge port + token are configured from Her (chrome.storage), or
// fall back to the defaults Her writes into a small config the user pastes
// once. To keep setup trivial, Her serves the port/token via a well-known
// discovery file the user provides through the extension options; for now
// they are read from chrome.storage.local, set by the paste-config step.

const DEFAULT_PORT = 8799;

async function config() {
  const stored = await chrome.storage.local.get(["port", "token"]);
  return {
    port: stored.port || DEFAULT_PORT,
    token: stored.token || ""
  };
}

function base(cfg) {
  return `http://127.0.0.1:${cfg.port}`;
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

// Injected into the page to enumerate interactive elements + read text.
function pageReadFn() {
  const sel = 'a[href], button, input:not([type=hidden]), textarea, select,'
    + ' [role=button], [role=link], [role=tab], [role=menuitem], [onclick], [contenteditable=true]';
  const nodes = Array.from(document.querySelectorAll(sel));
  const elements = [];
  let idx = 0;
  for (const el of nodes) {
    const rect = el.getBoundingClientRect();
    if (rect.width < 3 || rect.height < 3) continue;
    const style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none' || style.opacity === '0') continue;
    el.setAttribute('data-her-idx', String(idx));
    const label = (el.innerText || el.value || el.getAttribute('aria-label')
      || el.getAttribute('placeholder') || el.getAttribute('name')
      || el.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 80);
    elements.push({ index: idx, tag: el.tagName.toLowerCase(), type: el.getAttribute('type') || '', label });
    idx++;
    if (idx >= 120) break;
  }
  const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 40)
    .map(a => ({ t: (a.innerText || '').trim().slice(0, 60), href: a.href }))
    .filter(l => l.t);
  return {
    url: location.href,
    title: document.title,
    text: (document.body ? document.body.innerText : '').slice(0, 8000),
    elements, links
  };
}

function pageClickFn(selector, index) {
  const target = index != null
    ? document.querySelector('[data-her-idx="' + index + '"]')
    : document.querySelector(selector);
  if (!target) return { ok: false, error: 'element not found' };
  target.scrollIntoView({ block: 'center' });
  target.click();
  return { ok: true };
}

function pageTypeFn(selector, index, text, enter) {
  const target = index != null
    ? document.querySelector('[data-her-idx="' + index + '"]')
    : document.querySelector(selector);
  if (!target) return { ok: false, error: 'element not found' };
  target.focus();
  const setter = Object.getOwnPropertyDescriptor(target.__proto__, 'value');
  if (setter && setter.set) { setter.set.call(target, text); } else { target.value = text; }
  target.dispatchEvent(new Event('input', { bubbles: true }));
  target.dispatchEvent(new Event('change', { bubbles: true }));
  if (enter) {
    const opts = { bubbles: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
    target.dispatchEvent(new KeyboardEvent('keydown', opts));
    target.dispatchEvent(new KeyboardEvent('keyup', opts));
    if (target.form) { target.form.requestSubmit ? target.form.requestSubmit() : target.form.submit(); }
  }
  return { ok: true };
}

async function runInPage(tabId, func, args) {
  const [res] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return res ? res.result : null;
}

async function screenshot() {
  try {
    return await chrome.tabs.captureVisibleTab({ format: 'png' });
  } catch (e) {
    return null;
  }
}

async function execute(command) {
  const tab = await activeTab();
  if (!tab) return { id: command.id, ok: false, error: 'no active tab' };
  const p = command.params || {};
  try {
    if (command.action === 'navigate') {
      let url = p.url || '';
      if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url)) url = 'https://' + url;
      await chrome.tabs.update(tab.id, { url });
      await new Promise(r => setTimeout(r, 1500));
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok: true, ...(read || {}), screenshot: await screenshot() };
    }
    if (command.action === 'read') {
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok: true, ...(read || {}) };
    }
    if (command.action === 'screenshot') {
      return { id: command.id, ok: true, screenshot: await screenshot() };
    }
    if (command.action === 'click') {
      const r = await runInPage(tab.id, pageClickFn, [p.selector || null, p.index != null ? p.index : null]);
      await new Promise(res => setTimeout(res, 400));
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok: r && r.ok, error: r && r.error, ...(read || {}), screenshot: await screenshot() };
    }
    if (command.action === 'type' || command.action === 'key') {
      const r = await runInPage(tab.id, pageTypeFn,
        [p.selector || null, p.index != null ? p.index : null, p.text || '', !!p.enter || command.action === 'key']);
      await new Promise(res => setTimeout(res, 500));
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok: r && r.ok, error: r && r.error, ...(read || {}), screenshot: await screenshot() };
    }
    return { id: command.id, ok: false, error: 'unknown action ' + command.action };
  } catch (e) {
    return { id: command.id, ok: false, error: String(e) };
  }
}

async function poll() {
  const cfg = await config();
  if (!cfg.token) return;
  try {
    const res = await fetch(`${base(cfg)}/ext/next?token=${encodeURIComponent(cfg.token)}`);
    const data = await res.json();
    if (data && data.command) {
      const result = await execute(data.command);
      await fetch(`${base(cfg)}/ext/result?token=${encodeURIComponent(cfg.token)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(result)
      });
    }
  } catch (e) {
    // Her not running or no command; ignore and retry.
  }
}

// MV3 service workers sleep; a chrome.alarms tick keeps polling alive.
chrome.alarms.create('poll', { periodInMinutes: 0.05 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'poll') poll(); });
setInterval(poll, 800);
poll();
