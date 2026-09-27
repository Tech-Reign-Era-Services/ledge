'use strict';

/* global icon */
// The Shelf page. The app owns the items and the window size; this draws the island,
// animates it, and turns pointer, drag and keyboard input into Shelf actions.
const api = window.shelf;
const $ = (id) => document.getElementById(id);
const body = document.body;

const S = {
  state: 'closed',
  layout: null,
  items: [],
  selected: new Set(),
  anchor: null, // last clicked tile, for shift-click ranges
  hover: false,
  dragDepth: 0,
  dragOut: false, // dragging something out of the Shelf (so it isn't taken as a drop onto it)
  shown: false, // the first list has been drawn: later additions animate in
  previewing: null, // id of the item open in Quick Look
};
const timers = {};
const later = (name, ms, fn) => { clearTimeout(timers[name]); timers[name] = setTimeout(fn, ms); };
const cancel = (name) => clearTimeout(timers[name]);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return el;
}
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

/** Restart a CSS animation class (e.g. a bump that should play again on every new item). */
function replay(el, cls) {
  el.classList.remove(cls);
  void el.offsetWidth; // eslint-disable-line no-void
  el.classList.add(cls);
}

// ---------- island shape ----------

function applyState({ state, layout }) {
  const wasOpen = S.state !== 'closed';
  S.state = state;
  S.layout = layout;
  const open = state !== 'closed';
  const island = open ? layout.island.open : layout.island.closed;
  const root = document.documentElement.style;
  root.setProperty('--w', `${island.width}px`);
  root.setProperty('--h', `${island.height}px`);
  root.setProperty('--open-w', `${layout.island.open.width}px`);
  root.setProperty('--open-h', `${layout.island.open.height}px`);
  root.setProperty('--bar', `${layout.bar}px`);
  root.setProperty('--notch', `${layout.hasNotch ? layout.notch.width : 0}px`);
  root.setProperty('--sh', `${layout.shoulder}px`);
  root.setProperty('--top', `${open ? layout.inset.open : layout.inset.closed}px`);
  body.classList.toggle('is-open', open);
  body.classList.toggle('flat', !layout.hasNotch);
  body.classList.add('placed'); // sizes known: the ears may show
  if (open && !wasOpen) enterItems();
  if (open !== wasOpen) renderNow(); // the music bar moves only while it can be seen
  if (!open) {
    S.previewing = null;
    S.selected.clear();
    S.dragDepth = 0;
    S.dragOut = false;
    body.classList.remove('dragging');
    renderItems();
  }
  if (state === 'open') $('tray').focus();
}

/** Opening: the items rise into place one after another. */
function enterItems() {
  const tray = $('tray');
  if (reducedMotion.matches) return;
  replay(tray, 'entering');
  const visible = Math.min(S.items.length, 8);
  later('entering', visible * 34 + 700, () => tray.classList.remove('entering'));
}

const setState = (state) => { if (state !== S.state) api.setState(state); };

// Hover: peek after a moment (so passing through the menu bar doesn't open it), close soon after leaving.
const island = $('island');
island.addEventListener('mouseenter', () => {
  S.hover = true;
  cancel('close');
  if (S.state === 'closed') later('peek', 140, () => S.hover && setState('peek'));
});
island.addEventListener('mouseleave', () => {
  S.hover = false;
  cancel('peek');
  if (S.state === 'peek') later('close', 380, () => !S.hover && !S.dragDepth && setState('closed'));
});
island.addEventListener('mousemove', () => {
  S.dragOut = false;
  if (!S.hover) { S.hover = true; cancel('close'); }
});

// ---------- dropping things on the Shelf ----------

const acceptsDrop = (e) => [...e.dataTransfer.types].some((t) => t === 'Files' || t === 'text/plain' || t === 'text/uri-list');

function dropLabel(e) {
  const files = [...e.dataTransfer.items].filter((i) => i.kind === 'file').length;
  if (files > 1) return `Drop ${files} items on the Shelf`;
  if (files === 1) return 'Drop it on the Shelf';
  return [...e.dataTransfer.types].includes('text/uri-list') ? 'Drop the link on the Shelf' : 'Drop the text on the Shelf';
}

