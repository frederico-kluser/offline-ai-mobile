/// Ponte JS injetada na WebView (`window.__oai`) — a "mão" que executa as
/// ações do [BrowserAction] dentro da página.
///
/// Técnicas (dossiês 04-camada-js-acoes.md e 02-cdp-e-controlo.md):
///  - refs estáveis `data-oai-ref` atribuídas lazy por elemento interativo;
///  - `docId` por documento + `refEpoch` (MutationObserver) para NUNCA agir
///    sobre um DOM desatualizado (erro `stale-doc`/`stale-ref`);
///  - `ping()` para verificar instalação (Android não garante
///    AT_DOCUMENT_START em WebViews antigas — reinjetar e confirmar);
///  - clique = sequência pointerdown/mousedown/pointerup/mouseup/click +
///    `el.click()` para a default action (links, botões de submit);
///  - native value setter + `input`/`change` para inputs controlados por
///    React/Vue/Angular; `form.requestSubmit()` para submeter;
///  - coordenadas normalizadas 0..1 via `elementFromPoint`.
///
/// Limites assumidos (teste simples): iframes cross-origin, shadow DOM
/// fechado e canvas/WebGL não são acionáveis — reportados como erro explícito.
/// Eventos sintéticos são sempre `isTrusted:false` (inforjável): páginas com
/// anti-bot podem ignorá-los — mitigação futura é CDP/adb em dev.
library;

/// Versão do contrato da ponte (bump ao mudar o formato).
const String kBrowserBridgeVersion = '1';

