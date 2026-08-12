// ==UserScript==
// @name         Google Chat message renderer (Leandro)
// @namespace    leandro
// @version      3.0.0
// @description  Rich rendering for Google Chat: markdown tables, syntax-highlighted code blocks with copy button, styled inline code. Dark/light theme aware.
// @match        https://chat.google.com/*
// @match        https://mail.google.com/chat/*
// @match        https://mail.google.com/mail/*
// @require      https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js
// @grant        GM_setClipboard
// @run-at       document-idle
// ==/UserScript==

'use strict';

// ─────────────────────────────────────────────────────────────────────────────
// Pure parsing core — token model shared by the DOM layer and the node
// self-check. A token is one of:
//   {text: string}          plain text fragment
//   {node: Element}         atomic inline element (bold span, link, code span)
//   {block: Element}        atomic monospace block (Chat's fenced code block)
//   {nl: true}              line break
// ─────────────────────────────────────────────────────────────────────────────

const NL = { nl: true };
const ROW = /^\s*\|.*\|\s*$/;
const SEP = /^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$/;

function tokenText(tok) {
  if (tok.text !== undefined) return tok.text;
  if (tok.node) return nodeText(tok.node);
  return ''; // blocks and newlines contribute nothing to line text
}

// Chat keeps raw markdown markers in the DOM as hidden spans
// (<span data-cd="hidden">*</span>) and renders emoji as <img data-emoji="✅">.
// Markers must not leak into parsed text; emoji must contribute their glyph
// (status detection depends on it).
function nodeText(n) {
  if (n.getAttribute) {
    if (n.getAttribute('data-cd') === 'hidden') return '';
    const emoji = n.getAttribute('data-emoji') || (n.tagName === 'IMG' && n.alt);
    if (emoji) return emoji;
  }
  return n.textContent || '';
}

function groupLines(tokens) {
  const lines = [[]];
  for (const tok of tokens) {
    if (tok.nl) lines.push([]);
    else lines[lines.length - 1].push(tok);
  }
  return lines;
}

function lineText(line) {
  return line.map(tokenText).join('');
}

// Split one table row (token line) into cells, keeping inline element tokens
// attached to the cell they appear in. Pipes only ever live in text tokens.
function splitCells(line) {
  const cells = [[]];
  for (const tok of line) {
    if (tok.text !== undefined) {
      const parts = tok.text.split('|');
      parts.forEach((p, i) => {
        if (i) cells.push([]);
        if (p) cells[cells.length - 1].push({ text: p });
      });
    } else {
      cells[cells.length - 1].push(tok);
    }
  }
  const isEmpty = (cell) =>
    cell.every((t) => t.text !== undefined) && lineText(cell).trim() === '';
  if (cells.length && isEmpty(cells[0])) cells.shift();
  if (cells.length && isEmpty(cells[cells.length - 1])) cells.pop();
  return cells.map(trimCell);
}

function trimCell(cell) {
  const out = cell.slice();
  if (out.length && out[0].text !== undefined)
    out[0] = { text: out[0].text.replace(/^\s+/, '') };
  const last = out.length - 1;
  if (out.length && out[last].text !== undefined)
    out[last] = { text: out[last].text.replace(/\s+$/, '') };
  return out.filter((t) => t.text === undefined || t.text !== '');
}

// Split token lines into alternating segments:
//   {type: 'text', lines}  |  {type: 'table', header, rows}   (cells = token[][])
function parseSegments(lines) {
  const segments = [];
  let buf = [];
  const flush = () => {
    if (buf.length) segments.push({ type: 'text', lines: buf });
    buf = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const t = lineText(lines[i]);
    const next = i + 1 < lines.length ? lineText(lines[i + 1]) : '';
    if (ROW.test(t) && SEP.test(next)) {
      flush();
      const header = splitCells(lines[i]);
      const rows = [];
      i += 2;
      while (i < lines.length) {
        const rt = lineText(lines[i]);
        if (!ROW.test(rt) || SEP.test(rt)) break;
        rows.push(splitCells(lines[i]));
        i++;
      }
      i--;
      segments.push({ type: 'table', header, rows });
    } else {
      buf.push(lines[i]);
    }
  }
  flush();
  return segments;
}