document.addEventListener('dragenter', (e) => {
  if (!acceptsDrop(e) || S.dragOut) return;
  if (!S.dragDepth) $('drop-text').textContent = dropLabel(e);
  S.dragDepth++;
  cancel('close');
  body.classList.add('dragging');
  if (S.state === 'closed') setState('peek');
});
document.addEventListener('dragover', (e) => {
  if (!acceptsDrop(e) || S.dragOut) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
});
document.addEventListener('dragleave', () => {
  if (S.dragOut) return;
  S.dragDepth = Math.max(0, S.dragDepth - 1);
  if (S.dragDepth) return;
  body.classList.remove('dragging');
  if (S.state === 'peek') later('close', 300, () => !S.dragDepth && !S.hover && setState('closed'));
});
document.addEventListener('drop', async (e) => {
  e.preventDefault();
  S.dragDepth = 0;
  body.classList.remove('dragging');
  if (S.dragOut) return;
  replay(document.querySelector('.clip'), 'gulp');
  // The pointer is over the island after a drop; closing waits until it leaves.
  S.hover = true;
  // Dropped files never reach the page with their paths: the app reads them from the drop itself.
  if ([...e.dataTransfer.types].includes('Files')) return;
  const uri = (e.dataTransfer.getData('text/uri-list') || '').split('\n').map((l) => l.trim()).find((l) => l && !l.startsWith('#'));
  const text = uri || e.dataTransfer.getData('text/plain');
  if (text) await api.addText(text);
});

// ---------- items ----------

const iconCache = new Map(); // item id → data URL
const iconFor = (it) => (iconCache.has(it.id) ? Promise.resolve(iconCache.get(it.id)) : api.icon(it.id).then((url) => { iconCache.set(it.id, url); return url; }));

function thumbFor(it) {
  if (it.kind === 'text') return h('div', { class: 'thumb note' }, it.text.slice(0, 180));
  if (it.kind === 'link') return h('div', { class: 'thumb link' }, icon('link', 22));
  const box = h('div', { class: 'thumb' });
  iconFor(it).then((url) => { if (url) box.replaceChildren(h('img', { src: url, alt: '', draggable: 'false' })); });
  return box;
}

const tiles = new Map(); // item id → its tile, kept between renders so only real changes animate

function makeTile(it) {
  const title = it.kind === 'file' ? it.path : it.text.slice(0, 400);
  return h('div', {
    class: 'tile', role: 'option', title, draggable: 'true',
    onmousedown: (e) => {
      if (e.button !== 0 || e.target.closest('.x')) return;
      select(it, e);
      api.focus(); // so Space, the arrows and ⌘C that follow reach the Shelf, not the app underneath
    },
    ondblclick: () => api.open(it.id),
    ondragstart: (e) => dragOut(e, it),
    ondragend: () => { S.dragOut = false; },
  },
  thumbFor(it),
  h('div', { class: 'name' }, it.name),
  h('button', { class: 'x', title: 'Remove from the Shelf', 'aria-label': `Remove ${it.name}`, onclick: (e) => { e.stopPropagation(); api.remove([it.id]); } }, icon('x', 10)));
}

function select(it, e) {
  const index = S.items.findIndex((x) => x.id === it.id);
  if (e.shiftKey && S.anchor != null) {
    const [a, b] = [S.anchor, index].sort((x, y) => x - y);
    S.items.slice(a, b + 1).forEach((x) => S.selected.add(x.id));
  } else if (e.metaKey) {
    if (S.selected.has(it.id)) S.selected.delete(it.id); else S.selected.add(it.id);
    S.anchor = index;
  } else if (!S.selected.has(it.id)) {
    // Pressing on an already-selected tile keeps the selection, so the whole group can be dragged.
    S.selected = new Set([it.id]);
    S.anchor = index;
  }
  renderItems();
  if (S.previewing && S.previewing !== it.id && S.selected.has(it.id)) preview(it.id); // the preview follows the click, as in Finder
}

/** Drag the tile (or the selection it belongs to) out to Finder, Mail, a browser upload box… */
function dragOut(e, it) {
  const group = S.selected.has(it.id) ? S.items.filter((x) => S.selected.has(x.id)) : [it];
  const files = group.filter((x) => x.kind === 'file');
  S.dragOut = true;
  if (files.length) {
    // Files need a native drag (the page can't hand out real files), which the app starts.
    // The page gets no dragend for it, so the flag clears when the pointer moves over the island again.
    e.preventDefault();
    api.drag(files.map((x) => x.id));
    return;
  }
  // Text and links are an ordinary web drag, which every Mac app understands.
  const text = group.map((x) => x.text).join('\n\n');
  e.dataTransfer.effectAllowed = 'copy';
  e.dataTransfer.setData('text/plain', text);
  if (group.every((x) => x.kind === 'link')) e.dataTransfer.setData('text/uri-list', group.map((x) => x.text).join('\r\n'));
}

