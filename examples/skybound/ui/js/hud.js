// HUD rendering: everything below is drawn from what Godot sends. The 3D markers are the showcase: Godot projects
// world positions to screen fractions and the page places ordinary DOM elements on them.
(() => {
  const { $, fmt, restart } = SB;

  const ARC_LENGTH = 126;      // matches stroke-dasharray in hud.css
  const MAX_KMH = 60;          // the gauge is full here
  const EDGE_MARGIN = 38;      // px kept free around off-screen markers
  const markerEls = new Map();
  let shardsShown = -1;
  let deathsShown = -1;
  let linesShown = 0;
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
    $('chip-wings').hidden = !s.wings;

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

    // Speed gauge and crosshair.
    const k = Math.min(1, s.speed / MAX_KMH);
    $('arc').style.strokeDashoffset = (ARC_LENGTH * (1 - k)).toFixed(1);
    $('speed-num').textContent = s.speed;
    $('speedo').classList.toggle('sprinting', s.sprint);
    $('speedo').classList.toggle('fast', s.speed > 40);
    $('crosshair').classList.toggle('sprint', s.sprint);
    $('crosshair').classList.toggle('air', s.air);

    // Speed lines fade in above sprint speed (opacity only, the layer is static).
    const lines = SB.settings.speed_lines === false ? 0 : Math.max(0, Math.min(1, (s.speed - 34) / 24)) * 0.85;
    if (Math.abs(lines - linesShown) > 0.03) {
      $('speedlines').style.opacity = lines.toFixed(2);
      linesShown = lines;
    }

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
