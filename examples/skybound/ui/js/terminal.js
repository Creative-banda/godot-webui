// The in-world terminal page. Godot sends the run (state "run") and where the player is aiming (state "cursor"); a tap
// from Godot (a raycast hit mapped to page pixels) arrives as an ordinary click, and the buttons tell Godot what was asked
// ("terminal_action"). Godot validates the action and decides what happens.
(() => {
  const $ = (id) => document.getElementById(id);
  const fmt = (t) => {
    if (typeof t !== 'number' || t < 0) return '--';
    const m = Math.floor(t / 60);
    return `${m}:${(t - m * 60).toFixed(2).padStart(5, '0')}`;
  };

  const sections = [...document.querySelectorAll('#sections li')];
  const buttons = [...document.querySelectorAll('.action')];

  Godot.onState('run', (s) => {
    $('time').textContent = fmt(s.time);
    $('section-n').textContent = `${s.section}/5`;
    $('section-name').textContent = s.section_name;
    $('shards').textContent = `${s.shards} / ${s.shard_total}`;
    $('meter-fill').style.transform = `scaleX(${s.shard_total ? s.shards / s.shard_total : 0})`;
    $('falls').textContent = s.deaths;
    $('best').textContent = fmt(s.best_time);
    $('wings').textContent = s.wings ? 'ready' : 'locked';
    $('wings').classList.toggle('ready', s.wings);
    sections.forEach((li, i) => {
      li.classList.toggle('done', i + 1 < s.section);
      li.classList.toggle('now', i + 1 === s.section);
    });
  });

  // Aim cursor: Godot says where the crosshair meets the screen; the page draws it and lights the button under it.
  Godot.onState('cursor', (c) => {
    const cursor = $('cursor');
    cursor.hidden = !c.aimed;
    if (!c.aimed) {
      buttons.forEach((b) => b.classList.remove('hover'));
      return;
    }
    cursor.style.transform = `translate(${c.x}px, ${c.y}px)`;
    const under = document.elementFromPoint(c.x, c.y);
    buttons.forEach((b) => b.classList.toggle('hover', b === under || b.contains(under)));
  });

  const press = (button, action) => {
    button.addEventListener('click', () => {
      button.classList.add('pressed');
      setTimeout(() => button.classList.remove('pressed'), 160);
      Godot.emit('terminal_action', { action });
    });
  };
  press($('btn-retry'), 'retry');
  press($('btn-restart'), 'restart');

  // A small clock, to show the page runs by itself between Godot updates.
  const tick = () => {
    const d = new Date();
    $('clock').textContent = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  };
  tick();
  setInterval(tick, 5000);
})();