const targetIds = () => (S.selected.size ? [...S.selected] : S.items.map((x) => x.id));

async function copy(ids) {
  const res = await api.copy(ids);
  if (!res || !res.count) return;
  const what = res.kind === 'files' ? plural(res.count, 'file') : res.count === 1 ? 'the text' : plural(res.count, 'snippet');
  S.copied = true;
  renderHead();
  say(h('span', {}, h('span', { class: 'good' }, icon('check', 12)), `Copied ${what}. Press `, h('kbd', {}, '⌘V'), ' where you want it.'), 2600);
  later('copied', 1600, () => { S.copied = false; renderHead(); });
}

// ---------- drawing ----------

let spoken = null; // a passing message in the footer, instead of the usual hint
function say(el, ms) {
  spoken = el;
  renderHint();
  later('say', ms, () => { spoken = null; renderHint(); });
}

function renderHint() {
  const n = S.items.length;
  const k = (key) => h('kbd', {}, key);
  let el = spoken;
  if (!el && S.previewing) el = h('span', {}, k('Space'), ' closes the preview · ', k('←'), k('→'), ' previews the next one');
  else if (!el && S.selected.size) el = h('span', {}, k('Space'), ' to preview · ', k('⌘C'), ' to copy · ', k('⌫'), ' to remove · or drag it out');
  else if (!el && n) el = h('span', {}, 'Drag out, or ', k('⌘C'), ' then ', k('⌘V'), ' anywhere · select and ', k('Space'), ' to preview');
  else if (!el) el = h('span', {}, 'Drag things here, or copy and press ', k('⌘V'));
  const hint = $('hint');
  if (hint.firstChild && hint.firstChild.textContent === el.textContent) return; // unchanged: don't replay its entrance
  hint.replaceChildren(el);
}

function renderHead() {
  const n = S.items.length;
  const sel = S.selected.size;
  setCount($('count'), n ? String(n) : '');
  $('actions').replaceChildren(
    h('button', { class: `act ${S.copied ? 'done' : ''}`, disabled: !n, title: 'Put these on the clipboard, then ⌘V anywhere', onclick: () => copy(targetIds()) },
      icon(S.copied ? 'check' : 'copy', 13), S.copied ? 'Copied' : sel ? `Copy ${sel}` : 'Copy all'),
    h('button', { class: 'act quiet', disabled: !n, title: sel ? 'Remove the selected items (⌫)' : 'Empty the Shelf. Your files stay where they are.', onclick: () => { if (sel) api.remove([...S.selected]); else api.clear(); } },
      icon(sel ? 'x' : 'trash', 13), sel ? 'Remove' : 'Clear'));
}

/** Change a number with a little roll, the way the Dynamic Island updates a count. */
function setCount(el, text) {
  if (el.textContent === text) return;
  el.replaceChildren(text ? h('span', { class: S.shown ? 'tick' : '' }, text) : '');
}

function renderEars(prevCount) {
  const n = S.items.length;
  setCount($('ear-count'), n ? String(n) : '');
  const newest = S.items[0];
  const thumb = $('ear-thumb');
  thumb.className = 'ear-thumb';
  thumb.replaceChildren();
  if (newest) {
    if (newest.kind === 'text') { thumb.classList.add('note'); thumb.append(icon('doc', 12)); }
    else if (newest.kind === 'link') { thumb.classList.add('link'); thumb.append(icon('link', 12)); }
    else {
      thumb.append(icon('shelf', 14));
      iconFor(newest).then((url) => { if (url && S.items[0] === newest) thumb.replaceChildren(h('img', { src: url, alt: '' })); });
    }
  }
  if (S.shown && n > prevCount) replay($('ears'), 'bump');
}

