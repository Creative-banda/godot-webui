// Main menu: intent only. Settings live in Godot state.
(() => {
  const $ = (id) => document.getElementById(id);

  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  $('btn-start').addEventListener('click', () => Godot.emit('menu_start'));
  $('btn-quit').addEventListener('click', () => Godot.emit('menu_quit'));
  $('btn-settings').addEventListener('click', () => $('settings').classList.toggle('open'));

  $('set-sens').addEventListener('input', (e) =>
    Godot.emit('settings_changed', { sens: Number(e.target.value) }));
  $('set-vol').addEventListener('input', (e) =>
    Godot.emit('settings_changed', { volume: Number(e.target.value) }));

  Godot.onState('settings', (s) => {
    reveal();
    $('set-sens').value = s.sens;
    $('set-vol').value = s.volume;
  });
})();
