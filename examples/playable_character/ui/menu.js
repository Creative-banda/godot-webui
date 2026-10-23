// Menu logic: navigation, animation and presentation. Godot owns settings, stats and the game.
(() => {
  const $ = (id) => document.getElementById(id);
  const app = $('app');
  const screens = [...document.querySelectorAll('.screen')];

  // ---------- browser-side navigation with directional transitions
  let current = 'main';
  function show(name) {
    if (app) app.dataset.screen = name;
    const forward = name !== 'main';
    screens.forEach((s) => {
      const on = s.id === 'screen-' + name;
      s.classList.remove('fwd', 'bwd', 'warm');
      s.classList.toggle('active', on);
      if (on) {
        [...s.children].forEach((c, i) => c.style.setProperty('--i', i));
        void s.offsetWidth; // restart animations
        s.classList.add(forward ? 'fwd' : 'bwd');
      }
    });
    current = name;
    if (name === 'stats') animateStats();
    $('panel').scrollTop = 0;
  }
  document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => show(b.dataset.goto)));
  show('main');

  // ---------- warm-up
  // A display:none screen has no style, layout or paint, and the GPU shaders for its shadows,
  // gradients and filters are compiled the first time it is drawn: that lands on the frame of the
  // first visit. Draw each other screen once, invisibly, one per idle slot after the entrance
  // animation, so that cost is paid while the user is still looking at the main screen.
  function warmScreens() {
    const idle = window.requestIdleCallback ? (f) => requestIdleCallback(f, { timeout: 1500 }) : (f) => setTimeout(f, 300);
    const queue = screens.filter((s) => !s.classList.contains('active'));
    const next = () => {
      const s = queue.shift();
      if (!s) return;
      if (s.classList.contains('active')) return next();
      s.classList.add('warm');
      requestAnimationFrame(() => requestAnimationFrame(() => {
        s.classList.remove('warm');
        idle(next);
      }));
    };
    setTimeout(() => idle(next), 1200);
  }
  warmScreens();

  // ---------- tactile candy ripple (purely visual)
  document.querySelectorAll('.press').forEach((el) => {
    el.addEventListener('pointerdown', (e) => {
      const r = el.getBoundingClientRect();
      const size = Math.max(r.width, r.height) * 2;
      const dot = document.createElement('span');
      dot.className = 'ripple';
      dot.style.cssText = `width:${size}px;height:${size}px;left:${e.clientX - r.left - size / 2}px;top:${e.clientY - r.top - size / 2}px`;
      el.appendChild(dot);
      dot.addEventListener('animationend', () => dot.remove());
    });
  });

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
      const k = Math.min(1, (t - t0) / 800);
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

  // ---------- ambient bubbles, sparkles & confetti FX (canvas)
  const canvas = $('fx');
  const ctx = canvas.getContext('2d');
  const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
  let W = 0, H = 0;

  // Soap bubbles
  const bubbleCount = 20;
  const bubbles = Array.from({ length: bubbleCount }, () => ({
    x: Math.random(),
    y: Math.random() * 1.2,
    r: 10 + Math.random() * 22,
    speed: 0.03 + Math.random() * 0.05,
    wobbleSpeed: 1 + Math.random() * 2,
    wobbleAmp: 0.015 + Math.random() * 0.02,
    phase: Math.random() * Math.PI * 2,
    hue: Math.floor(Math.random() * 360)
  }));

  // Sparkles & confetti
  const sparkleCount = 28;
  const sparkles = Array.from({ length: sparkleCount }, () => ({
    x: Math.random(),
    y: Math.random(),
    size: 2.5 + Math.random() * 4,
    speed: 0.02 + Math.random() * 0.06,
    rot: Math.random() * Math.PI * 2,
    rotSpeed: (Math.random() - 0.5) * 3,
    hue: [45, 160, 210, 290, 340][Math.floor(Math.random() * 5)],
    isStar: Math.random() < 0.4
  }));

  function resize() {
    W = canvas.clientWidth;
    H = canvas.clientHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  window.addEventListener('resize', resize);
  resize();

  let last = performance.now();
  function frame(t) {
    const dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    ctx.clearRect(0, 0, W, H);

    // 1. Draw iridescent soap bubbles
    for (const b of bubbles) {
      b.y -= b.speed * dt;
      if (b.y < -0.1) {
        b.y = 1.1;
        b.x = Math.random();
        b.hue = Math.floor(Math.random() * 360);
      }
      const bx = (b.x + Math.sin(t * 0.001 * b.wobbleSpeed + b.phase) * b.wobbleAmp) * W;
      const by = b.y * H;

      // Outer rainbow rim
      ctx.save();
      ctx.beginPath();
      ctx.arc(bx, by, b.r, 0, Math.PI * 2);

      // Translucent bubble body gradient
      const bodyGrad = ctx.createRadialGradient(bx - b.r * 0.3, by - b.r * 0.3, b.r * 0.1, bx, by, b.r);
      bodyGrad.addColorStop(0, `hsla(${b.hue}, 95%, 85%, 0.15)`);
      bodyGrad.addColorStop(0.7, `hsla(${(b.hue + 60) % 360}, 90%, 75%, 0.25)`);
      bodyGrad.addColorStop(1, `hsla(${(b.hue + 140) % 360}, 95%, 70%, 0.55)`);
      ctx.fillStyle = bodyGrad;
      ctx.fill();

      // Iridescent outline
      ctx.lineWidth = 1.8;
      ctx.strokeStyle = `hsla(${b.hue}, 90%, 80%, 0.6)`;
      ctx.stroke();

      // Curved specular gloss highlight (top-left)
      ctx.beginPath();
      ctx.ellipse(bx - b.r * 0.35, by - b.r * 0.35, b.r * 0.32, b.r * 0.16, -Math.PI / 4, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255, 255, 255, 0.75)';
      ctx.fill();

      // Small secondary glint (bottom-right)
      ctx.beginPath();
      ctx.arc(bx + b.r * 0.4, by + b.r * 0.4, b.r * 0.1, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255, 255, 255, 0.45)';
      ctx.fill();
      ctx.restore();
    }

    // 2. Draw confetti & sparkles
    for (const s of sparkles) {
      s.y -= s.speed * dt;
      s.rot += s.rotSpeed * dt;
      if (s.y < -0.05) {
        s.y = 1.05;
        s.x = Math.random();
      }
      const sx = s.x * W;
      const sy = s.y * H;

      ctx.save();
      ctx.translate(sx, sy);
      ctx.rotate(s.rot);

      if (s.isStar) {
        // 4-pointed sparkle
        ctx.fillStyle = `hsla(${s.hue}, 95%, 80%, 0.7)`;
        ctx.beginPath();
        for (let i = 0; i < 4; i++) {
          ctx.lineTo(Math.cos((i * Math.PI) / 2) * s.size * 2, Math.sin((i * Math.PI) / 2) * s.size * 2);
          ctx.lineTo(Math.cos((i * Math.PI) / 2 + Math.PI / 4) * s.size * 0.5, Math.sin((i * Math.PI) / 2 + Math.PI / 4) * s.size * 0.5);
        }
        ctx.closePath();
        ctx.fill();
      } else {
        // Confetti flake
        ctx.fillStyle = `hsla(${s.hue}, 90%, 70%, 0.65)`;
        ctx.fillRect(-s.size, -s.size, s.size * 2, s.size * 1.5);
      }
      ctx.restore();
    }

    if (!document.hidden) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
      last = performance.now();
      requestAnimationFrame(frame);
    }
  });
})();