function renderItems() {
  body.classList.toggle('has-items', S.items.length > 0);
  renderHead();
  renderHint();
  const tray = $('tray');
  if (!S.items.length) {
    for (const el of tiles.values()) el.remove();
    tiles.clear();
    if (!tray.querySelector('.empty')) {
      tray.replaceChildren(h('div', { class: 'empty' },
        h('div', { class: 'empty-art' }, icon('plus', 16)),
        h('b', {}, 'Nothing on the Shelf'),
        h('span', {}, 'Keep files, text and links here for a moment.')));
    }
    updateFades();
    return;
  }
  tray.querySelector('.empty')?.remove();

  // Where each tile is now, so tiles that shift (to make room for a new one) can slide there.
  const animate = S.shown && S.state !== 'closed' && !reducedMotion.matches;
  const before = new Map();
  if (animate) for (const [id, el] of tiles) before.set(id, el.getBoundingClientRect().left);

  // Tiles that left: shrink away, then go.
  const ids = new Set(S.items.map((x) => x.id));
  for (const [id, el] of tiles) {
    if (ids.has(id)) continue;
    tiles.delete(id);
    if (reducedMotion.matches || S.state === 'closed') { el.remove(); continue; }
    el.classList.add('leave');
    setTimeout(() => el.remove(), 320);
  }
  // New and existing tiles, in order.
  let prev = null;
  S.items.forEach((it, i) => {
    let el = tiles.get(it.id);
    if (!el) {
      el = makeTile(it);
      tiles.set(it.id, el);
      if (S.shown && S.state !== 'closed' && !reducedMotion.matches) {
        el.classList.add('arrive');
        el.addEventListener('animationend', () => el.classList.remove('arrive'), { once: true });
      }
    }
    const on = S.selected.has(it.id);
    el.classList.toggle('on', on);
    el.setAttribute('aria-selected', on ? 'true' : 'false');
    el.style.setProperty('--i', String(Math.min(i, 8)));
    // Only move a tile when it's out of order: moving one restarts its animations. Leaving tiles stay put.
    let want = prev ? prev.nextSibling : tray.firstChild;
    while (want && want.classList.contains('leave')) want = want.nextSibling;
    if (want !== el) tray.insertBefore(el, want);
    prev = el;
  });
  if (animate) slide(before);
  updateFades();
}

/** FLIP: tiles that moved start where they were and spring to where they are now. */
function slide(before) {
  const easing = getComputedStyle(document.documentElement).getPropertyValue('--spring').trim();
  for (const [id, el] of tiles) {
    const x0 = before.get(id);
    if (x0 == null) continue;
    const dx = x0 - el.getBoundingClientRect().left;
    if (Math.abs(dx) > 1) el.animate([{ transform: `translateX(${dx}px)` }, { transform: 'none' }], { duration: 480, easing });
  }
}

function setItems(items) {
  const prevCount = S.items.length;
  const ids = new Set(items.map((x) => x.id));
  S.selected = new Set([...S.selected].filter((id) => ids.has(id)));
  for (const id of iconCache.keys()) if (!ids.has(id)) iconCache.delete(id);
  const grew = items.length > prevCount && items[0] && !S.items.some((x) => x.id === items[0].id);
  // What you just pasted or dropped becomes the selection, as in Finder, so Space previews it (not what was selected before).
  const had = new Set(S.items.map((x) => x.id));
  const added = items.filter((x) => !had.has(x.id)).map((x) => x.id);
  if (added.length && S.shown && S.state !== 'closed') S.selected = new Set(added);
  S.items = items;
  S.anchor = null;
  renderItems();
  renderEars(prevCount);
  if (grew && S.shown && S.state !== 'closed') $('tray').scrollTo({ left: 0 });
  S.shown = true;
}

/** Fade the row's edges when there's more to scroll to. */
function updateFades() {
  const tray = $('tray');
  const wrap = $('tray-wrap');
  wrap.classList.toggle('more-l', tray.scrollLeft > 4);
  wrap.classList.toggle('more-r', tray.scrollLeft + tray.clientWidth < tray.scrollWidth - 4);
}

// ---------- keyboard (when the Shelf was opened with the shortcut, or clicked) ----------

// ---------- Quick Look (Space, as in Finder) ----------

let previewTurn = 0;
async function preview(id) {
  const turn = ++previewTurn;
  const shown = await api.preview(id, !!S.previewing); // switching: Quick Look must close and reopen to show it
  if (turn !== previewTurn) return; // a later ← → overtook this one
  S.previewing = shown ? id : null;
  renderHint();
}
function closePreview() {
  previewTurn++;
  api.closePreview();
  S.previewing = null;
  renderHint();
}
function togglePreview() {
  if (S.previewing) return closePreview();
  if (!S.items.length) return;
  // Nothing selected: preview the first item, like Finder does with the first file in a folder.
  if (!S.selected.size) { S.selected = new Set([S.items[0].id]); S.anchor = 0; renderItems(); }
  return preview(S.items.find((x) => S.selected.has(x.id)).id);
}
// Someone clicked Quick Look or another app: Space opens a fresh preview next time instead of "closing" one.
// Only once the keys are really gone: opening Quick Look blurs the Shelf for a moment too, then it takes them back.
window.addEventListener('blur', () => later('lostKeys', 300, () => { if (S.previewing && !document.hasFocus()) { S.previewing = null; renderHint(); } }));

