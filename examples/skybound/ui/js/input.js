// Input: the virtual stick, the jump button, the look zone (a swipe anywhere else), and the keyboard for
// the desktop preview. Everything is sent to Godot as intent; Godot decides what happens.
(() => {
  const { $, emit } = SB;

  // ---------- stick: one pointer, pointer capture, always released
  const zone = $('stick-zone');
  const stick = $('stick');
  const knob = $('knob');
  const DEAD_ZONE = 0.12;
  let stickPointer = null;
  let sent = { x: 0, y: 0 };

  function sendMove(x, y) {
    if (x === sent.x && y === sent.y) return;
    sent = { x, y };
    emit('move_changed', { x, y });
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
    if (stickPointer === null && sent.x === 0 && sent.y === 0) return;
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

  // ---------- jump: its own pointer, so it works together with the stick; hold for height
  const jump = $('btn-jump');
  let jumpPointer = null;
  function releaseJump() {
    if (jumpPointer === null) return;
    jumpPointer = null;
    jump.classList.remove('down');
    emit('jump_released');
  }
  jump.addEventListener('pointerdown', (e) => {
    if (jumpPointer !== null) return;
    jumpPointer = e.pointerId;
    jump.setPointerCapture(e.pointerId);
    jump.classList.add('down');
    emit('jump');
  });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    jump.addEventListener(type, (e) => { if (e.pointerId === jumpPointer) releaseJump(); });
  }
  Godot.guard(releaseJump);

  // ---------- look: swipe anywhere on the look zone. It lives in the page so it keeps working while another
  // finger holds the stick (on Android a second finger goes to the WebView, not to Godot). Deltas are sent as
  // fractions of the screen height, so the feel is the same on every screen.
  const look = $('look-zone');
  let lookPointer = null;
  let lastX = 0;
  let lastY = 0;
  let pendingX = 0;
  let pendingY = 0;
  let queued = false;

  function flushLook() {
    queued = false;
    if (pendingX === 0 && pendingY === 0) return;
    const h = window.innerHeight;
    emit('look_drag', { dx: pendingX / h, dy: pendingY / h });
    pendingX = 0;
    pendingY = 0;
  }

  function releaseLook() {
    if (lookPointer === null) return;
    flushLook();
    lookPointer = null;
  }

  look.addEventListener('pointerdown', (e) => {
    if (lookPointer !== null) return;
    lookPointer = e.pointerId;
    look.setPointerCapture(e.pointerId);
    lastX = e.clientX;
    lastY = e.clientY;
  });
  look.addEventListener('pointermove', (e) => {
    if (e.pointerId !== lookPointer) return;
    pendingX += e.clientX - lastX;
    pendingY += e.clientY - lastY;
    lastX = e.clientX;
    lastY = e.clientY;
    if (!queued) {
      queued = true;
      requestAnimationFrame(flushLook);
    }
  });
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    look.addEventListener(type, (e) => { if (e.pointerId === lookPointer) releaseLook(); });
  }
  Godot.guard(releaseLook);

  // ---------- keyboard (the desktop preview: the WebView holds the focus, so it forwards the keys)
  const KEYS = { KeyW: 'up', ArrowUp: 'up', KeyS: 'down', ArrowDown: 'down', KeyA: 'left', ArrowLeft: 'left', KeyD: 'right', ArrowRight: 'right' };
  const held = new Set();
  let sentKeys = '';

  function sendKeys() {
    const state = { up: false, down: false, left: false, right: false };
    for (const name of held) state[name] = true;
    const json = JSON.stringify(state);
    if (json === sentKeys) return;
    sentKeys = json;
    emit('keys_changed', state);
  }

  function releaseKeys() {
    held.clear();
    sendKeys();
    emit('sprint', { held: false });
  }

  window.addEventListener('keydown', (e) => {
    if (e.repeat) return;
    if (e.code === 'Space') {
      if (SB.screen === 'play') emit('jump');
      e.preventDefault();
    } else if (KEYS[e.code]) {
      held.add(KEYS[e.code]);
      sendKeys();
      e.preventDefault();
    } else if (e.code === 'ShiftLeft' || e.code === 'ShiftRight') {
      emit('sprint', { held: true });
    } else if (e.code === 'Escape') {
      SB.escape();
    } else if (e.code === 'KeyR' && SB.screen === 'play') {
      emit('retry_checkpoint');
    }
  });
  window.addEventListener('keyup', (e) => {
    if (e.code === 'Space') emit('jump_released');
    if (KEYS[e.code]) {
      held.delete(KEYS[e.code]);  // both keys of a pair (W and the arrow) may be held
      sendKeys();
    }
    if (e.code === 'ShiftLeft' || e.code === 'ShiftRight') emit('sprint', { held: false });
  });
  window.addEventListener('blur', releaseKeys);
  Godot.guard(releaseKeys);
})();