// ─────────────────────────────────────────────────────────────────────────────
// Browser side
// ─────────────────────────────────────────────────────────────────────────────
if (typeof document !== 'undefined' && typeof window !== 'undefined') {
  const CSS = `
:root.lgc-dark {
  --lgc-border: rgba(255,255,255,.16);
  --lgc-border-soft: rgba(255,255,255,.09);
  --lgc-th-bg: rgba(255,255,255,.07);
  --lgc-zebra: rgba(255,255,255,.03);
  --lgc-hover: rgba(255,255,255,.07);
  --lgc-code-bg: #0d1117;
  --lgc-code-head: rgba(255,255,255,.045);
  --lgc-dim: #9aa4ae;
  --lgc-inline-bg: rgba(255,255,255,.09);
  --lgc-shadow: 0 1px 3px rgba(0,0,0,.35);
}
:root.lgc-light {
  --lgc-border: rgba(0,0,0,.16);
  --lgc-border-soft: rgba(0,0,0,.08);
  --lgc-th-bg: rgba(0,0,0,.045);
  --lgc-zebra: rgba(0,0,0,.02);
  --lgc-hover: rgba(0,0,0,.05);
  --lgc-code-bg: #f6f8fa;
  --lgc-code-head: rgba(0,0,0,.03);
  --lgc-dim: #57606a;
  --lgc-inline-bg: rgba(0,0,0,.055);
  --lgc-shadow: 0 1px 2px rgba(0,0,0,.12);
}
.lgc-root { line-height: 1.5; }
.lgc-prose { white-space: pre-wrap; }
/* Cloned Chat emoji <img> can lose Chat's scoped sizing inside .lgc-root */
.lgc-root img[data-emoji] { height: 1.2em; width: auto; vertical-align: -0.2em; }

.lgc-tblwrap {
  overflow-x: auto; max-width: 100%;
  border: 1px solid var(--lgc-border); border-radius: 10px;
  margin: 8px 0; box-shadow: var(--lgc-shadow);
}
.lgc-tbl { border-collapse: separate; border-spacing: 0; font-size: .93em; width: 100%; }
.lgc-tbl th {
  background: var(--lgc-th-bg); font-weight: 600; text-align: left;
  padding: 8px 12px; white-space: nowrap;
  border-bottom: 2px solid var(--lgc-border);
}
.lgc-tbl td {
  padding: 8px 12px; vertical-align: top; line-height: 1.45;
  border-bottom: 1px solid var(--lgc-border-soft);
}
.lgc-tbl tbody tr:last-child td { border-bottom: none; }
.lgc-tbl tbody tr:nth-child(even) { background: var(--lgc-zebra); }
.lgc-tbl tbody tr:hover { background: var(--lgc-hover); }

.lgc-code {
  border: 1px solid var(--lgc-border); border-radius: 10px;
  margin: 8px 0; overflow: hidden;
  background: var(--lgc-code-bg); box-shadow: var(--lgc-shadow);
}
.lgc-code-head {
  display: flex; justify-content: space-between; align-items: center;
  padding: 4px 6px 4px 12px;
  background: var(--lgc-code-head);
  border-bottom: 1px solid var(--lgc-border-soft);
}
.lgc-code-lang {
  font: 500 11px/1.6 system-ui, sans-serif;
  color: var(--lgc-dim); letter-spacing: .4px; text-transform: lowercase;
}
.lgc-copy {
  font: 500 11px/1.6 system-ui, sans-serif;
  color: var(--lgc-dim); background: none; border: 1px solid transparent;
  border-radius: 6px; padding: 2px 8px; cursor: pointer; opacity: 0;
  transition: opacity .15s, border-color .15s;
}
.lgc-code:hover .lgc-copy { opacity: 1; }
.lgc-copy:hover { border-color: var(--lgc-border); }
.lgc-code pre { margin: 0; padding: 10px 14px; overflow-x: auto; }
.lgc-code code {
  font-family: 'Roboto Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12.5px; line-height: 1.55; white-space: pre; background: none;
}

.lgc-inline {
  background: var(--lgc-inline-bg);
  border: 1px solid var(--lgc-border-soft);
  border-radius: 5px; padding: 0 4px;
  white-space: nowrap; /* never break a flag/name mid-token */
}

/* Syntax palette — GitHub-flavored, both themes */
:root.lgc-dark .lgc-code .hljs-keyword { color: #ff7b72; }
:root.lgc-dark .lgc-code .hljs-string { color: #a5d6ff; }
:root.lgc-dark .lgc-code .hljs-number,
:root.lgc-dark .lgc-code .hljs-literal,
:root.lgc-dark .lgc-code .hljs-symbol,
:root.lgc-dark .lgc-code .hljs-bullet,
:root.lgc-dark .lgc-code .hljs-meta { color: #79c0ff; }
:root.lgc-dark .lgc-code .hljs-comment { color: #8b949e; font-style: italic; }
:root.lgc-dark .lgc-code .hljs-attr,
:root.lgc-dark .lgc-code .hljs-attribute,
:root.lgc-dark .lgc-code .hljs-tag,
:root.lgc-dark .lgc-code .hljs-name,
:root.lgc-dark .lgc-code .hljs-addition { color: #7ee787; }
:root.lgc-dark .lgc-code .hljs-built_in,
:root.lgc-dark .lgc-code .hljs-variable,
:root.lgc-dark .lgc-code .hljs-type { color: #ffa657; }
:root.lgc-dark .lgc-code .hljs-title,
:root.lgc-dark .lgc-code .hljs-function { color: #d2a8ff; }
:root.lgc-dark .lgc-code .hljs-deletion { color: #ffa198; }
:root.lgc-dark .lgc-code .hljs-section { font-weight: 700; }

:root.lgc-light .lgc-code .hljs-keyword { color: #cf222e; }
:root.lgc-light .lgc-code .hljs-string { color: #0a3069; }
:root.lgc-light .lgc-code .hljs-number,
:root.lgc-light .lgc-code .hljs-literal,
:root.lgc-light .lgc-code .hljs-symbol,
:root.lgc-light .lgc-code .hljs-bullet,
:root.lgc-light .lgc-code .hljs-meta { color: #0550ae; }
:root.lgc-light .lgc-code .hljs-comment { color: #6e7781; font-style: italic; }
:root.lgc-light .lgc-code .hljs-attr,
:root.lgc-light .lgc-code .hljs-attribute,
:root.lgc-light .lgc-code .hljs-tag,
:root.lgc-light .lgc-code .hljs-name,
:root.lgc-light .lgc-code .hljs-addition { color: #116329; }
:root.lgc-light .lgc-code .hljs-built_in,
:root.lgc-light .lgc-code .hljs-variable,
:root.lgc-light .lgc-code .hljs-type { color: #953800; }
:root.lgc-light .lgc-code .hljs-title,
:root.lgc-light .lgc-code .hljs-function { color: #8250df; }
:root.lgc-light .lgc-code .hljs-deletion { color: #82071e; }
:root.lgc-light .lgc-code .hljs-section { font-weight: 700; }
`;

  const style = document.createElement('style');
  style.textContent = CSS;
  document.head.appendChild(style);

  // ── Theme detection ────────────────────────────────────────────────────────
  function applyTheme() {
    let bg = getComputedStyle(document.body).backgroundColor;
    if (!bg || bg === 'transparent' || /rgba\(.*,\s*0\)/.test(bg))
      bg = getComputedStyle(document.documentElement).backgroundColor;
    const m = bg && bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
    let dark = false;
    if (m) {
      const lum = (0.2126 * +m[1] + 0.7152 * +m[2] + 0.0722 * +m[3]) / 255;
      dark = lum < 0.5;
    }
    document.documentElement.classList.toggle('lgc-dark', dark);
    document.documentElement.classList.toggle('lgc-light', !dark);
  }

  // ── Monospace detection (cached per scan) ──────────────────────────────────
  const MONO = /mono|courier|consolas|menlo/i;
  function makeMonoCache() {
    const cache = new Map();
    return function isMono(el) {
      if (!el || el.nodeType !== 1) return false;
      let v = cache.get(el);
      if (v === undefined) {
        v = MONO.test(getComputedStyle(el).fontFamily);
        cache.set(el, v);
      }
      return v;
    };
  }

  // ── DOM → tokens ───────────────────────────────────────────────────────────
  // Clone a source node for our rendered output: drop Chat's hidden markdown
  // marker spans entirely (their hiding CSS is scoped to Chat's own message
  // container and stops applying inside .lgc-root), and strip our processing
  // markers. `unhide` is for code blocks we hid and re-render inside cards.
  function cleanClone(src, unhide = false) {
    if (src.nodeType === 1 && src.getAttribute('data-cd') === 'hidden') return null;
    const clone = src.cloneNode(true);
    if (clone.nodeType !== 1) return clone;
    clone.removeAttribute('data-lgc-done');
    for (const el of clone.querySelectorAll('[data-lgc-done]'))
      el.removeAttribute('data-lgc-done');
    for (const el of clone.querySelectorAll('[data-cd="hidden"]')) el.remove();
    if (unhide && clone.style.display === 'none') clone.style.display = '';
    return clone;
  }

  function flatten(el, out, isMono) {
    for (const child of el.childNodes) {
      if (child.nodeType === 3) {
        const parts = child.data.split('\n');
        parts.forEach((p, i) => {
          if (i) out.push(NL);
          if (p) out.push({ text: p });
        });
      } else if (child.nodeType === 1) {
        if (child.classList.contains('lgc-code') || child.classList.contains('lgc-root'))
          continue; // our own output — the hidden source element is kept instead
        if (child.tagName === 'BR') { out.push(NL); continue; }
        const multiline = child.textContent.includes('\n');
        if (multiline && isMono(child)) {
          // Chat's fenced code block: atomic, own line, re-enhanced after clone
          out.push(NL, { block: child }, NL);
          continue;
        }
        if (multiline) { flatten(child, out, isMono); continue; }
        out.push({ node: child });
      }
    }
  }

  // ── Tokens → DOM ───────────────────────────────────────────────────────────
  function tokensToFragment(tokens) {
    const frag = document.createDocumentFragment();
    for (const tok of tokens) {
      if (tok.text !== undefined) {
        frag.appendChild(document.createTextNode(tok.text));
      } else {
        const src = tok.node || tok.block;
        const clone = cleanClone(src, Boolean(tok.block));
        if (clone) frag.appendChild(clone);
      }
    }
    return frag;
  }

  function buildProse(lines) {
    const div = document.createElement('div');
    div.className = 'lgc-prose';
    lines.forEach((line, i) => {
      if (i) div.appendChild(document.createTextNode('\n'));
      div.appendChild(tokensToFragment(line));
    });
    return div;
  }

  function buildTable(seg) {
    const wrap = document.createElement('div');
    wrap.className = 'lgc-tblwrap';
    const table = document.createElement('table');
    table.className = 'lgc-tbl';
    const cols = seg.header.length;

    const thead = document.createElement('thead');
    const htr = document.createElement('tr');
    for (const cell of seg.header) {
      const th = document.createElement('th');
      th.appendChild(tokensToFragment(cell));
      htr.appendChild(th);
    }
    thead.appendChild(htr);
    table.appendChild(thead);

    const tbody = document.createElement('tbody');
    for (const row of seg.rows) {
      const tr = document.createElement('tr');
      for (let c = 0; c < Math.max(cols, row.length); c++) {
        const td = document.createElement('td');
        if (row[c]) td.appendChild(tokensToFragment(row[c]));
        tr.appendChild(td);
      }
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    wrap.appendChild(table);
    return wrap;
  }

  function renderMessage(el, isMono) {
    const tokens = [];
    flatten(el, tokens, isMono);
    const segments = parseSegments(groupLines(tokens));
    if (!segments.some((s) => s.type === 'table')) return;
    const root = document.createElement('div');
    root.className = 'lgc-root';
    for (const seg of segments) {
      if (seg.type === 'table') root.appendChild(buildTable(seg));
      else root.appendChild(buildProse(seg.lines));
    }
    el.dataset.lgcDone = '1';
    el.style.display = 'none';
    el.after(root);
  }

  // ── Code block enhancement ─────────────────────────────────────────────────
  const HLJS_LANGS = ['bash', 'shell', 'yaml', 'json', 'python', 'go',
    'javascript', 'typescript', 'sql', 'diff', 'ini', 'xml', 'plaintext'];

  function guessLang(text) {
    if (/^\s*[{[]/.test(text) && /[}\]]\s*$/.test(text)) return 'json';
    if (/^(apiVersion|kind|metadata):/m.test(text)) return 'yaml';
    if (/^\$ |^(kubectl|helm|git|curl|ssh|docker|k9s|nix) /m.test(text)) return 'bash';
    if (/^(--- |\+\+\+ |@@ )/m.test(text)) return 'diff';
    return null;
  }

  function copyText(text, btn) {
    try {
      if (typeof GM_setClipboard === 'function') GM_setClipboard(text);
      else navigator.clipboard.writeText(text);
      btn.textContent = 'copié ✓';
    } catch (e) {
      btn.textContent = 'erreur';
    }
    setTimeout(() => { btn.textContent = 'copier'; }, 1600);
  }

  function enhanceCodeBlock(el) {
    const raw = el.innerText.replace(/\n$/, '');
    if (!raw.trim()) return;

    let html = null;
    let lang = 'text';
    const hljs = window.hljs;
    if (hljs) {
      try {
        const guessed = guessLang(raw);
        if (guessed) {
          html = hljs.highlight(raw, { language: guessed }).value;
          lang = guessed;
        } else {
          const auto = hljs.highlightAuto(raw, HLJS_LANGS);
          if (auto.language && auto.relevance >= 5) {
            html = auto.value;
            lang = auto.language;
          }
        }
      } catch (e) { /* fall through to plain rendering */ }
    }

    const box = document.createElement('div');
    box.className = 'lgc-code';

    const head = document.createElement('div');
    head.className = 'lgc-code-head';
    const label = document.createElement('span');
    label.className = 'lgc-code-lang';
    label.textContent = lang;
    const btn = document.createElement('button');
    btn.className = 'lgc-copy';
    btn.type = 'button';
    btn.textContent = 'copier';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      copyText(raw, btn);
    });
    head.append(label, btn);

    const pre = document.createElement('pre');
    const code = document.createElement('code');
    if (html !== null) code.innerHTML = html;
    else code.textContent = raw;
    pre.appendChild(code);

    box.append(head, pre);
    el.dataset.lgcDone = '1';
    el.style.display = 'none';
    el.after(box);
  }

  // ── Scanning ───────────────────────────────────────────────────────────────
  function scanCode(isMono) {
    // Computed-style probe over div/span/pre/code candidates each scan;
    // Chat virtualizes its DOM so the candidate set stays small.
    const candidates = document.body.querySelectorAll('div, pre, code, span');
    for (const el of candidates) {
      if (el.dataset.lgcDone) continue;
      if (el.closest('.lgc-code, [contenteditable="true"]')) continue;
      if (!isMono(el)) continue;
      if (isMono(el.parentElement)) continue; // outermost monospace element wins
      const display = getComputedStyle(el).display;
      const multiline = el.textContent.includes('\n');
      if (display !== 'inline' && (multiline || el.textContent.length > 40)) {
        enhanceCodeBlock(el);
      } else if (display === 'inline' && !multiline) {
        el.classList.add('lgc-inline');
        el.dataset.lgcDone = '1';
      }
    }
  }

  function scanTables(isMono) {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const targets = new Set();
    let node;
    while ((node = walker.nextNode())) {
      if (!/\|[\s:|-]*-{3,}/.test(node.data)) continue;
      let el = node.parentElement;
      if (!el || el.closest('.lgc-root, .lgc-code, [contenteditable="true"]')) continue;
      if (isMono(el)) continue; // ASCII table inside a code block: leave it aligned
      // Climb to the smallest element containing a full header+separator pair
      while (el && el !== document.body) {
        const lines = (el.innerText || '').split('\n');
        const ok = lines.some(
          (l, i) => ROW.test(l) && i + 1 < lines.length && SEP.test(lines[i + 1])
        );
        if (ok) break;
        el = el.parentElement;
      }
      if (el && el !== document.body && !el.dataset.lgcDone && !el.closest('.lgc-root'))
        targets.add(el);
    }
    for (const el of targets) renderMessage(el, isMono);
  }

  function scan() {
    applyTheme();
    const isMono = makeMonoCache();
    scanCode(isMono);
    scanTables(isMono);
  }

  let pending = null;
  const observer = new MutationObserver(() => {
    if (pending) return;
    pending = setTimeout(() => {
      pending = null;
      scan();
    }, 300);
  });
  observer.observe(document.body, { childList: true, subtree: true });
  scan();
}

