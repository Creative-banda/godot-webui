// HUD logic: presentation and input capture only. Godot owns the movement, the camera and its settings.
(() => {
  const $ = (id) => document.getElementById(id);

  // Only elements marked data-webui-touch take touches; everything else reaches Godot (camera swipe).
  Godot.touchRegions();

  // ---------- virtual joystick: one pointer, pointer capture, always released
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
    let x = dx / radius;
    let y = dy / radius;
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

  // ---------- jump button: its own pointer, so it works together with the stick
  const jump = $('btn-jump');
  let jumpPointer = null;
  function releaseJump() {
    jumpPointer = null;
    jump.classList.remove('down');
  }
  jump.addEventListener('pointerdown', (e) => {
    if (jumpPointer !== null) return;
    jumpPointer = e.pointerId;
    jump.setPointerCapture(e.pointerId);
    jump.classList.add('down');
    Godot.emit('jump');
  });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    jump.addEventListener(type, (e) => { if (e.pointerId === jumpPointer) releaseJump(); });
  }
  Godot.guard(releaseJump);

  // ---------- tell Godot while a control of this page owns a pointer (desktop preview does not emulate
  // pass-through, so without this a click on the stick would also turn the camera)
  const owned = new Set();
  let busySent = false;
  function syncBusy() {
    const busy = owned.size > 0;
    if (busy === busySent) return;
    busySent = busy;
    Godot.emit('ui_busy', { busy });
  }
  document.addEventListener('pointerdown', (e) => {
    if (e.target.closest && e.target.closest('[data-webui-touch]')) { owned.add(e.pointerId); syncBusy(); }
  }, true);
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    window.addEventListener(type, (e) => { if (owned.delete(e.pointerId)) syncBusy(); }, true);
  }
  Godot.guard(() => { owned.clear(); syncBusy(); });

  // ---------- keyboard (desktop preview): the WebView can hold the keyboard focus, so forward the keys
  const KEYS = { KeyW: 'up', ArrowUp: 'up', KeyS: 'down', ArrowDown: 'down', KeyA: 'left', ArrowLeft: 'left', KeyD: 'right', ArrowRight: 'right' };
  const held = new Set();
  let sentKeys = '';

  function sendKeys() {
    const state = { up: false, down: false, left: false, right: false };
    for (const name of held) state[name] = true;
    const json = JSON.stringify(state);
    if (json === sentKeys) return;
    sentKeys = json;
    Godot.emit('keys_changed', state);
  }

  function releaseKeys() {
    held.clear();
    sendKeys();
  }

  window.addEventListener('keydown', (e) => {
    if (e.code === 'Space') {
      if (!e.repeat) Godot.emit('jump');
      e.preventDefault();
    } else if (KEYS[e.code]) {
      held.add(KEYS[e.code]);
      sendKeys();
      e.preventDefault();
    }
  });
  window.addEventListener('keyup', (e) => {
    if (KEYS[e.code]) {
      // Both keys of a pair (W and ArrowUp) can be held; recompute from what is still down.
      held.delete(KEYS[e.code]);
      sendKeys();
    }
  });
  window.addEventListener('blur', releaseKeys);
  Godot.guard(releaseKeys);

  // ---------- camera settings: the page asks, Godot validates and echoes the result back
  const panel = $('camera-panel');
  const slider = $('sensitivity');
  const toggles = { invert_x: $('invert-x'), invert_y: $('invert-y') };

  $('btn-menu').addEventListener('click', () => Godot.emit('back_to_menu'));
  $('btn-camera').addEventListener('click', () => { panel.hidden = !panel.hidden; });
  slider.addEventListener('input', () => {
    $('sens-value').textContent = Number(slider.value).toFixed(1) + 'x';
    Godot.emit('camera_settings', { sensitivity: Number(slider.value) });
  });
  for (const [key, el] of Object.entries(toggles)) {
    el.addEventListener('click', () => {
      Godot.emit('camera_settings', { [key]: el.getAttribute('aria-pressed') !== 'true' });
    });
  }

  document.addEventListener('contextmenu', (e) => e.preventDefault());

  // ---------- Godot -> HTML
  Godot.onState('camera', (s) => {
    if (document.activeElement !== slider) slider.value = s.sensitivity;
    $('sens-value').textContent = s.sensitivity.toFixed(1) + 'x';
    $('btn-menu').hidden = !s.can_exit;
    for (const [key, el] of Object.entries(toggles)) el.setAttribute('aria-pressed', String(s[key]));
  });

  let swiped = false;
  Godot.onState('telemetry', (s) => {
    $('t-swipe').textContent = s.swiping ? 'swiping' : 'idle';
    $('t-swipe').classList.toggle('on', s.swiping);
    $('t-yaw').textContent = s.yaw + '°';
    $('t-pitch').textContent = s.pitch + '°';
    $('t-speed').textContent = s.speed.toFixed(1) + ' m/s';
    $('t-floor').textContent = s.on_floor ? 'yes' : 'air';
    $('t-fps').textContent = s.fps;
    if (s.swiping && !swiped) {
      swiped = true;
      $('hint').classList.add('gone');
    }
  });
})();
