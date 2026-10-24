// HUD logic: presentation and input capture only. Godot owns the movement, the camera and its settings.
(() => {
  const $ = (id) => document.getElementById(id);

  // Only elements marked data-webui-touch take touches. The look zone covers the whole screen.
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

  // ---------- camera look: a swipe anywhere on the look zone (under the controls), one finger at a time.
  // It lives in the page so it keeps working while another finger holds the stick: on Android a second
  // finger is handed to the WebView, not to Godot, once the first one is on a page control.
  const lookZone = $('look-zone');
  let lookPointer = null;
  let lastX = 0;
  let lastY = 0;
  let pendingX = 0;
  let pendingY = 0;
  let flushQueued = false;

  function flushLook() {
    flushQueued = false;
    if (pendingX === 0 && pendingY === 0) return;
    const h = window.innerHeight;  // fractions of the screen height: independent of the screen size
    Godot.emit('look_drag', { dx: pendingX / h, dy: pendingY / h });
    pendingX = 0;
    pendingY = 0;
  }

  function releaseLook() {
    if (lookPointer === null) return;
    flushLook();
    lookPointer = null;
    Godot.emit('look_active', { active: false });
  }

  lookZone.addEventListener('pointerdown', (e) => {
    if (lookPointer !== null) return;
    lookPointer = e.pointerId;
    lookZone.setPointerCapture(e.pointerId);
    lastX = e.clientX;
    lastY = e.clientY;
    Godot.emit('look_active', { active: true });
  });
  lookZone.addEventListener('pointermove', (e) => {
    if (e.pointerId !== lookPointer) return;
    pendingX += e.clientX - lastX;
    pendingY += e.clientY - lastY;
    lastX = e.clientX;
    lastY = e.clientY;
    if (!flushQueued) {
      flushQueued = true;
      requestAnimationFrame(flushLook);
    }
  });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    lookZone.addEventListener(type, (e) => { if (e.pointerId === lookPointer) releaseLook(); });
  }
  Godot.guard(releaseLook);

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

  // Android Back: close the camera panel first; otherwise Godot goes back to the menu.
  Godot.onBack(() => {
    if (panel.hidden) return false;
    panel.hidden = true;
    return true;
  });

  document.addEventListener('contextmenu', (e) => e.preventDefault());

  // ---------- Godot -> HTML
  // Page lifecycle: the page loads hidden (body.loading, see hud3d.css) and fades in on the first
  // state; Godot re-hides it with an "app_loading" event while it swaps scenes.
  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  Godot.onState('camera', (s) => {
    reveal();
    if (document.activeElement !== slider) slider.value = s.sensitivity;
    $('sens-value').textContent = s.sensitivity.toFixed(1) + 'x';
    $('btn-menu').hidden = !s.can_exit;
    for (const [key, el] of Object.entries(toggles)) el.setAttribute('aria-pressed', String(s[key]));
  });

  let swiped = false;
  Godot.onState('telemetry', (s) => {
    reveal();
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
