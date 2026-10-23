// Presentation and input only. Godot owns coins, damage and health.
(() => {
  const $ = (id) => document.getElementById(id);

  // Opt in to touch pass-through: only [data-webui-touch] elements take touches.
  Godot.touchRegions();

  // HTML -> Godot: send intent. Godot validates it and decides what happens.
  $('attack').addEventListener('click', () => Godot.emit('attack', { heavy: false }));
  $('heavy').addEventListener('click', () => Godot.emit('attack', { heavy: true }));
  $('repair').addEventListener('click', () => Godot.emit('repair'));

  // Godot -> HTML, persistent state: also delivered to us at once if it already arrived, and
  // resent by Godot after every page (re)load.
  Godot.onState('hud', (s) => {
    $('coins').textContent = s.coins;
    $('hp-fill').style.width = (s.dummy_hp / s.dummy_max * 100) + '%';
    $('hp-text').textContent = `Dummy ${s.dummy_hp} / ${s.dummy_max}`;
  });

  // Godot -> HTML, one-shot events: never replayed, so a late page does not replay old hits.
  Godot.onEvent('hit', (e) => {
    const el = document.createElement('div');
    el.className = 'floater' + (e.crit ? ' crit' : '');
    el.textContent = '-' + e.damage + (e.crit ? '!' : '');
    el.style.marginLeft = (Math.random() * 120 - 60) + 'px';
    $('floaters').appendChild(el);
    el.addEventListener('animationend', () => el.remove());
  });

  let toastTimer = 0;
  Godot.onEvent('toast', (e) => {
    $('toast').textContent = e.text;
    $('toast').hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { $('toast').hidden = true; }, 1800);
  });
})();
