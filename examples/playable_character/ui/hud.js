// HUD logic: presentation and input capture only. All gameplay happens in Godot.
(() => {
  const $ = (id) => document.getElementById(id);

  // Only the elements marked data-webui-touch receive touches; everything else reaches the game.
  Godot.touchRegions();

  // ---------- page lifecycle ----------
  // The page loads with body.loading (hidden by the loader cover) and fades in when the first
  // state arrives; Godot re-hides it with an "app_loading" event while it swaps scenes.
  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  // ---------- virtual joystick (one pointer, pointer capture, always releases)
  const zone = $('stick-zone');
  const stick = $('stick');
  const knob = $('knob');
  const DEAD_ZONE = 0.12;
  let stickPointer = null;
  let sent = { x: 0, y: 0 };

  function sendMove(x, y) {
    if (x === sent.x && y === sent.y) return;
    sent = { x, y };
    Godot.emit('move_changed', { x, y });
  }

  function paintStick(x, y) {
    const radius = stick.getBoundingClientRect().width / 2 - 8;
    knob.style.transform = `translate(${x * radius}px, ${y * radius}px)`;
  }

  function updateStick(e) {
    const r = stick.getBoundingClientRect();
    const radius = r.width / 2 - 8;
    let dx = e.clientX - (r.left + r.width / 2);
    let dy = e.clientY - (r.top + r.height / 2);
    const len = Math.hypot(dx, dy);
    if (len > radius) { dx = dx / len * radius; dy = dy / len * radius; }
    let x = dx / radius, y = dy / radius;
    paintStick(x, y);
    if (Math.hypot(x, y) < DEAD_ZONE) { x = 0; y = 0; }
    sendMove(Math.round(x * 100) / 100, Math.round(y * 100) / 100);
  }

  function releaseStick() {
    stickPointer = null;
    stick.classList.remove('drag');
    paintStick(0, 0);
    sendMove(0, 0);
  }

  zone.addEventListener('pointerdown', (e) => {
    if (stickPointer !== null) return;
    stickPointer = e.pointerId;
    zone.setPointerCapture(e.pointerId);
    stick.classList.add('drag');
    updateStick(e);
  });
  zone.addEventListener('pointermove', (e) => { if (e.pointerId === stickPointer) updateStick(e); });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    zone.addEventListener(type, (e) => { if (e.pointerId === stickPointer) releaseStick(); });
  }
  Godot.guard(releaseStick);

  // ---------- buttons: each tracks its own pointer, so they work simultaneously with the joystick
  function holdButton(el, onDown, onUp) {
    let pointer = null;
    const up = () => {
      if (pointer === null) return;
      pointer = null;
      el.classList.remove('down');
      if (onUp) onUp();
    };
    el.addEventListener('pointerdown', (e) => {
      if (pointer !== null) return;
      pointer = e.pointerId;
      el.setPointerCapture(e.pointerId);
      el.classList.add('down');
      onDown();
    });
    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      el.addEventListener(type, (e) => { if (e.pointerId === pointer) up(); });
    }
    Godot.guard(up);
  }

  holdButton($('btn-jump'), () => Godot.emit('jump'), () => Godot.emit('jump_released'));  // hold = full jump, tap = hop
  holdButton($('btn-flare'), () => Godot.emit('flare'));
  holdButton($('btn-pause'), () => Godot.emit('pause_toggle'));
  holdButton($('btn-resume'), () => Godot.emit('pause_toggle'));
  holdButton($('btn-restart'), () => Godot.emit('restart'));
  holdButton($('btn-menu'), () => Godot.emit('back_to_menu'));
  holdButton($('btn-again'), () => Godot.emit('play_again'));
  holdButton($('btn-next'), () => Godot.emit('next_level'));
  holdButton($('btn-results-menu'), () => Godot.emit('back_to_menu'));

  document.addEventListener('contextmenu', (e) => e.preventDefault());

  // ---------- keyboard (desktop preview): the WebView holds focus, so forward keys as intents.
  // Same pattern as the 3D demo: the page forwards what it sees; Godot stays authoritative.
  const held = new Set();
  const KEYMAP = { KeyA: 'left', ArrowLeft: 'left', KeyD: 'right', ArrowRight: 'right' };

  function sendMoveFromKeys() {
    const x = (held.has('right') ? 1 : 0) - (held.has('left') ? 1 : 0);
    Godot.emit('move_changed', { x, y: 0 });
  }
  function releaseKeys() {
    if (held.size === 0) return;
    held.clear();
    sendMoveFromKeys();
  }
  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') {
      if (!e.repeat) Godot.emit('jump');
      e.preventDefault();
    } else if (e.code === 'Escape' && !e.repeat) {
      Godot.emit('pause_toggle');
    } else if (e.code === 'KeyG' && !e.repeat) {
      Godot.emit('warp');
    } else if ((e.code === 'KeyX' || e.code === 'KeyJ' || e.code === 'KeyF') && !e.repeat) {
      Godot.emit('attack_pressed');
      Godot.emit('attack_released');  // the flare is a burst, not a hold
    } else if (KEYMAP[e.code]) {
      held.add(KEYMAP[e.code]);
      sendMoveFromKeys();
      e.preventDefault();
    }
  });
  window.addEventListener('keyup', (e) => {
    if (e.code === 'Space') Godot.emit('jump_released');
    if (KEYMAP[e.code]) {
      held.delete(KEYMAP[e.code]);  // both keys of a pair (A + ArrowLeft) may be held
      sendMoveFromKeys();
    }
  });
  window.addEventListener('blur', releaseKeys);
  Godot.guard(releaseKeys);

  // ---------- settings inside the pause card ----------
  const segDifficulty = $('seg-difficulty');
  segDifficulty.querySelectorAll('button').forEach((b) =>
    b.addEventListener('click', () => Godot.emit('settings_changed', { difficulty: b.dataset.value })));
  $('btn-sfx').addEventListener('click', () => Godot.emit('settings_changed', { sfx: $('btn-sfx').getAttribute('aria-pressed') !== 'true' }));

  // ---------- Godot -> HTML: showcase moments ----------
  // A seed pickup pings a small light from where it happened toward the counter (transform-only).
  Godot.onEvent('seed_collected', (e) => {
    const dot = document.createElement('div');
    dot.className = 'seedfly';
    dot.style.left = (e.x * window.innerWidth) + 'px';
    dot.style.top = (e.y * window.innerHeight) + 'px';
    document.body.appendChild(dot);
    dot.addEventListener('animationend', () => dot.remove());
  });

  // The last seed: a banner moment, then a quiet nudge at the right edge while the gate is open.
  Godot.onEvent('gate_awake', () => {
    const awake = $('awake');
    awake.hidden = false;
    awake.classList.remove('show');
    void awake.offsetWidth;
    awake.classList.add('show');
    document.body.classList.add('gate-open');
    setTimeout(() => { awake.hidden = true; }, 2800);
  });

  // Entering the gate: a warm full-screen breath before the results arrive.
  Godot.onEvent('victory', () => {
    const flash = $('flash');
    flash.classList.remove('show');
    void flash.offsetWidth;
    flash.classList.add('show');
    document.body.classList.remove('gate-open');
  });

  // ---------- Godot -> HTML ----------
  const vignette = $('vignette');
  const pips = [...$('hp').children];
  const flarePips = [...$('flare-pips').children];
  let prevHealth = null;
  let wasDead = false;
  let prevShards = null;
  let lastTimeSec = -1;
  let toastShown = false;
  let wasFinished = false;

  Godot.on('settings', (s) => {
    reveal();
    $('btn-sfx').setAttribute('aria-pressed', String(s.sfx));
    $('btn-sfx').textContent = s.sfx ? 'On' : 'Off';
    segDifficulty.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.value === s.difficulty));
    $('debug').hidden = !s.show_debug;
  });

  Godot.on('state', (s) => {
    reveal();

    // Glimmers
    if (s.shards !== prevShards) {
      $('glow-n').textContent = s.shards;
      $('glow-total').textContent = s.shards_total;
      if (prevShards !== null) {
        const chip = $('glow');
        chip.classList.remove('pop');
        void chip.offsetWidth;
        chip.classList.add('pop');
      }
      prevShards = s.shards;
    }

    // Health pips: one pip per fifth of the bar.
    const lit = Math.ceil(s.health / (s.max_health / pips.length));
    pips.forEach((pip, i) => pip.classList.toggle('off', i >= lit));
    vignette.classList.toggle('low', !s.dead && s.health <= s.max_health * 0.3);

    // Timer (updates once per second; the page does no timing itself).
    if (s.time_sec !== lastTimeSec && s.time_sec >= 0 && !s.finished) {
      lastTimeSec = s.time_sec;
      $('timer').textContent = `${Math.floor(s.time_sec / 60)}:${String(s.time_sec % 60).padStart(2, '0')}`;
    }

    // Flare charges.
    flarePips.forEach((pip, i) => pip.classList.toggle('on', i < s.flares || (i === s.flares && s.flare_k >= 0.95)));
    $('btn-flare').classList.toggle('empty', s.flares === 0);

    // Overlays.
    if (s.dead !== wasDead) { $('ko').hidden = !s.dead; wasDead = s.dead; }
    // The results card follows Godot's `finished` flag: Restart reuses this page (nothing reloads), so a card
    // left over from the last run must go as soon as the new run reports finished = false.
    $('results').hidden = !s.finished;
    if (wasFinished && !s.finished) {
      toastShown = false;  // a new run: show the objective toast again
      lastTimeSec = -1;
      prevShards = null;
    }
    wasFinished = s.finished;
    $('pause').hidden = !s.paused || s.finished;
    document.body.classList.toggle('gate-open', s.gate_open && !s.finished);

    // Objective toast: once per page load, when the run begins.
    if (!toastShown && !s.paused && !s.finished) {
      toastShown = true;
      $('toast-kicker').textContent = s.level_name.toUpperCase();
      const t = $('toast');
      t.classList.remove('show');
      void t.offsetWidth;
      t.classList.add('show');
    }

    if (s.show_debug) $('debug-line').textContent = `hits ${s.hits} · gate ${s.gate_open ? 'open' : 'sealed'}`;
  });

  Godot.on('results', (r) => {
    $('results-kicker').textContent = r.level_name.toUpperCase();
    $('r-verdict').textContent = r.verdict || '';
    $('r-best').textContent = r.new_best ? `New best time — ${r.best}` : `Best: ${r.best}`;
    $('r-best').classList.toggle('newbest', r.new_best);
    $('btn-next').textContent = `Next: ${r.next_name}`;
    $('results').hidden = false;
    $('pause').hidden = true;
    countUp($('r-time'), r.time_sec || 0, (v) => fmtTime(v));
    countUp($('r-glims'), r.shards || 0, (v) => `${Math.round(v)}/${r.shards_total}`);
    countUp($('r-hits'), r.hits || 0, (v) => `${Math.round(v)}`);
  });

  // Brief count-up animation for the results numbers (stops after 0.7 s; rAF only while running).
  function countUp(el, to, format) {
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 700);
      el.textContent = format(to * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  function fmtTime(seconds) {
    return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}.${Math.floor((seconds % 1) * 10)}`;
  }
})();