// ─────────────────────────────────────────────────────────────────────────────
// Node self-check: `node gchat-renderer.user.js`
// ─────────────────────────────────────────────────────────────────────────────
if (typeof document === 'undefined') {
  const assert = (cond, m) => {
    if (!cond) { console.error('FAIL:', m); process.exit(1); }
  };
  const T = (s) => ({ text: s });
  const B = (s) => ({ node: { textContent: s } }); // fake bold/code inline span

  // Message: prose, table (with inline element inside a cell), prose
  const tokens = [
    T('Analyse des composants :'), NL,
    NL,
    T('| Composant | Replicas | Verdict |'), NL,
    T('|---|---|---|'), NL,
    T('| '), B('kube-apiserver'), T(' | 3 | RAS |'), NL,
    T('| CoreDNS | 3 | '), B('OK'), T(' |'), NL,
    NL,
    T('Verdict global : RAS.'),
  ];
  const segs = parseSegments(groupLines(tokens));
  assert(segs.length === 3, 'three segments');
  assert(segs[1].type === 'table', 'middle segment is a table');
  assert(segs[1].header.length === 3, 'three header cells');
  assert(lineText(segs[1].header[0]) === 'Composant', 'header cell text');
  assert(segs[1].rows.length === 2, 'two data rows');
  assert(segs[1].rows[0][0].some((t) => t.node), 'inline element kept inside cell');
  assert(lineText(segs[1].rows[0][0]) === 'kube-apiserver', 'cell text from element');
  assert(lineText(segs[1].rows[1][2]) === 'OK', 'trailing inline element cell');
  assert(segs[0].type === 'text' && segs[2].type === 'text', 'prose preserved around');

  // No false positives without separator row
  const noTable = parseSegments(groupLines([T('a | b'), NL, T('c | d')]));
  assert(noTable.every((s) => s.type === 'text'), 'pipes without separator stay prose');

  // Separator variants
  assert(SEP.test('|:---|---:|:--:|'), 'alignment separators accepted');
  assert(!SEP.test('| a | b |'), 'data row is not a separator');

  // Chat DOM specifics: hidden markdown markers excluded, <img> emoji counted
  const hiddenMarker = { node: {
    getAttribute: (k) => (k === 'data-cd' ? 'hidden' : null), textContent: '*',
  } };
  const emojiImg = { node: {
    getAttribute: (k) => (k === 'data-emoji' ? '⚠' : null),
    tagName: 'IMG', alt: '⚠', textContent: '',
  } };
  assert(lineText([hiddenMarker, T('gras'), hiddenMarker]) === 'gras',
    'hidden markdown markers excluded from text');
  assert(lineText([emojiImg, T(' fine-tuning')]) === '⚠ fine-tuning',
    'img emoji contributes its glyph');

  console.log('OK: parser self-check passed');
}
