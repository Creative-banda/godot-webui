// Menu logic: navigation, animation and presentation. Godot owns settings, stats and the game.
(() => {
  const $ = (id) => document.getElementById(id);
  const app = $('app');
  const screens = [...document.querySelectorAll('.screen')];

  // ---------- browser-side navigation with fast, hardware-accelerated transitions
  let current = 'main';
  let isNavigating = false;
  let navTimer = 0;

  function show(name) {
    if (app) app.dataset.screen = name;
    screens.forEach((s) => {
      const on = s.id === 'screen-' + name;
      s.classList.toggle('active', on);
    });
    current = name;
    if (name === 'stats') animateStats();
    $('panel').scrollTop = 0;

    // Pause canvas particle rendering briefly during screen transition for buttery smooth 60 FPS
    isNavigating = true;
    clearTimeout(navTimer);
    navTimer = setTimeout(() => { isNavigating = false; }, 200);
  }
  document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => show(b.dataset.goto)));
  show('main');

  // ---------- HTML -> Godot (intent only)
  let level = 1;
  $('btn-play').addEventListener('click', () => Godot.emit('menu_play', { level }));
  $('btn-quit').addEventListener('click', () => Godot.emit('menu_quit'));
  $('btn-start-level').addEventListener('click', () => Godot.emit('menu_play', { level }));
  const levelButtons = [...document.querySelectorAll('[data-level]')];
  function selectLevel(n) {
    level = n;
    levelButtons.forEach((b) => b.classList.toggle('sel', Number(b.dataset.level) === n));
    $('start-n').textContent = n;
    $('play-sub').textContent = 'Continue · Level ' + n;
  }
  levelButtons.forEach((b) => b.addEventListener('click', () => selectLevel(Number(b.dataset.level))));
  selectLevel(1);

  // Settings: send only the change; controls are redrawn from Godot's reply.
  const music = $('set-music');
  music.addEventListener('input', () => {
    music.style.setProperty('--pct', music.value * 100 + '%'); // instant visual feedback
    Godot.emit('settings_changed', { music: Number(music.value) });
  });
  $('set-sfx').addEventListener('change', (e) => Godot.emit('settings_changed', { sfx: e.target.checked }));
  $('set-debug').addEventListener('change', (e) => Godot.emit('settings_changed', { show_debug: e.target.checked }));
  document.querySelectorAll('#set-difficulty button').forEach((b) =>
    b.addEventListener('click', () => Godot.emit('settings_changed', { difficulty: b.dataset.value })));

  const nameInput = $('input-player-name');
  if (nameInput) {
    nameInput.addEventListener('input', (e) => {
      console.log('Player name:', e.target.value);
    });
  }
  const scoreInput = $('input-target-score');
  if (scoreInput) {
    scoreInput.addEventListener('input', (e) => {
      console.log('Target score:', e.target.value);
    });
  }

  // ---------- Godot -> HTML
  Godot.on('settings', (s) => {
    music.value = s.music;
    music.style.setProperty('--pct', s.music * 100 + '%');
    $('out-music').textContent = Math.round(s.music * 100) + '%';
    $('set-sfx').checked = s.sfx;
    $('set-debug').checked = s.show_debug;
    document.querySelectorAll('#set-difficulty button').forEach((b) => {
      const on = b.dataset.value === s.difficulty;
      b.classList.toggle('on', on);
      if (on) $('set-difficulty').style.setProperty('--idx', b.dataset.i);
    });
  });

  let stats = { plays: 0, deaths: 0, jumps: 0 };
  Godot.on('stats', (s) => { stats = s; if (current === 'stats') animateStats(); });
  function countUp(el, to) {
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 600);
      el.textContent = Math.round(to * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }
  function animateStats() {
    countUp($('st-plays'), stats.plays);
    countUp($('st-deaths'), stats.deaths);
    countUp($('st-jumps'), stats.jumps);
    const per = stats.plays ? stats.deaths / stats.plays : 0;
    $('ring-val').textContent = per.toFixed(1);
    $('ring-fg').style.strokeDasharray = `${Math.min(per / 5, 1) * 100} 100`; // full ring = 5 deaths per game
  }

  Godot.on('info', (i) => {
    $('ab-engine').textContent = 'Godot ' + i.engine;
    $('ab-os').textContent = i.os;
    $('ab-renderer').textContent = i.renderer;
    $('brand-ver').textContent = i.engine.split(' ')[0].split('.').slice(0, 2).join('.');
    if (i.level) selectLevel(i.level);
  });

  // ---------- ambient bubbles & sparkles FX (ultra-optimized for mobile) ----------
  const canvas = $('fx');
  const ctx = canvas.getContext('2d');
  const prefersReduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Pre-render bubble stamp onto an offscreen canvas ONCE (avoids 1,200 dynamic gradient allocations/sec)
  const bubbleSprite = document.createElement('canvas');
  const B_RES = 64;
  bubbleSprite.width = B_RES;
  bubbleSprite.height = B_RES;
  const bCtx = bubbleSprite.getContext('2d');
  const bGrad = bCtx.createRadialGradient(22, 20, 4, 32, 32, 28);
  bGrad.addColorStop(0, 'rgba(255, 255, 255, 0.45)');
  bGrad.addColorStop(0.55, 'rgba(255, 209, 102, 0.2)');
  bGrad.addColorStop(0.85, 'rgba(255, 71, 133, 0.25)');
  bGrad.addColorStop(1, 'rgba(56, 182, 255, 0.45)');
  bCtx.fillStyle = bGrad;
  bCtx.beginPath();
  bCtx.arc(32, 32, 28, 0, Math.PI * 2);
  bCtx.fill();
  bCtx.lineWidth = 1.5;
  bCtx.strokeStyle = 'rgba(255, 255, 255, 0.65)';
  bCtx.stroke();
  bCtx.beginPath();
  bCtx.ellipse(22, 20, 8, 4, -Math.PI / 4, 0, Math.PI * 2);
  bCtx.fillStyle = 'rgba(255, 255, 255, 0.85)';
  bCtx.fill();

  // Pre-render star sparkle onto an offscreen canvas ONCE
  const starSprite = document.createElement('canvas');
  const S_RES = 24;
  starSprite.width = S_RES;
  starSprite.height = S_RES;
  const sCtx = starSprite.getContext('2d');
  sCtx.fillStyle = 'rgba(255, 230, 100, 0.85)';
  sCtx.beginPath();
  for (let i = 0; i < 4; i++) {
    sCtx.lineTo(12 + Math.cos((i * Math.PI) / 2) * 10, 12 + Math.sin((i * Math.PI) / 2) * 10);
    sCtx.lineTo(12 + Math.cos((i * Math.PI) / 2 + Math.PI / 4) * 3, 12 + Math.sin((i * Math.PI) / 2 + Math.PI / 4) * 3);
  }
  sCtx.closePath();
  sCtx.fill();

  // Ultra-sparse particles: only 2-3 slow ambient floating bubbles and 1-2 stars
  const isMobile = window.innerWidth <= 768 || (window.matchMedia && window.matchMedia('(max-width: 768px)').matches);
  const bubbleCount = isMobile ? 2 : 3;
  const starCount = isMobile ? 1 : 2;

  const bubbles = Array.from({ length: bubbleCount }, () => ({
    x: Math.random(),
    y: Math.random() * 1.2,
    size: 22 + Math.random() * 20,
    speed: 0.015 + Math.random() * 0.02,
    wobbleSpeed: 0.8 + Math.random() * 1.0,
    wobbleAmp: 0.006 + Math.random() * 0.01,
    phase: Math.random() * Math.PI * 2
  }));

  const stars = Array.from({ length: starCount }, () => ({
    x: Math.random(),
    y: Math.random(),
    size: 8 + Math.random() * 10,
    speed: 0.01 + Math.random() * 0.015,
    alpha: 0.35 + Math.random() * 0.35
  }));

  let W = 0, H = 0;
  function resize() {
    W = canvas.clientWidth;
    H = canvas.clientHeight;
    // Keep canvas 1x to avoid fill-rate tax on high-density phone displays
    canvas.width = W;
    canvas.height = H;
  }
  window.addEventListener('resize', resize);
  resize();

  // Pause canvas rendering while user is tapping or interacting to ensure 100% responsiveness
  window.addEventListener('pointerdown', () => {
    isNavigating = true;
    clearTimeout(navTimer);
    navTimer = setTimeout(() => { isNavigating = false; }, 260);
  }, { passive: true });

  let last = performance.now();
  let lastDraw = 0;
  function frame(t) {
    if (document.hidden || prefersReduced) {
      requestAnimationFrame(frame);
      return;
    }

    // Skip canvas update during active screen transitions to give 100% GPU to navigation
    if (isNavigating) {
      last = t;
      requestAnimationFrame(frame);
      return;
    }

    // Cap ambient particle rendering to 30 FPS (~33ms) to halve mobile GPU load
    if (t - lastDraw < 33) {
      requestAnimationFrame(frame);
      return;
    }
    lastDraw = t;

    const dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    ctx.clearRect(0, 0, W, H);

    // 1. Draw bubbles using cached offscreen sprite
    for (const b of bubbles) {
      b.y -= b.speed * dt;
      if (b.y < -0.1) {
        b.y = 1.1;
        b.x = Math.random();
      }
      const bx = (b.x + Math.sin(t * 0.001 * b.wobbleSpeed + b.phase) * b.wobbleAmp) * W;
      const by = b.y * H;
      ctx.drawImage(bubbleSprite, bx - b.size / 2, by - b.size / 2, b.size, b.size);
    }

    // 2. Draw stars using cached offscreen sprite
    for (const s of stars) {
      s.y -= s.speed * dt;
      if (s.y < -0.05) {
        s.y = 1.05;
        s.x = Math.random();
      }
      const sx = s.x * W;
      const sy = s.y * H;
      ctx.globalAlpha = s.alpha;
      ctx.drawImage(starSprite, sx - s.size / 2, sy - s.size / 2, s.size, s.size);
    }
    ctx.globalAlpha = 1.0;

    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      last = performance.now();
      requestAnimationFrame(frame);
    }
  });
})();