/// Fonte da ponte. String raw única para injetar como UserScript
/// (`AT_DOCUMENT_START`) e reinjetar em `onLoadStop`.
const String kBrowserBridgeJs = r'''
(function () {
  if (window.__oai && window.__oai.version === 1) { return; }
  var MAX_ELEMENTS = 60;
  var MAX_TEXT = 4000;
  var MAX_NAME = 80;
  var SELECTOR = 'a[href], button, input, select, textarea, summary, ' +
    '[onclick], [role="button"], [role="link"], [role="textbox"], ' +
    '[role="checkbox"], [role="radio"], [role="menuitem"], [role="tab"], ' +
    '[contenteditable="true"]';

  var docId = 'd' + Date.now().toString(36) + Math.floor(
    Math.random() * 1e6).toString(36);
  var refEpoch = 0;
  var epochTimer = null;
  try {
    var mo = new MutationObserver(function () {
      if (epochTimer) { clearTimeout(epochTimer); }
      epochTimer = setTimeout(function () { refEpoch++; }, 150);
    });
    mo.observe(document.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['class', 'hidden', 'style']
    });
  } catch (e) {}

  function isVisible(el) {
    if (!el || el.disabled) { return false; }
    if (el.getAttribute('aria-hidden') === 'true') { return false; }
    var r = el.getBoundingClientRect();
    if (r.width <= 1 || r.height <= 1) { return false; }
    var st = window.getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none') { return false; }
    if (parseFloat(st.opacity || '1') < 0.1) { return false; }
    return true;
  }

  function nextRef(el) {
    var ex = el.getAttribute('data-oai-ref');
    if (ex) { return ex; }
    var d = document.documentElement;
    var n = parseInt(d.getAttribute('data-oai-counter') || '0', 10) + 1;
    d.setAttribute('data-oai-counter', String(n));
    var ref = 'e' + n;
    el.setAttribute('data-oai-ref', ref);
    return ref;
  }

  function byRef(ref) {
    if (!ref) { return document.activeElement; }
    try {
      return document.querySelector('[data-oai-ref="' + ref + '"]');
    } catch (e) { return null; }
  }

  function accessibleName(el) {
    var al = el.getAttribute('aria-label');
    if (al) { return al.trim(); }
    var lb = el.getAttribute('aria-labelledby');
    if (lb) {
      var t = document.getElementById(lb);
      if (t) { return (t.textContent || '').trim(); }
    }
    if (el.labels && el.labels.length) {
      return (el.labels[0].textContent || '').trim();
    }
    var ph = el.getAttribute('placeholder');
    if (ph) { return ph.trim(); }
    var ti = el.getAttribute('title');
    if (ti) { return ti.trim(); }
    var txt = (el.innerText || el.textContent || '').trim();
    if (!txt && el.tagName === 'BUTTON' && el.value) { txt = String(el.value); }
    return txt;
  }

  function pageText() {
    var root = document.querySelector('main, article, [role="main"]') || document.body;
    if (!root) { return ''; }
    return (root.innerText || root.textContent || '')
      .replace(/\s+/g, ' ').trim();
  }

  function snapshot() {
    var nodes = document.querySelectorAll(SELECTOR);
    var els = [];
    var overflow = false;
    for (var i = 0; i < nodes.length; i++) {
      if (els.length >= MAX_ELEMENTS) { overflow = true; break; }
      var el = nodes[i];
      if (!isVisible(el)) { continue; }
      var r = el.getBoundingClientRect();
      var name = (accessibleName(el) || '').replace(/\s+/g, ' ')
        .slice(0, MAX_NAME);
      var value = null;
      if (el.value !== undefined && el.value !== null && el.value !== '') {
        // Senhas NUNCA saem em claro (contrato view.js do anonymous-browser).
        value = (el.type === 'password')
          ? '•••' : String(el.value).slice(0, MAX_NAME);
      }
      els.push({
        ref: nextRef(el),
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        name: name,
        value: value,
        input_type: el.type ? String(el.type) : null,
        x: +(r.left / window.innerWidth).toFixed(3),
        y: +(r.top / window.innerHeight).toFixed(3),
        w: +(r.width / window.innerWidth).toFixed(3),
        h: +(r.height / window.innerHeight).toFixed(3)
      });
    }
    var text = pageText();
    var textTruncated = text.length > MAX_TEXT;
    if (textTruncated) { text = text.slice(0, MAX_TEXT); }
    return {
      v: 1,
      doc_id: docId,
      ref_epoch: refEpoch,
      url: location.href,
      title: document.title || '',
      text: text,
      elements: els,
      truncated: overflow || textTruncated,
      captured_at_ms: Date.now()
    };
  }

  function ok(output, withSnapshot) {
    var r = { status: 'ok', output: output, doc_id: docId,
      ref_epoch: refEpoch };
    if (withSnapshot) { r.snapshot = snapshot(); }
    return r;
  }

  function noResults(output) {
    return { status: 'no_results', output: output, doc_id: docId,
      ref_epoch: refEpoch };
  }

  function err(kind, output) {
    return { status: 'error', error_kind: kind, output: output,
      doc_id: docId, ref_epoch: refEpoch };
  }

  function fire(el, type, Ctor) {
    var Ev = Ctor || Event;
    try {
      el.dispatchEvent(new Ev(type, {
        bubbles: true, cancelable: true, composed: true, view: window
      }));
    } catch (e) {
      try { el.dispatchEvent(new Event(type, { bubbles: true })); } catch (e2) {}
    }
  }

  function clickSequence(el) {
    var seq = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
    for (var i = 0; i < seq.length; i++) {
      var t = seq[i];
      var Ctor = (t.indexOf('pointer') === 0 && window.PointerEvent)
        ? PointerEvent : ((t === 'click' || t.indexOf('mouse') === 0)
          ? MouseEvent : Event);
      fire(el, t, Ctor);
    }
  }

  function activate(el) {
    try { el.focus(); } catch (e) {}
    if (typeof el.click === 'function') { el.click(); }
    else { clickSequence(el); }
  }

  function setNativeValue(el, value) {
    var proto = (el instanceof HTMLTextAreaElement)
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) { desc.set.call(el, value); }
    else { el.value = value; }
    fire(el, 'input', Event);
    fire(el, 'change', Event);
  }

  function submitForm(el) {
    var form = el && el.form ? el.form
      : (el && el.tagName === 'FORM' ? el : null);
    if (form) {
      if (typeof form.requestSubmit === 'function') {
        try { form.requestSubmit(); return true; } catch (e) {}
      }
      try {
        if (form.dispatchEvent(new Event('submit',
          { bubbles: true, cancelable: true }))) { form.submit(); }
        return true;
      } catch (e) {}
    }
    if (el && typeof el.click === 'function') {
      var near = el.closest('button, input[type="submit"], [role="button"]');
      if (near) { near.click(); return true; }
    }
    return false;
  }

  function tapRef(ref) {
    var el = byRef(ref);
    if (!el || el === document.body) {
      return err('ref-not-found',
        'elemento "' + ref + '" não existe nesta página (faz snapshot)');
    }
    if (!isVisible(el)) {
      try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
    }
    activate(el);
    return ok('clicado em ' + ref + ' (' + el.tagName.toLowerCase() + ')', true);
  }

  function tapAt(nx, ny) {
    var x = Math.max(0, Math.min(1, +nx)) * window.innerWidth;
    var y = Math.max(0, Math.min(1, +ny)) * window.innerHeight;
    var el = document.elementFromPoint(x, y);
    if (!el) {
      return err('point-empty', 'sem elemento em (' + nx + ',' + ny + ')');
    }
    var target = el.closest(
      'a, button, input, select, textarea, summary, [onclick], [role="button"], [role="link"]');
    if (!target) { target = el; }
    var ref = nextRef(target);
    activate(target);
    return ok('clicado em (' + nx + ',' + ny + ') → ' + ref + ' (' +
      target.tagName.toLowerCase() + ')', true);
  }

  function typeText(ref, text, submit) {
    var el = byRef(ref);
    if (!el || el === document.body) {
      return err('ref-not-found',
        'campo "' + ref + '" não existe nesta página (faz snapshot)');
    }
    var tag = el.tagName.toLowerCase();
    try { el.focus(); } catch (e) {}
    if (el.isContentEditable) {
      try {
        document.execCommand('insertText', false, text);
      } catch (e) {
        el.textContent = (el.textContent || '') + text;
        fire(el, 'input', Event);
      }
    } else if (tag === 'select') {
      return selectOption(ref, text);
    } else if (tag === 'input' || tag === 'textarea') {
      setNativeValue(el, text);
    } else {
      return err('not-editable',
        tag + ' não aceita texto (escolhe um input/textarea)');
    }
    var out = 'escrito em ' + ref;
    if (submit) {
      out += submitForm(el) ? ' e submetido' : ' (submit falhou)';
    }
    return ok(out, true);
  }

  function selectOption(ref, value) {
    var el = byRef(ref);
    if (!el || el.tagName.toLowerCase() !== 'select') {
      return err('ref-not-found', '"' + ref + '" não é um select');
    }
    var matched = null;
    for (var i = 0; i < el.options.length; i++) {
      var o = el.options[i];
      if (o.value === value || (o.textContent || '').trim() === value) {
        matched = o.value; break;
      }
    }
    if (matched === null) {
      return noResults('sem opção "' + value + '" em ' + ref +
        ' (opções: ' + Array.prototype.map.call(el.options,
          function (o) { return o.value; }).join(', ') + ')');
    }
    el.value = matched;
    fire(el, 'change', Event);
    return ok('selecionado "' + matched + '" em ' + ref, true);
  }

  function scrollPage(dx, dy) {
    var w = window.innerWidth, h = window.innerHeight;
    var before = window.scrollY;
    window.scrollBy((+dx) * w, (+dy) * h);
    var moved = Math.abs(window.scrollY - before);
    if (moved < 1 && (+dy) !== 0) {
      return noResults('sem espaço para rolar (fim da página?)');
    }
    return ok('rolado (' + dx + ',' + dy + ')', true);
  }

  function act(cmd) {
    var a;
    if (typeof cmd === 'string') {
      try { a = JSON.parse(cmd); }
      catch (e) { return err('bad-payload', 'JSON de ação inválido'); }
    } else { a = cmd || {}; }
    if (a.doc_id && a.doc_id !== docId) {
      return err('stale-doc',
        'a ação pertence a outro documento (DOM mudou) — refaz snapshot');
    }
    if (a.ref_epoch !== undefined && a.ref_epoch !== null &&
        (+a.ref_epoch) < refEpoch) {
      var w = err('stale-ref',
        'o DOM mudou desde o snapshot (epoch ' + a.ref_epoch + ' < ' +
        refEpoch + ') — refaz snapshot se a ref falhar');
      w.warning = true;
    }
    var k = a.kind;
    var out;
    if (k === 'tap') { out = tapRef(a.ref); }
    else if (k === 'tap_at') { out = tapAt(a.x, a.y); }
    else if (k === 'type') { out = typeText(a.ref, String(a.text || ''), !!a.submit); }
    else if (k === 'scroll') { out = scrollPage(a.dx || 0, a.dy || 0); }
    else if (k === 'select') { out = selectOption(a.ref, String(a.value || '')); }
    else if (k === 'snapshot') {
      out = ok('snapshot ok', true);
    }
    else if (k === 'extract') {
      var text = pageText();
      out = text ? ok(text.slice(0, 12000), true)
        : noResults('[no_results] página sem texto principal visível');
    }
    else { out = err('unknown-kind', 'ação desconhecida: ' + k); }
    if (typeof out === 'string') { return JSON.parse(out); }
    return out;
  }

  window.__oai = {
    version: 1,
    ping: function () {
      return { version: 1, doc_id: docId, ref_epoch: refEpoch,
        url: location.href };
    },
    snapshot: function () { return JSON.stringify(snapshot()); },
    act: function (cmd) { return JSON.stringify(act(cmd)); }
  };
})();
''';