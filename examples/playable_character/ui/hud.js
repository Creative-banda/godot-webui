// HUD logic: presentation and input capture only. All gameplay happens in Godot.
(() => {
  const $ = (id) => document.getElementById(id);

  // Only the elements marked data-webui-touch receive touches; everything else reaches the game.
  Godot.touchRegions();

  // ---------- press ripple (purely visual)
  function ripple(el, e) {
    const r = el.getBoundingClientRect();
    const size = Math.max(r.width, r.height) * 2;
    const dot = document.createElement('span');
    dot.className = 'ripple';
    dot.style.cssText = `width:${size}px;height:${size}px;left:${e.clientX - r.left - size / 2}px;top:${e.clientY - r.top - size / 2}px`;
    el.appendChild(dot);
    dot.addEventListener('animationend', () => dot.remove());
  }

  // ---------- virtual joystick (one pointer, pointer capture, always releases)
  const zone = $('stick-zone');
  const stick = $('stick');
  const knob = $('knob');
  const arrows = { u: stick.querySelector('.u'), d: stick.querySelector('.d'), l: stick.querySelector('.l'), r: stick.querySelector('.r') };
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
    stick.style.setProperty('--mag', Math.min(1, Math.hypot(x, y)).toFixed(2));
    arrows.l.classList.toggle('on', x < -0.4);
    arrows.r.classList.toggle('on', x > 0.4);
    arrows.u.classList.toggle('on', y < -0.4);
    arrows.d.classList.toggle('on', y > 0.4);
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
      if (el.classList.contains('fx')) ripple(el, e);
      onDown();
    });
    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      el.addEventListener(type, (e) => { if (e.pointerId === pointer) up(); });
    }
    Godot.guard(up);
  }

  holdButton($('btn-jump'), () => Godot.emit('jump'));
  holdButton($('btn-attack'),
    () => Godot.emit('attack_pressed'),
    () => Godot.emit('attack_released'));
  holdButton($('btn-damage'), () => Godot.emit('damage_self'));
  holdButton($('btn-pause'), () => Godot.emit('pause_toggle'));
  holdButton($('btn-resume'), () => Godot.emit('pause_toggle'));
  holdButton($('btn-menu'), () => Godot.emit('back_to_menu'));

  document.addEventListener('contextmenu', (e) => e.preventDefault());

  // ---------- Godot -> HTML
  const vitals = $('vitals');
  let prevHealth = null;
  let shownHealth = null;
  let tween = 0;
  let toastLevel = null;
  let wasDead = false;

  function setHealthText(value, max) { $('hp-text').textContent = `${Math.round(value)} / ${max}`; }

  function tweenHealth(to, max) {
    cancelAnimationFrame(tween);
    const from = shownHealth ?? to;
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 350);
      shownHealth = from + (to - from) * (1 - Math.pow(1 - k, 3));
      setHealthText(shownHealth, max);
      if (k < 1) tween = requestAnimationFrame(step);
    };
    tween = requestAnimationFrame(step);
  }

  function floater(text, kind) {
    const f = document.createElement('div');
    f.className = 'floater ' + kind;
    f.textContent = text;
    f.style.left = (Math.random() * 40) + 'px';
    $('floaters').appendChild(f);
    f.addEventListener('animationend', () => f.remove());
  }

  function showToast(text) {
    const t = $('toast');
    $('toast-text').textContent = text;
    t.classList.remove('show');
    void t.offsetWidth; // restart the animation
    t.classList.add('show');
  }

  Godot.on('settings', (s) => { $('debug').style.display = s.show_debug ? '' : 'none'; });

  Godot.on('state', (s) => {
    const pct = Math.max(0, Math.min(100, (s.health / s.max_health) * 100));
    $('hp-fill').style.width = pct + '%';
    vitals.style.setProperty('--hue', Math.round(pct * 1.35));
    $('hp-fill').style.setProperty('--hue', Math.round(pct * 1.35));
    vitals.classList.toggle('low', pct <= 30);

    if (prevHealth === null || s.health > prevHealth) {
      $('hp-trail').style.transition = 'none';
      $('hp-trail').style.width = pct + '%';
      void $('hp-trail').offsetWidth;
      $('hp-trail').style.transition = '';
      if (prevHealth !== null) floater('+' + (s.health - prevHealth), 'heal');
    } else if (s.health < prevHealth) {
      $('hp-trail').style.width = (prevHealth / s.max_health * 100) + '%';
      requestAnimationFrame(() => { $('hp-trail').style.width = pct + '%'; });
      floater('-' + (prevHealth - s.health), 'dmg');
      for (const [el, cls] of [[vitals, 'shake'], [$('vignette'), 'hit']]) {
        el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls);
      }
    }
    if (prevHealth !== s.health) tweenHealth(s.health, s.max_health);
    prevHealth = s.health;

    if (s.dead !== wasDead) { $('ko').hidden = !s.dead; wasDead = s.dead; }
    $('pause').hidden = !s.paused;
    $('level-text').textContent = `LEVEL ${s.level} · ${s.level_name.toUpperCase()} · ${s.difficulty.toUpperCase()}`;
    if (toastLevel !== s.level) { toastLevel = s.level; showToast(s.level_name); }

    $('r-pos').textContent = `${s.x}, ${s.y}`;
    $('r-vel').textContent = `${s.vx}, ${s.vy}`;
    $('r-floor').textContent = s.on_floor ? 'yes' : 'air';
    $('r-atk').textContent = s.attacking ? 'ON' : 'off';
    $('btn-attack').classList.toggle('down', s.attacking);
  });
})();
