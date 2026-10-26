// HUD rendering: everything below is drawn from what Godot sends. The 3D markers are the showcase: Godot projects
// world positions to screen fractions and the page places ordinary DOM elements on them.
(() => {
  const { $, fmt, restart } = SB;

  const EDGE_MARGIN = 38;      // px kept free around off-screen markers
  const markerEls = new Map();
  let shardsShown = -1;
  let deathsShown = -1;
  let wingsShown = '';
  let sprintShown = null;
  let countdownTimer = 0;

  SB.lastHud = null;

  function marker(kind) {
    let el = markerEls.get(kind);
    if (!el) {
      el = document.createElement('div');
      el.className = 'marker ' + kind;
      el.innerHTML = '<div class="pin"><i class="gem"></i><b></b><small></small></div>';
      $('markers').appendChild(el);
      markerEls.set(kind, el);
    }
    return el;
  }

  function placeMarkers(list) {
    const seen = new Set();
    const w = window.innerWidth;
    const h = window.innerHeight;
    for (const m of list) {
      seen.add(m.kind);
      const el = marker(m.kind);
      let px = m.x * w;
      let py = m.y * h;
      const off = m.behind || px < EDGE_MARGIN || px > w - EDGE_MARGIN || py < EDGE_MARGIN * 1.6 || py > h - EDGE_MARGIN * 1.6;
      if (off) {
        const cx = w / 2;
        const cy = h / 2;
        const dx = (m.behind ? (m.x - 0.5) * w : px - cx) || 0.001;
        const dy = (m.behind ? h : py - cy) || 0.001;
        const k = Math.min((cx - EDGE_MARGIN) / Math.abs(dx), (cy - EDGE_MARGIN * 1.6) / Math.abs(dy));
        px = cx + dx * k;
        py = cy + dy * k;
      }
      el.classList.toggle('edge', off);
      el.style.transform = `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px)`;
      el.querySelector('b').textContent = m.label;
      el.querySelector('small').textContent = `${m.dist} m`;
      el.hidden = false;
    }
    for (const [kind, el] of markerEls) {
      if (!seen.has(kind)) el.hidden = true;
    }
  }

  Godot.onState('hud', (s) => {
    SB.lastHud = s;
    $('timer').textContent = fmt(s.time);
    $('section-n').textContent = `${s.section}/5`;
    $('section-name').textContent = s.section_name;
    $('shard-total').textContent = `/ ${s.shard_total}`;

    if (s.shards !== shardsShown) {
      $('shard-count').textContent = s.shards;
      if (shardsShown >= 0 && s.shards > shardsShown) restart($('chip-shards'), 'pop');
      shardsShown = s.shards;
    }
    if (s.deaths !== deathsShown) {
      $('death-count').textContent = s.deaths;
      if (deathsShown >= 0 && s.deaths > deathsShown) restart($('chip-deaths'), 'pop');
      deathsShown = s.deaths;
    }

    // Sprint is the controller's own state, not a guess from speed. It opens the crosshair, shows a small chevron
    // and brings in light speed lines (opacity only: the layers are static).
    if (s.sprinting !== sprintShown) {
      sprintShown = s.sprinting;
      $('crosshair').classList.toggle('sprint', s.sprinting);
      $('sprint-ind').classList.toggle('on', s.sprinting);
      $('speedlines').classList.toggle('on', s.sprinting && SB.settings.speed_lines !== false);
    }
    $('crosshair').classList.toggle('air', s.air);

    // Double jump: icon after the Wing Orb, bright while the extra jump is available, dim once spent.
    const wings = !s.wings ? 'locked' : (s.air_jump ? 'ready' : 'spent');
    if (wings !== wingsShown) {
      wingsShown = wings;
      $('chip-wings').hidden = wings === 'locked';
      $('chip-wings').classList.toggle('ready', wings === 'ready');
      $('btn-jump').classList.toggle('air-ready', wings === 'ready' && s.air);
    }
    $('btn-jump').classList.toggle('air-ready', wings === 'ready' && s.air);

    $('fps-chip').hidden = !SB.settings.show_fps;
    if (SB.settings.show_fps) $('fps-num').textContent = s.fps;
    placeMarkers(s.markers || []);
  });

  // ---------- one-shot events
  Godot.onEvent('countdown', (e) => {
    const box = $('countdown');
    const num = $('count-num');
    clearTimeout(countdownTimer);
    box.hidden = false;
    num.textContent = e.n > 0 ? String(e.n) : 'GO';
    restart(num, 'pop');
    if (e.n === 0) countdownTimer = setTimeout(() => { box.hidden = true; }, 850);
  });

  Godot.onEvent('section', (e) => {
    $('banner-kicker').textContent = `SECTION ${e.number} OF ${e.total}`;
    $('banner-name').textContent = e.name;
    restart($('banner'), 'show');
  });

  Godot.onEvent('toast', (e) => {
    const box = $('toasts');
    const el = document.createElement('div');
    el.className = `toast glass ${e.kind || ''}`;
    const text = document.createElement('span');
    text.textContent = e.text;
    el.appendChild(text);
    if (e.hint) {
      const hint = document.createElement('small');
      hint.textContent = e.hint;
      el.appendChild(hint);
    }
    box.appendChild(el);
    el.addEventListener('animationend', () => el.remove());
    while (box.children.length > 3) box.firstChild.remove();
  });

  Godot.onEvent('respawn', () => {
    const flash = $('flash');
    flash.className = 'red';
    restart(flash, 'show');
  });

  Godot.onEvent('finish', () => {
    const flash = $('flash');
    flash.className = 'gold';
    restart(flash, 'show');
  });

  // A new run starts from zero: forget what was shown so the counters do not pop.
  SB.resetHud = () => {
    shardsShown = -1;
    deathsShown = -1;
    $('countdown').hidden = true;
    $('toasts').replaceChildren();
    for (const el of markerEls.values()) el.hidden = true;
  };
})();