const HANDLED = new Set([' ', 'Escape', 'Enter', 'Backspace', 'Delete', 'ArrowLeft', 'ArrowRight']);
document.addEventListener('keydown', (e) => {
  const cmd = e.metaKey;
  // Using the keyboard means you're working in the Shelf: don't let it close when the pointer wanders off.
  if (S.state === 'peek' && (HANDLED.has(e.key) || cmd)) setState('open');
  if (e.key === 'Escape') { if (S.previewing) closePreview(); else setState('closed'); return; }
  if (e.key === ' ') { e.preventDefault(); togglePreview(); return; }
  if (cmd && e.key === 'c') { e.preventDefault(); copy(targetIds()); return; }
  if (cmd && e.key === 'v') { e.preventDefault(); api.paste(); return; }
  if (cmd && e.key === 'a') { e.preventDefault(); S.selected = new Set(S.items.map((x) => x.id)); renderItems(); return; }
  if ((e.key === 'Backspace' || e.key === 'Delete') && S.selected.size) { e.preventDefault(); api.remove([...S.selected]); return; }
  if (e.key === 'Enter' && S.selected.size) { e.preventDefault(); [...S.selected].slice(0, 10).forEach((id) => api.open(id)); return; }
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
    e.preventDefault();
    if (!S.items.length) return;
    const cur = S.items.findIndex((x) => S.selected.has(x.id));
    const next = cur < 0 ? 0 : Math.min(S.items.length - 1, Math.max(0, cur + (e.key === 'ArrowRight' ? 1 : -1)));
    S.selected = new Set([S.items[next].id]);
    S.anchor = next;
    renderItems();
    tiles.get(S.items[next].id)?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    if (S.previewing) preview(S.items[next].id); // the preview follows the selection, as in Finder
  }
});

const tray = $('tray');
// A click on empty space clears the selection.
tray.addEventListener('mousedown', (e) => { if (e.target === tray && S.selected.size) { S.selected.clear(); renderItems(); } });
// A vertical wheel scrolls the row sideways.
tray.addEventListener('wheel', (e) => {
  if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
  e.preventDefault();
  tray.scrollBy({ left: e.deltaY, behavior: 'instant' });
}, { passive: false });
tray.addEventListener('scroll', updateFades, { passive: true });

// ---------- live activities (music, and whatever other apps post) ----------

S.live = [];

function setActivities(list) {
  const had = new Set(S.live.map((a) => a.id));
  S.live = list || [];
  body.classList.toggle('live', S.live.length > 0);
  body.classList.toggle('live-playing', S.live.some((a) => a.kind === 'music' && a.playing));
  renderLiveEars(S.live.some((a) => !had.has(a.id)));
  renderNow();
}

/** The activity's picture: an app icon or symbol the app drew, or an emoji. */
function liveArt(a, size) {
  if (a.emoji) return h('span', { class: 'live-emoji', style: `font-size:${Math.round(size * 0.72)}px` }, a.emoji);
  if (a.art) return h('img', { class: 'art', src: a.art, alt: '', draggable: 'false' }); // the album artwork
  if (a.icon) return h('img', { src: a.icon, alt: '', draggable: 'false' });
  return icon('dots', Math.round(size * 0.6));
}

/** Beside the island when it's closed: dancing bars for music, a ring for progress, or a few characters. */
function trailFor(a) {
  if (a.kind === 'music') return h('span', { class: `eq ${a.playing ? 'on' : ''}` }, h('i'), h('i'), h('i'), h('i'));
  if (a.progress != null) return ring(a.progress, a.tint);
  if (a.trailing) return h('span', { class: 'live-text' }, a.trailing);
  return null;
}

/** The music bars, moving to the music itself: levels from the app, or null to let them animate by themselves. */
function setLevels(levels) {
  body.classList.toggle('eq-real', !!levels);
  document.querySelectorAll('.eq i').forEach((el, i) => {
    el.style.transform = levels ? `scaleY(${(0.2 + 0.8 * (levels[i % levels.length] || 0)).toFixed(2)})` : '';
  });
}

