import Foundation

/// The scripts that read and act on the browser pane's page for an agent. They run with `callAsyncJavaScript` in
/// Ensemble's own content world (`BrowserScripts.worldName`), so the page cannot see or replace them, and every value
/// from the agent (refs, typed text) arrives as an argument, never pasted into the source. There is no tool that runs
/// the agent's own JavaScript.
///
/// Refs (`e1`, `e2`, ...) are handed out by the snapshot and kept in the world's own `window.__ensembleAgent`, holding
/// elements weakly; an element keeps its ref across snapshots while it stays in the page.
public enum BrowserAgentScripts {
    /// Shared helpers, at the top of every script.
    static let prelude = #"""
    const S = window.__ensembleAgent || (window.__ensembleAgent = { next: 1, refs: new Map(), ids: new WeakMap() });
    function visible(el) {
      if (!el || !el.isConnected) { return false; }
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) { return false; }
      const s = getComputedStyle(el);
      return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0;
    }
    function clean(t, n) {
      t = String(t || '').replace(/\s+/g, ' ').trim();
      return t.length > n ? t.slice(0, n - 1) + '…' : t;
    }
    const sensitiveHint = /(passw|passcode|pass-code|\bpin\b|card.?num|cc-?num|cc-?csc|cvc|cvv|csc|security.?code|iban|routing|account.?num|expir|\bssn\b|one.?time|\botp\b)/i;
    function sensitive(el) {
      if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) { return false; }
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (type === 'password') { return true; }
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      if (/(^|\s)(cc-[a-z-]+|current-password|new-password|one-time-code)(\s|$)/.test(ac)) { return true; }
      const hint = [el.name, el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder')].join(' ');
      return sensitiveHint.test(hint);
    }
    function signInPage() {
      return Array.from(document.querySelectorAll('input[type=password], input[autocomplete~="current-password"], input[autocomplete~="one-time-code"]')).some(visible);
    }
    function lookup(ref) {
      const held = S.refs.get(ref);
      const el = held && held.deref();
      return el && el.isConnected ? el : null;
    }
    function labelText(el) {
      const aria = el.getAttribute('aria-label');
      if (aria) { return aria; }
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const t = by.split(/\s+/).map(function (i) { return document.getElementById(i); }).filter(Boolean)
          .map(function (n) { return n.innerText || n.textContent; }).join(' ');
        if (t.trim()) { return t; }
      }
      if (el.labels && el.labels.length) { return Array.from(el.labels).map(function (l) { return l.innerText || l.textContent; }).join(' '); }
      return el.getAttribute('placeholder') || el.getAttribute('alt') || el.getAttribute('title') || '';
    }
    function roleOf(el) {
      const explicit = el.getAttribute('role');
      if (explicit) { return explicit.split(/\s+/)[0].toLowerCase(); }
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') { return el.hasAttribute('href') ? 'link' : null; }
      if (tag === 'button' || tag === 'summary') { return 'button'; }
      if (tag === 'select') { return 'combobox'; }
      if (tag === 'textarea') { return 'textbox'; }
      if (tag === 'input') {
        const t = (el.getAttribute('type') || 'text').toLowerCase();
        if (t === 'hidden') { return null; }
        if (['button', 'submit', 'reset', 'image'].indexOf(t) >= 0) { return 'button'; }
        if (t === 'checkbox' || t === 'radio') { return t; }
        if (t === 'range') { return 'slider'; }
        if (t === 'file') { return 'file'; }
        if (t === 'search') { return 'searchbox'; }
        return 'textbox';
      }
      if (/^h[1-6]$/.test(tag)) { return 'heading'; }
      if (el.isContentEditable && el.hasAttribute('contenteditable')) { return 'textbox'; }
      return null;
    }
    function describe(el) {
      const role = roleOf(el) || el.tagName.toLowerCase();
      const field = role === 'textbox' || role === 'searchbox' || role === 'combobox';
      const name = labelText(el) || (field ? '' : (el.innerText || el.textContent || el.value || ''));
      const shown = clean(name, 60);
      return role + (shown ? ' "' + shown.replace(/"/g, "'") + '"' : '');
    }
    function fileControl(el) {
      if (el instanceof HTMLInputElement && (el.getAttribute('type') || '').toLowerCase() === 'file') { return true; }
      const label = el.closest('label');
      return !!(label && label.control && (label.control.getAttribute('type') || '').toLowerCase() === 'file');
    }
    """#

    /// Arguments: `maxText`, `maxItems`. Returns a JSON string: title, url, text, elements, signIn, truncation flags,
    /// scroll position.
    public static let snapshot = prelude + #"""
    function refFor(el) {
      let id = S.ids.get(el);
      if (!id) { id = 'e' + (S.next++); S.ids.set(el, id); }
      S.refs.set(id, new WeakRef(el));
      return id;
    }
    const acting = ['link', 'button', 'checkbox', 'radio', 'textbox', 'searchbox', 'combobox', 'slider', 'switch', 'tab',
                    'menuitem', 'menuitemcheckbox', 'option', 'file', 'listbox', 'spinbutton', 'treeitem'];
    const lines = [];
    let count = 0, itemsTruncated = false;
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let el = walker.currentNode; el; el = walker.nextNode()) {
      const role = roleOf(el);
      if (!role || (acting.indexOf(role) < 0 && role !== 'heading') || !visible(el)) { continue; }
      if (count >= maxItems) { itemsTruncated = true; break; }
      count++;
      const field = role === 'textbox' || role === 'searchbox' || role === 'combobox';
      const name = role === 'heading' ? (el.innerText || el.textContent)
        : (labelText(el) || (field ? '' : (el.innerText || el.textContent || el.value || '')));
      const shown = clean(name, 80);
      let line = '- ' + role + (shown ? ' "' + shown.replace(/"/g, "'") + '"' : '');
      if (role === 'heading') {
        line += ' (level ' + el.tagName.slice(1) + ')';
      } else {
        line += ' [ref=' + refFor(el) + ']';
        if (sensitive(el)) {
          line += ' (password or payment field: Ensemble does not type here)';
        } else if ((role === 'textbox' || role === 'searchbox') && typeof el.value === 'string' && el.value) {
          line += ' value="' + clean(el.value, 80).replace(/"/g, "'") + '"';
        }
        if (el.disabled) { line += ' (disabled)'; }
        if (role === 'checkbox' || role === 'radio') { line += el.checked ? ' (checked)' : ' (not checked)'; }
        if (role === 'link') {
          const h = el.getAttribute('href') || '';
          if (h && h.indexOf('javascript:') !== 0) { line += ' -> ' + clean(h, 120); }
        }
        if (el instanceof HTMLSelectElement && el.selectedOptions[0]) { line += ' selected="' + clean(el.selectedOptions[0].text, 60) + '"'; }
      }
      lines.push(line);
    }
    let text = ((document.body && document.body.innerText) || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    const textTruncated = text.length > maxText;
    if (textTruncated) { text = text.slice(0, maxText); }
    return JSON.stringify({
      title: document.title || '', url: location.href, text: text, elements: lines.join('\n'), signIn: signInPage(),
      textTruncated: textTruncated, itemsTruncated: itemsTruncated,
      scrollY: Math.round(window.scrollY), height: Math.round(document.documentElement.scrollHeight), viewport: Math.round(window.innerHeight)
    });
    """#

    /// Argument: `ref`. Returns `{"what": "button \"Save\"", "sensitive": bool, "upload": bool}` or `{"error": "stale"}`,
    /// so a card can name the element and refusals need no card.
    public static let describe = prelude + #"""
    const el = lookup(ref);
    if (!el) { return JSON.stringify({ error: 'stale' }); }
    return JSON.stringify({ what: describe(el), sensitive: sensitive(el), upload: fileControl(el) });
    """#

    /// Argument: `ref`. Returns `{"ok": true, "what": ...}` or `{"error": "stale" | "upload" | "sensitive" | "disabled"}`.
    public static let click = prelude + #"""
    const el = lookup(ref);
    if (!el) { return JSON.stringify({ error: 'stale' }); }
    if (fileControl(el)) { return JSON.stringify({ error: 'upload' }); }
    if (sensitive(el)) { return JSON.stringify({ error: 'sensitive' }); }
    if (el.disabled) { return JSON.stringify({ error: 'disabled' }); }
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    const o = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    try { el.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (e) {}
    el.dispatchEvent(new MouseEvent('mousedown', o));
    if (typeof el.focus === 'function') { el.focus({ preventScroll: true }); }
    try { el.dispatchEvent(new PointerEvent('pointerup', o)); } catch (e) {}
    el.dispatchEvent(new MouseEvent('mouseup', o));
    el.click();
    return JSON.stringify({ ok: true, what: el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') });
    """#

    /// Arguments: `ref`, `text`, `submit`. Returns `{"ok": true}` or `{"error": "stale" | "sensitive" | "upload" | "notText" | "disabled"}`.
    public static let type = prelude + #"""
    const el = lookup(ref);
    if (!el) { return JSON.stringify({ error: 'stale' }); }
    if (fileControl(el)) { return JSON.stringify({ error: 'upload' }); }
    if (sensitive(el)) { return JSON.stringify({ error: 'sensitive' }); }
    const isInput = el instanceof HTMLInputElement, isArea = el instanceof HTMLTextAreaElement;
    const kind = isInput ? (el.getAttribute('type') || 'text').toLowerCase() : '';
    if (isInput && ['text', 'search', 'email', 'url', 'tel', 'number'].indexOf(kind) < 0) { return JSON.stringify({ error: 'notText' }); }
    if (!isInput && !isArea && !el.isContentEditable) { return JSON.stringify({ error: 'notText' }); }
    if (el.disabled || el.readOnly) { return JSON.stringify({ error: 'disabled' }); }
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
    el.focus({ preventScroll: true });
    if (isInput || isArea) {
      const proto = isArea ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      el.textContent = text;
      el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
    }
    if (submit) {
      const k = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const go = el.dispatchEvent(new KeyboardEvent('keydown', k));
      el.dispatchEvent(new KeyboardEvent('keypress', k));
      el.dispatchEvent(new KeyboardEvent('keyup', k));
      if (go && el.form) {
        if (typeof el.form.requestSubmit === 'function') { el.form.requestSubmit(); } else { el.form.submit(); }
      }
    }
    return JSON.stringify({ ok: true });
    """#

    /// Arguments: `direction`, `ref` (or null). Returns `{"scrollY", "height", "viewport"}` or `{"error": "stale"}`.
    public static let scroll = prelude + #"""
    if (ref) {
      const el = lookup(ref);
      if (!el) { return JSON.stringify({ error: 'stale' }); }
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
    } else if (direction === 'down') {
      window.scrollBy({ top: window.innerHeight * 0.8, behavior: 'instant' });
    } else if (direction === 'up') {
      window.scrollBy({ top: -window.innerHeight * 0.8, behavior: 'instant' });
    } else if (direction === 'top') {
      window.scrollTo({ top: 0, behavior: 'instant' });
    } else {
      window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'instant' });
    }
    return JSON.stringify({ scrollY: Math.round(window.scrollY), height: Math.round(document.documentElement.scrollHeight),
                            viewport: Math.round(window.innerHeight) });
    """#

    /// No arguments. Returns `true` when a visible password or one-time code field is on the page.
    public static let signIn = prelude + "return signInPage();"

    public static let maxText = 12_000
    public static let maxItems = 300
}
