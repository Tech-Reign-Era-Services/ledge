'use strict';

// The page's only bridge to the app: the same window.shelf API the page had under Electron, carried over
// WebKit message handlers. Calls return promises (the app replies); events arrive through window.__ledge.
(() => {
  const post = (cmd, args) => window.webkit.messageHandlers.ledge.postMessage({ cmd, args });
  const invoke = (cmd) => (...args) => post(cmd, args);
  const send = (cmd) => (...args) => { post(cmd, args).catch(() => {}); };
  const handlers = {};
  const listen = (name) => (fn) => { (handlers[name] ||= []).push(fn); };

  window.__ledge = { emit: (name, payload) => (handlers[name] || []).forEach((fn) => fn(payload)) };

  // Mirror errors to the app's log, so a broken page doesn't fail silently.
  window.addEventListener('error', (e) => send('log')(`${e.message} (${e.filename}:${e.lineno})`));
  window.addEventListener('unhandledrejection', (e) => send('log')(String(e.reason)));

  window.shelf = {
    items: invoke('items'),
    addFiles: invoke('addFiles'),
    addText: invoke('addText'),
    paste: invoke('paste'),
    remove: invoke('remove'),
    clear: invoke('clear'),
    copy: invoke('copy'),
    open: invoke('open'),
    reveal: invoke('reveal'),
    preview: invoke('preview'),
    closePreview: invoke('closePreview'),
    focus: invoke('focus'),
    icon: invoke('icon'),
    activities: invoke('activities'),
    activity: invoke('activity'), // (id, 'playpause' | 'next' | 'previous' | 'open' | 'dismiss')
    setState: send('setState'),
    drag: send('drag'),
    // Dropped files are read by the app itself (a web page never sees their paths).
    pathFor: () => null,
    onState: listen('state'),
    onItems: listen('items'),
    onFlash: listen('flash'),
    onActivities: listen('activities'),
    onLevels: listen('levels'), // the music bars: four levels 0–1, bass to treble, or null to animate by themselves
  };
})();
