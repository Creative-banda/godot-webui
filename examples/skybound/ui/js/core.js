// Shared helpers for the Skybound page. Godot owns the game; this page only sends intent and draws what
// it is told. The other scripts (input, hud, screens) hang their pieces off window.SB.
(() => {
  const $ = (id) => document.getElementById(id);

  const SB = {
    $,
    settings: {},
    profile: {},
    screen: 'menu',
    panel: '',
    // Touch controls on phones; keyboard and mouse hints in the desktop preview (unless it has a touch screen).
    touch: !Godot.preview || navigator.maxTouchPoints > 0,

    emit(name, payload) { Godot.emit(name, payload); },

    // 0:00.00, or "--" when there is no time yet.
    fmt(seconds) {
      if (typeof seconds !== 'number' || seconds < 0) return '--';
      const m = Math.floor(seconds / 60);
      const s = seconds - m * 60;
      return `${m}:${s.toFixed(2).padStart(5, '0')}`;
    },

    // Whole seconds for the medal thresholds: 150 -> 2:30.
    fmtShort(seconds) {
      const m = Math.floor(seconds / 60);
      return `${m}:${String(Math.round(seconds - m * 60)).padStart(2, '0')}`;
    },

    // Plays a CSS animation again by removing its class, forcing a reflow and adding it back.
    restart(el, cls) {
      el.classList.remove(cls);
      void el.offsetWidth;
      el.classList.add(cls);
    },
  };

  document.body.classList.toggle('touch', SB.touch);
  window.SB = SB;

  // Only elements marked data-webui-touch take touches; every other touch reaches Godot.
  Godot.touchRegions();
  document.addEventListener('contextmenu', (e) => e.preventDefault());
})();
