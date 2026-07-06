// Her Desktop browser bridge — MV3 service worker.
//
// Polls Her's loopback bridge for a command, runs it in the active tab, and
// posts the result back — all inside the user's own Chrome with their real
// profile. Input goes through the Chrome Debugger Protocol (Input.*) so it is
// trusted (isTrusted:true) and works on React rich editors like X's composer;
// reads/screenshots use the standard scripting/tabs APIs. Using the debugger
// shows a "being debugged" banner while Her is driving the tab.
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
    + ' [role=button], [role=link], [role=tab], [role=menuitem], [role=textbox],'
    + ' [role=searchbox], [role=combobox], [onclick], [contenteditable=true]';
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

function isEditable(el) {
  if (!el) return false;
  return el.isContentEditable
    || (el.getAttribute && el.getAttribute('role') === 'textbox')
    || el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
}

function firstVisibleEditable() {
  const nodes = document.querySelectorAll('[contenteditable=true], [role=textbox], textarea, input:not([type=hidden])');
  for (const el of nodes) {
    const r = el.getBoundingClientRect();
    if (r.width > 2 && r.height > 2 && getComputedStyle(el).visibility !== 'hidden') return el;
  }
  return null;
}

function resolveTarget(selector, index, x, y) {
  if (index != null) return document.querySelector('[data-her-idx="' + index + '"]');
  if (selector) return document.querySelector(selector);
  if (x != null && y != null) return document.elementFromPoint(x, y);
  return null;
}

function pageClickFn(selector, index, x, y) {
  const target = resolveTarget(selector, index, x, y);
  if (!target) return { ok: false, error: 'element not found' };
  target.scrollIntoView({ block: 'center' });
  if (x != null && y != null) {
    for (const type of ['mousedown', 'mouseup', 'click']) {
      target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y }));
    }
  } else {
    target.click();
  }
  // Clicking a rich editor doesn't reliably move focus; do it explicitly so
  // a following type lands there.
  if (isEditable(target)) target.focus();
  return { ok: true };
}

function pageTypeFn(selector, index, x, y, text, enter) {
  // Prefer an explicit target; else the focused element; else the first
  // visible editable on the page (handles X's compose box after a click,
  // and stale data-her-idx from React re-renders).
  let target = resolveTarget(selector, index, x, y);
  if (!target && isEditable(document.activeElement)) target = document.activeElement;
  if (!target) target = firstVisibleEditable();
  if (!target) return { ok: false, error: 'no editable field found' };
  target.focus();
  const editable = target.isContentEditable || (target.getAttribute && target.getAttribute('role') === 'textbox');
  if (editable) {
    // React rich editors (Draft/Lexical, e.g. X's compose box) listen for
    // beforeinput/input; execCommand('insertText') dispatches both.
    target.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: 'insertText', data: text }));
    const ok = document.execCommand('insertText', false, text);
    if (!ok) {
      const sel = window.getSelection();
      if (sel && sel.rangeCount) { sel.getRangeAt(0).insertNode(document.createTextNode(text)); }
    }
    target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
  } else if ('value' in target) {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(target), 'value');
    const next = (target.value || '') + text;
    if (setter && setter.set) { setter.set.call(target, next); } else { target.value = next; }
    target.dispatchEvent(new Event('input', { bubbles: true }));
    target.dispatchEvent(new Event('change', { bubbles: true }));
  } else {
    document.execCommand('insertText', false, text);
  }
  if (enter) {
    const opts = { bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13 };
    target.dispatchEvent(new KeyboardEvent('keydown', opts));
    target.dispatchEvent(new KeyboardEvent('keypress', opts));
    target.dispatchEvent(new KeyboardEvent('keyup', opts));
    if (target.form && !editable) { target.form.requestSubmit ? target.form.requestSubmit() : target.form.submit(); }
  }
  return { ok: true };
}

async function runInPage(tabId, func, args) {
  const [res] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return res ? res.result : null;
}

// --- Trusted input via the Chrome Debugger Protocol -------------------------
// Synthetic DOM events (dispatchEvent / execCommand) carry isTrusted:false and
// React rich editors (X's Lexical, Gmail, Notion) ignore them. chrome.debugger
// + Input.* dispatch real browser-level input (isTrusted:true) — identical to a
// human at the keyboard — which every editor accepts. This is the mechanism
// automation extensions use to post to X. It shows a "being debugged" banner.
const cdpTabs = new Set();

async function cdpAttach(tabId) {
  if (cdpTabs.has(tabId)) return true;
  try {
    await chrome.debugger.attach({ tabId }, '1.3');
    cdpTabs.add(tabId);
    return true;
  } catch (e) {
    const msg = String((e && e.message) || e);
    if (msg.includes('already attached')) { cdpTabs.add(tabId); return true; }
    return false; // DevTools open on this tab, or attach not permitted
  }
}

