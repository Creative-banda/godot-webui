// Screens: which layer is up (Godot says which), the settings panel, the record card, the results reveal and the
// Android Back button. Godot owns every value shown here; the page only asks for changes and shows the answer.
(() => {
  const { $, emit, fmt, fmtShort } = SB;

  // ---------- which screen
  function applyScreen(s) {
    const was = SB.screen;
    SB.screen = s.name;
    document.body.dataset.screen = s.name;
    $('menu').hidden = s.name !== 'menu';
    $('hud').hidden = !(s.name === 'play' || s.name === 'pause');
    $('look-zone').hidden = s.name !== 'play';
    $('pause').hidden = s.name !== 'pause';
    $('results').hidden = s.name !== 'results';
    if (s.name === 'play' && was !== 'play' && was !== 'pause') SB.resetHud();
    if (s.name === 'pause') {
      const h = SB.lastHud;
      $('pause-line').textContent = h
        ? `Section ${h.section}/5 · ${h.shards}/${h.shard_total} shards · ${h.deaths} falls · ${fmt(h.time)}`
        : '';
    }
    if (s.name !== 'pause' && s.name !== 'menu') closePanel();
    if (s.name === 'results') revealResults();
  }
  Godot.onState('screen', applyScreen);

  // ---------- panels on top of a screen (settings, how to play)
  function openPanel(name) {
    closePanel();
    SB.panel = name;
    $(name).hidden = false;
  }

  function closePanel() {
    if (!SB.panel) return;
    $(SB.panel).hidden = true;
    SB.panel = '';
  }

  // Escape: close a panel, else pause or resume.
  SB.escape = () => {
    if (SB.panel) closePanel();
    else if (SB.screen === 'play') emit('pause');
    else if (SB.screen === 'pause') emit('resume');
  };

  // Android Back: a panel first, otherwise Godot decides (pause, resume, menu, quit).
  Godot.onBack(() => {
    if (!SB.panel) return false;
    closePanel();
    return true;
  });

  // ---------- buttons
  const on = (id, fn) => $(id).addEventListener('click', fn);
  on('btn-play', () => emit('start_run'));
  on('btn-howto', () => openPanel('howto'));
  on('btn-settings', () => openPanel('settings'));
  on('btn-quit', () => emit('quit'));
  on('btn-pause', () => emit('pause'));
  on('btn-resume', () => emit('resume'));
  on('btn-retry', () => emit('retry_checkpoint'));
  on('btn-restart', () => emit('restart_run'));
  on('btn-pause-settings', () => openPanel('settings'));
  on('btn-pause-menu', () => emit('to_menu'));
  on('btn-res-retry', () => emit('restart_run'));
  on('btn-res-menu', () => emit('to_menu'));
  on('btn-settings-back', closePanel);
  on('btn-howto-back', closePanel);

  // ---------- settings
  const sliders = {
    sensitivity: { el: $('set-sensitivity'), out: $('out-sensitivity'), text: (v) => `${Number(v).toFixed(1)}x` },
    fov: { el: $('set-fov'), out: $('out-fov'), text: (v) => String(Math.round(v)) },
  };
  const toggles = ['invert_y', 'auto_sprint', 'head_bob', 'speed_lines', 'show_fps'];
  let dragging = '';

  for (const [key, s] of Object.entries(sliders)) {
    s.el.addEventListener('pointerdown', () => { dragging = key; });
    for (const type of ['pointerup', 'pointercancel']) s.el.addEventListener(type, () => { dragging = ''; });
    s.el.addEventListener('input', () => {
      s.out.textContent = s.text(s.el.value);
      emit('settings_changed', { [key]: Number(s.el.value) });
    });
  }
  for (const key of toggles) {
    $(`tg-${key}`).addEventListener('click', () => {
      emit('settings_changed', { [key]: !SB.settings[key] });
    });
  }

  Godot.onState('settings', (s) => {
    SB.settings = s;
    for (const [key, slider] of Object.entries(sliders)) {
      if (dragging !== key) slider.el.value = s[key];
      slider.out.textContent = slider.text(s[key]);
    }
    for (const key of toggles) {
      const button = $(`tg-${key}`);
      button.setAttribute('aria-pressed', String(s[key]));
      button.textContent = s[key] ? 'On' : 'Off';
    }
  });

  // ---------- the record card and the menu's start button
  Godot.onState('profile', (p) => {
    SB.profile = p;
    const [gold, silver, bronze] = p.medal_times;
    $('medal-gold-time').textContent = fmtShort(gold);
    $('medal-silver-time').textContent = fmtShort(silver);
    $('medal-bronze-time').textContent = fmtShort(bronze);
    const order = ['gold', 'silver', 'bronze'];
    const reached = order.indexOf(p.best_medal);
    order.forEach((name, i) => $(`medal-${name}`).classList.toggle('earned', reached >= 0 && i >= reached));
    $('stat-best').textContent = fmt(p.best_time);
    $('stat-shards').textContent = `${p.best_shards}/${p.shard_total}`;
    $('stat-runs').textContent = p.plays;
    $('best-line').textContent = p.best_time >= 0
      ? `Best ${fmt(p.best_time)}${p.best_medal !== 'none' ? ' · ' + p.best_medal : ''}`
      : 'No finish yet. Reach the beacon.';
  });

  // Development switch (Godot argument --sb-touch): show the touch controls in the desktop preview.
  Godot.onState('dev', (d) => document.body.classList.toggle('touch', !!d.touch));

  // ---------- results
  let results = null;
  Godot.onState('results', (r) => { results = r; });

  function revealResults() {
    if (!results) return;
    const r = results;
    const medal = $('res-medal');
    medal.className = r.medal;
    $('res-medal-name').textContent = r.medal === 'none' ? 'No medal' : `${r.medal} medal`;
    medal.style.animation = 'none';  // replay the medal animation
    void medal.offsetWidth;
    medal.style.animation = '';
    $('res-shards').textContent = `${r.shards}/${r.shards_total}`;
    $('res-deaths').textContent = r.deaths;
    $('res-best').textContent = fmt(r.best_time);
    $('res-badge').hidden = !r.new_best;
    $('res-perfect').hidden = !r.perfect;
    const [gold, silver, bronze] = r.medal_times;
    $('res-best-line').textContent = r.medal === 'gold'
      ? `Gold needs ${fmtShort(gold)}: you beat it.`
      : `Next medal: ${r.medal === 'silver' ? 'gold ' + fmtShort(gold) : r.medal === 'bronze' ? 'silver ' + fmtShort(silver) : 'bronze ' + fmtShort(bronze)}`;
    countUp($('res-time'), r.time);
  }

  // The time counts up to its value in 0.9 s (requestAnimationFrame only while it runs).
  function countUp(el, to) {
    const t0 = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - t0) / 900);
      el.textContent = fmt(to * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }
})();
