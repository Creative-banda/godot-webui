// Completion screen: final record + run stats from Godot state.
(() => {
  const $ = (id) => document.getElementById(id);
  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  function fmtTime(seconds) {
    return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
  }

  Godot.onState('world', (w) => {
    reveal();
    $('s-time').textContent = fmtTime(w.elapsed || 0);
    $('s-clues').textContent = String(w.clues || 0);
  });

  $('btn-replay').addEventListener('click', () => Godot.emit('restart'));
  $('btn-menu').addEventListener('click', () => Godot.emit('to_menu'));
})();