async function cdpSend(tabId, method, params) {
  return chrome.debugger.sendCommand({ tabId }, method, params || {});
}

async function cdpClick(tabId, x, y) {
  await cdpSend(tabId, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none' });
  await cdpSend(tabId, 'Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
  await cdpSend(tabId, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
}

const CDP_KEYS = {
  Enter: { vk: 13, code: 'Enter', key: 'Enter', text: '\r' },
  Tab: { vk: 9, code: 'Tab', key: 'Tab' },
  Escape: { vk: 27, code: 'Escape', key: 'Escape' },
  Backspace: { vk: 8, code: 'Backspace', key: 'Backspace' },
  ArrowDown: { vk: 40, code: 'ArrowDown', key: 'ArrowDown' },
  ArrowUp: { vk: 38, code: 'ArrowUp', key: 'ArrowUp' },
  Space: { vk: 32, code: 'Space', key: ' ', text: ' ' }
};

async function cdpKey(tabId, name) {
  const k = CDP_KEYS[name] || { vk: 0, code: name, key: name };
  const b = { windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk, code: k.code, key: k.key };
  await cdpSend(tabId, 'Input.dispatchKeyEvent', Object.assign({ type: 'keyDown' }, b, k.text ? { text: k.text } : {}));
  await cdpSend(tabId, 'Input.dispatchKeyEvent', Object.assign({ type: 'keyUp' }, b));
}

async function cdpInsertText(tabId, text) {
  await cdpSend(tabId, 'Input.insertText', { text });
}

chrome.debugger.onDetach.addListener((src) => { if (src.tabId != null) cdpTabs.delete(src.tabId); });
chrome.tabs.onRemoved.addListener((tabId) => cdpTabs.delete(tabId));

// Injected: viewport-relative center (CSS px) of a target element, for
// dispatching a trusted click at coordinates.
function elementCenterFn(selector, index) {
  let el = null;
  if (index != null) el = document.querySelector('[data-her-idx="' + index + '"]');
  else if (selector) el = document.querySelector(selector);
  if (!el) {
    const nodes = document.querySelectorAll('[contenteditable=true],[role=textbox],textarea,input:not([type=hidden])');
    for (const n of nodes) { const r = n.getBoundingClientRect(); if (r.width > 2 && r.height > 2) { el = n; break; } }
  }
  if (!el) return null;
  el.scrollIntoView({ block: 'center' });
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

async function targetCenter(tabId, p) {
  if (p.x != null && p.y != null) return { x: p.x, y: p.y };
  return runInPage(tabId, elementCenterFn, [p.selector || null, p.index != null ? p.index : null]);
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
      // Re-tag elements so a data-her-idx from an earlier read still resolves
      // after a React re-render.
      if (p.index != null) await runInPage(tab.id, pageReadFn, []);
      let ok = false, err = null;
      if (await cdpAttach(tab.id)) {
        const c = await targetCenter(tab.id, p);
        if (c) { await cdpClick(tab.id, c.x, c.y); ok = true; }
      }
      if (!ok) {
        const r = await runInPage(tab.id, pageClickFn,
          [p.selector || null, p.index != null ? p.index : null, p.x != null ? p.x : null, p.y != null ? p.y : null]);
        ok = !!(r && r.ok); err = r && r.error;
      }
      await new Promise(res => setTimeout(res, 400));
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok, error: err, ...(read || {}), screenshot: await screenshot() };
    }
    if (command.action === 'type' || command.action === 'key') {
      if (p.index != null) await runInPage(tab.id, pageReadFn, []);
      const isKey = command.action === 'key';
      let ok = false, err = null;
      if (await cdpAttach(tab.id)) {
        // Focus the target with a trusted click, then insert trusted input.
        if (!isKey) {
          const c = await targetCenter(tab.id, p);
          if (c) await cdpClick(tab.id, c.x, c.y);
        }
        if (isKey && p.key) { await cdpKey(tab.id, p.key); ok = true; }
        else if (p.text != null) {
          if (p.text) await cdpInsertText(tab.id, p.text);
          if (p.enter) await cdpKey(tab.id, 'Enter');
          ok = true;
        }
      }
      if (!ok) {
        const r = await runInPage(tab.id, pageTypeFn,
          [p.selector || null, p.index != null ? p.index : null, p.x != null ? p.x : null, p.y != null ? p.y : null,
           p.text || '', !!p.enter || isKey]);
        ok = !!(r && r.ok); err = r && r.error;
      }
      await new Promise(res => setTimeout(res, 500));
      const read = await runInPage(tab.id, pageReadFn, []);
      return { id: command.id, ok, error: err, ...(read || {}), screenshot: await screenshot() };
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