function ring(progress, tint) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 20 20');
  svg.setAttribute('class', 'ring');
  const c = 2 * Math.PI * 7.5;
  for (const [cls, dash] of [['ring-bg', ''], ['ring-fg', `${(c * progress).toFixed(2)} ${c.toFixed(2)}`]]) {
    const el = document.createElementNS(NS, 'circle');
    el.setAttribute('cx', '10'); el.setAttribute('cy', '10'); el.setAttribute('r', '7.5');
    el.setAttribute('class', cls);
    if (dash) el.setAttribute('stroke-dasharray', dash);
    if (dash && tint) el.setAttribute('stroke', tint);
    svg.append(el);
  }
  return svg;
}

function renderLiveEars(bump) {
  const a = S.live[0];
  $('live-icon').replaceChildren(...(a ? [liveArt(a, 20)] : []));
  $('live-icon').classList.toggle('art', !!a?.art);
  const trail = a && trailFor(a);
  $('live-trail').replaceChildren(...(trail ? [trail] : []));
  if (bump && S.shown) replay($('live-ears'), 'bump');
}

/** Where a playing song is now, from where it was when the player last said. */
function musicAt(a) {
  if (a.elapsed == null || !a.duration) return null;
  const e = a.elapsed + (a.playing ? (Date.now() - a.at) / 1000 : 0);
  return Math.min(1, Math.max(0, e / a.duration));
}

function bar(fraction, tint, runSeconds) {
  const fill = h('i', { style: `transform:scaleX(${fraction.toFixed(4)})${tint ? `;background:${tint}` : ''}` });
  const el = h('div', { class: 'now-bar' }, fill);
  // Playing: slide to the end over the time that's left, on the compositor. Nothing runs per frame in the page.
  if (runSeconds > 0) requestAnimationFrame(() => requestAnimationFrame(() => {
    fill.style.transition = `transform ${runSeconds}s linear`;
    fill.style.transform = 'scaleX(1)';
  }));
  return el;
}

function renderNow() {
  const open = S.state !== 'closed';
  $('now').replaceChildren(...S.live.slice(0, 2).map((a) => {
    const act = (action) => (e) => { e.stopPropagation(); api.activity(a.id, action); };
    let right = null;
    let below = null;
    if (a.kind === 'music') {
      right = h('div', { class: 'now-controls' },
        h('button', { class: 'ctl', title: 'Previous', 'aria-label': 'Previous', onclick: act('previous') }, icon('prev', 13)),
        h('button', { class: 'ctl main', title: a.playing ? 'Pause' : 'Play', 'aria-label': a.playing ? 'Pause' : 'Play', onclick: act('playpause') }, icon(a.playing ? 'pause' : 'play', 15)),
        h('button', { class: 'ctl', title: 'Next', 'aria-label': 'Next', onclick: act('next') }, icon('next', 13)));
      const at = musicAt(a);
      if (at != null) below = bar(at, null, open && a.playing ? a.duration * (1 - at) : 0);
    } else {
      if (a.trailing) right = h('span', { class: 'now-trail' }, a.trailing);
      if (a.progress != null) below = bar(a.progress, a.tint, 0);
    }
    const clickable = a.kind === 'music' || a.link;
    return h('div', { class: `now-row ${clickable ? 'go' : ''}`, title: clickable ? `Open ${a.kind === 'music' ? a.source : 'it'}` : null, onclick: clickable ? act('open') : null },
      h('div', { class: `now-art ${a.emoji ? 'emoji' : ''}` }, liveArt(a, 40)),
      h('div', { class: 'now-text' },
        h('b', {}, a.title),
        h('span', {}, [a.source, a.subtitle].filter(Boolean).join(' · ')),
        below),
      right,
      a.kind !== 'music' && h('button', { class: 'x', title: 'Dismiss', 'aria-label': `Dismiss ${a.title}`, onclick: act('dismiss') }, icon('x', 10)));
  }));
}

// ---------- boot ----------

$('title-icon').append(icon('shelf', 14));
$('drop-icon').append(icon('down', 18));
api.onState(applyState);
api.onItems(setItems);
api.onActivities(setActivities);
api.onLevels(setLevels);
api.activities().then(setActivities);
api.onFlash((ms) => later('close', ms, () => !S.hover && S.state === 'peek' && setState('closed')));
api.items().then(setItems);
