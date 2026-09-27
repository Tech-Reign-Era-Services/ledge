'use strict';

(() => {
  const REPO = 'Tech-Reign-Era-Services/ledge';

  // Point every download button straight at the latest .pkg, and show its version and size.
  // Without JS (or if GitHub's API is unavailable) the buttons still go to the Releases page.
  async function loadRelease() {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      if (!res.ok) return;
      const release = await res.json();
      const pkg = (release.assets || []).find((a) => a.name.endsWith('.pkg'));
      if (!pkg) return;
      const version = release.tag_name.replace(/^v/, '');
      const size = pkg.size < 1048576 ? `${Math.round(pkg.size / 1024)} KB` : `${(pkg.size / 1048576).toFixed(1)} MB`;
      document.querySelectorAll('[data-download]').forEach((a) => { a.href = pkg.browser_download_url; });
      document.querySelectorAll('[data-pkg-name]').forEach((el) => { el.textContent = pkg.name; });
      document.querySelectorAll('[data-release-meta]').forEach((el) => {
        el.textContent = `Free · Version ${version} · ${size} download · Apple silicon and Intel · macOS 13 or later`;
      });
    } catch { /* keep the Releases page links */ }
  }

  // Phones, tablets and other computers can't run Ledge: say so instead of starting a download.
  function flagNonMac() {
    const ua = navigator.userAgent;
    const isMac = /Macintosh/.test(ua) && navigator.maxTouchPoints <= 1; // iPads also say Macintosh, but have touch
    if (isMac) return;
    const note = document.querySelector('.not-mac');
    if (note) note.hidden = false;
    const btn = document.querySelector('[data-copy-link]');
    if (btn && navigator.clipboard) {
      btn.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(location.href.split('#')[0]); btn.textContent = 'link copied'; } catch { /* ignore */ }
      });
    } else if (btn) {
      btn.replaceWith(document.createTextNode('share this page to yourself'));
    }
  }

  function navShadow() {
    const nav = document.querySelector('.nav');
    if (!nav) return;
    const update = () => nav.classList.toggle('scrolled', window.scrollY > 8);
    update();
    window.addEventListener('scroll', update, { passive: true });
  }

  // Looping videos: respect reduced motion, play only on screen, and give people a pause button.
  function loopVideo(video) {
    const toggle = video.parentElement.querySelector('[data-video-toggle]');
    if (!toggle) return;
    let userPaused = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const sync = () => {
      toggle.classList.toggle('paused', video.paused);
      toggle.setAttribute('aria-label', video.paused ? 'Play video' : 'Pause video');
    };
    if (userPaused) { video.removeAttribute('autoplay'); video.pause(); }
    toggle.addEventListener('click', () => {
      if (video.paused) { userPaused = false; video.play().catch(() => {}); } else { userPaused = true; video.pause(); }
    });
    video.addEventListener('play', sync);
    video.addEventListener('pause', sync);
    new IntersectionObserver(([entry]) => {
      if (userPaused) return;
      if (entry.isIntersecting) video.play().catch(() => {}); else video.pause();
    }, { threshold: 0.25 }).observe(video);
    sync();
  }

  loadRelease();
  document.querySelectorAll('[data-hero-video]').forEach(loopVideo);
  flagNonMac();
  navShadow();
})();
