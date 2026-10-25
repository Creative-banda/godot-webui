// HUD: renders Godot state, forwards player input to Godot, owns journal/pause overlays.
(() => {
  const $ = (id) => document.getElementById(id);

  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  // ---------- input forwarding ----------
  // Keyboard focus sits on the WebView, so the page forwards movement/interact/pause to Godot.
  // Clicking engages browser pointer lock where available so mouse deltas keep working at the
  // screen edges; deltas are forwarded as look events either way.
  const held = new Set();
  let locked = false;
  let open = () => false;  // overlays open?

  const MOVE_KEYS = { KeyW: 'f', ArrowUp: 'f', KeyS: 'b', ArrowDown: 'b', KeyA: 'l', ArrowLeft: 'l', KeyD: 'r', ArrowRight: 'r' };

  function sendMove() {
    const x = (held.has('r') ? 1 : 0) - (held.has('l') ? 1 : 0);
    const z = (held.has('f') ? 1 : 0) - (held.has('b') ? 1 : 0);
    Godot.emit('move', { x, z });
  }

  window.addEventListener('keydown', (e) => {
    if (open()) return;
    if (MOVE_KEYS[e.code]) {
      if (!held.has(MOVE_KEYS[e.code])) { held.add(MOVE_KEYS[e.code]); sendMove(); }
      e.preventDefault();
    } else if (e.code === 'KeyE' && !e.repeat) {
      Godot.emit('interact');
      e.preventDefault();
    } else if (e.code === 'Escape') {
      if (locked && document.exitPointerLock) document.exitPointerLock();
      Godot.emit('pause_toggle');
    } else if (e.code === 'Tab') {
      e.preventDefault();
      toggleJournal();
    }
  });

  window.addEventListener('keyup', (e) => {
    if (MOVE_KEYS[e.code] && held.has(MOVE_KEYS[e.code])) {
      held.delete(MOVE_KEYS[e.code]);
      if (!open()) sendMove();
    }
  });

  window.addEventListener('blur', () => {
    if (held.size) { held.clear(); Godot.emit('move', { x: 0, z: 0 }); }
  });
  Godot.guard(() => { held.clear(); Godot.emit('move', { x: 0, z: 0 }); });

  // Mouse look: pointer lock preferred; raw deltas forwarded as fractions of the viewport.
  let last = null;
  document.addEventListener('click', () => {
    if (open() || locked) return;
    if (document.body.requestPointerLock) {
      const p = document.body.requestPointerLock();
      if (p && p.catch) p.catch(() => {});
    }
  });
  document.addEventListener('pointerlockchange', () => {
    locked = document.pointerLockElement === document.body;
  });
  window.addEventListener('mousemove', (e) => {
    if (open()) { last = null; return; }
    if (locked) {
      Godot.emit('look', { dx: e.movementX, dy: e.movementY });
    } else if (last) {
      Godot.emit('look', { dx: e.clientX - last.x, dy: e.clientY - last.y });
    }
    last = { x: e.clientX, y: e.clientY };
  });

  // ---------- overlays ----------
  function anyOpen() {
    return $('journal').classList.contains('open') || $('pause').classList.contains('open');
  }
  open = anyOpen;

  function toggleJournal() {
    const j = $('journal');
    const willOpen = !j.classList.contains('open');
    j.classList.toggle('open', willOpen);
    if (willOpen) Godot.emit('move', { x: 0, z: 0 });
  }
  $('btn-journal').addEventListener('click', toggleJournal);
  $('btn-journal-close').addEventListener('click', toggleJournal);
  $('btn-pause').addEventListener('click', () => Godot.emit('pause_toggle'));
  $('btn-resume').addEventListener('click', () => Godot.emit('pause_toggle'));
  $('btn-restart').addEventListener('click', () => Godot.emit('restart'));
  $('btn-menu').addEventListener('click', () => Godot.emit('to_menu'));
  $('set-sens').addEventListener('input', (e) => Godot.emit('settings_changed', { sens: Number(e.target.value) }));
  $('set-vol').addEventListener('input', (e) => Godot.emit('settings_changed', { volume: Number(e.target.value) }));

  // ---------- toasts ----------
  Godot.onEvent('toast', (t) => {
    const el = document.createElement('div');
    el.className = 'toast';
    el.textContent = t.text;
    $('toasts').appendChild(el);
    setTimeout(() => el.remove(), 4000);
  });

  Godot.onEvent('journal_added', (e) => {
    $('cluecount').textContent = String(Number($('cluecount').textContent) + 1);
    renderJournal(e.id, e.title, '');
  });

  function renderJournal(id, title, text) {
    const list = $('journal-list');
    const empty = list.querySelector('.empty');
    if (empty) empty.remove();
    if (list.querySelector(`[data-id="${id}"]`)) return;
    const div = document.createElement('div');
    div.className = 'entry';
    div.dataset.id = id;
    div.innerHTML = `<div class="etitle"></div><div class="etext"></div>`;
    div.querySelector('.etitle').textContent = title;
    div.querySelector('.etext').textContent = text || '— open the journal again for the full text —';
    list.appendChild(div);
  }

  // ---------- state ----------
  const PHASES = ['trace', 'override', 'grid', 'control'];

  Godot.onState('world', (w) => {
    reveal();
    $('objective').textContent = w.objective;
    const solved = { trace: w.trace_solved, override: w.override_solved, grid: w.grid_solved, control: w.power_on };
    document.querySelectorAll('.phase').forEach((el) => {
      const p = el.dataset.p;
      el.classList.toggle('done', !!solved[p]);
      el.classList.toggle('now', p === PHASES.find((k) => !solved[k]));
    });
  });

  Godot.onState('player', (p) => {
    reveal();
    $('prompt').classList.toggle('show', !!p.prompt);
    if (p.prompt) $('prompt').innerHTML = p.prompt.replace(/^E /, '<b>E</b> ');
    $('pause').classList.toggle('open', !!p.paused);
    $('reticle').classList.toggle('active', !!p.prompt);
  });

  Godot.onState('journal', (j) => {
    $('cluecount').textContent = String(j.entries.length);
    const list = $('journal-list');
    list.innerHTML = '';
    if (!j.entries.length) {
      list.innerHTML = '<p class="empty">No findings yet. Read logs and notes with E.</p>';
      return;
    }
    for (const e of j.entries) renderJournal(e.id, e.title, e.text);
  });

  Godot.onState('settings', (s) => {
    $('set-sens').value = s.sens;
    $('set-vol').value = s.volume;
  });
})();
