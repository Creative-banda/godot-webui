// Menu logic: navigation and presentation. Godot owns settings, stats and the game.
(() => {
  const $ = (id) => document.getElementById(id);

  // ---------- page lifecycle ----------
  // The page loads with body.loading (hidden by the loader cover) and fades in when the first
  // state arrives; Godot re-hides it with an "app_loading" event while it swaps scenes.
  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  // ---------- browser-side navigation ----------
  const screens = [...document.querySelectorAll('.screen')];
  function show(name) {
    screens.forEach((s) => s.classList.toggle('active', s.id === 'screen-' + name));
    Godot.emit('menu_screen', { name });  // Godot uses this to scope its Enter-key fallback
  }
  document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => show(b.dataset.goto)));

  // Android Back: leave a sub-screen first. On the main screen the page declines and Godot quits.
  Godot.onBack(() => {
    if ($('screen-main').classList.contains('active')) return false;
    show('main');
    return true;
  });

  // ---------- HTML -> Godot (intent only)
  $('btn-play').addEventListener('click', () => Godot.emit('menu_play', { level: 1 }));
  $('btn-play-3d').addEventListener('click', () => Godot.emit('menu_play_3d'));
  $('btn-bench').addEventListener('click', () => Godot.emit('menu_bench'));
  $('btn-quit').addEventListener('click', () => Godot.emit('menu_quit'));
  $('btn-settings').addEventListener('click', () => show('settings'));
  $('btn-about').addEventListener('click', () => show('about'));

  // Desktop preview convenience: Enter or Space begins the run from the main screen.
  window.addEventListener('keydown', (e) => {
    if ((e.code === 'Enter' || e.code === 'Space') && $('screen-main').classList.contains('active')) {
      Godot.emit('menu_play', { level: 1 });
      e.preventDefault();
    }
  });

  // Settings: send only the change; controls are redrawn from Godot's reply.
  $('set-sfx').addEventListener('click', () => Godot.emit('settings_changed', { sfx: $('set-sfx').getAttribute('aria-pressed') !== 'true' }));
  $('set-debug').addEventListener('click', () => Godot.emit('settings_changed', { show_debug: $('set-debug').getAttribute('aria-pressed') !== 'true' }));
  document.querySelectorAll('#set-difficulty button').forEach((b) =>
    b.addEventListener('click', () => Godot.emit('settings_changed', { difficulty: b.dataset.value })));

  // Text entry: the keyboard-aware editor keeps the field visible above the Android keyboard.
  // The chip never opens the IME itself; confirming sends the change through the bridge and the
  // value comes back from Godot (drawn in the settings handler below).
  Godot.editText.attach($('set-name'), {
    title: 'KEEPER NAME', placeholder: 'Your name', maxLength: 16,
    onConfirm: (v) => Godot.emit('settings_changed', { player_name: v }),
  });
  Godot.editText.attach($('set-note'), {
    title: 'GROVE NOTE', placeholder: 'A note for your next run', mode: 'multiline', maxLength: 120,
    onConfirm: (v) => Godot.emit('settings_changed', { grove_note: v }),
  });

  // ---------- Godot -> HTML ----------
  Godot.on('settings', (s) => {
    reveal();
    $('set-sfx').setAttribute('aria-pressed', String(s.sfx));
    $('set-sfx').textContent = s.sfx ? 'On' : 'Off';
    $('set-debug').setAttribute('aria-pressed', String(s.show_debug));
    $('set-debug').textContent = s.show_debug ? 'On' : 'Off';
    $('set-name').textContent = s.player_name || 'Keeper';
    $('set-note').textContent = s.grove_note || '—';
    document.querySelectorAll('#set-difficulty button').forEach((b) =>
      b.classList.toggle('on', b.dataset.value === s.difficulty));
  });

  Godot.on('records', (r) => {
    $('best-line').textContent = r.best_1 ? `Best in the Hollow — ${r.best_1}` : 'A quiet walk through the grove';
  });

  Godot.on('info', (i) => {
    reveal();
    $('ab-engine').textContent = `Godot ${i.engine.split(' ')[0]} · ${i.os}`;
  });
})();
