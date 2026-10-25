// Terminal shell: hosts the TRACE / OVERRIDE / GRID applications and the records archive.
// All puzzle data comes from Godot state; submissions go through the bridge; Godot validates.
(() => {
  const $ = (id) => document.getElementById(id);
  const app = $('app');

  Godot.onEvent('app_loading', () => document.body.classList.add('loading'));
  function reveal() { document.body.classList.remove('loading'); }

  const data = {
    trace: null, override: null, grid: null, records: null,
  };
  let current = 'trace';
  let route = [];

  // ESC closes the terminal (also wired in Godot via player fallback).
  window.addEventListener('keydown', (e) => {
    if (e.code === 'Escape') { e.preventDefault(); Godot.emit('terminal_close'); }
  });
  $('btn-close').addEventListener('click', () => Godot.emit('terminal_close'));

  document.querySelectorAll('#appnav .btn').forEach((b) =>
    b.addEventListener('click', () => showApp(b.dataset.app)));

  Godot.onEvent('terminal_open', (e) => {
    showApp(e.app || 'trace');
  });

  function showApp(name) {
    current = name;
    document.querySelectorAll('#appnav .btn').forEach((b) =>
      b.classList.toggle('active', b.dataset.app === name));
    const render = { trace: renderTrace, override: renderOverride, grid: renderGrid, records: renderRecords }[name];
    if (render) render();
  }

  function feedback(ok, msg) {
    const el = document.getElementById('feedback');
    if (!el) return;
    el.className = ok ? 'ok' : 'bad';
    el.textContent = (ok ? 'OK // ' : 'ERR // ') + msg;
  }

  Godot.onEvent('puzzle_result', (r) => {
    feedback(r.ok, r.msg);
    if (r.ok) {
      // Re-render from the fresh state Godot pushed (solved tag, glow states).
      setTimeout(() => showApp(current), 60);
    }
  });

  // ---------------- TRACE ----------------
  const NODE_POS = {
    ACCESS_REQUEST: [70, 150], GATEWAY: [255, 70], VERIFY_01: [440, 150],
    RELAY_09: [255, 235], DOOR_CONTROL: [630, 150],
  };

  function renderTrace() {
    const t = data.trace;
    if (!t) { app.innerHTML = ''; return; }
    app.innerHTML = `
      <h3>TRACE — AUTHENTICATION ROUTING${t.solved ? '<span class="solved-tag">ACTIVE</span>' : ''}</h3>
      <p class="desc">Configure the authentication route for the entrance checkpoint. Build the path by
      clicking nodes in order from ACCESS REQUEST to DOOR CONTROL.</p>
      <div id="graphwrap"><svg id="graph" viewBox="0 0 720 300" preserveAspectRatio="xMidYMid meet"></svg></div>
      <div id="route"></div>
      <div class="actions">
        <button class="btn primary" id="btn-run">RUN DIAGNOSTIC</button>
        <button class="btn" id="btn-clear">CLEAR ROUTE</button>
      </div>
      <div id="feedback">Awaiting diagnostic.</div>`;
    const svg = $('graph');
    const NS = 'http://www.w3.org/2000/svg';
    // links
    for (const [a, b] of t.links) {
      const line = document.createElementNS(NS, 'line');
      const inRoute = isLinkInRoute(a, b);
      line.setAttribute('x1', NODE_POS[a][0] + 70); line.setAttribute('y1', NODE_POS[a][1] + 22);
      line.setAttribute('x2', NODE_POS[b][0] + 70); line.setAttribute('y2', NODE_POS[b][1] + 22);
      line.setAttribute('class', 'glink' + (inRoute ? ' inroute' : ''));
      line.dataset.pair = a + '|' + b;
      svg.appendChild(line);
    }
    // nodes (clickable rects on top)
    for (const node of t.nodes) {
      const [x, y] = NODE_POS[node.id];
      const g = document.createElementNS(NS, 'g');
      g.setAttribute('class', 'gnode' + (route.includes(node.id) ? ' inroute' : ''));
      g.dataset.id = node.id;
      const rect = document.createElementNS(NS, 'rect');
      rect.setAttribute('x', x); rect.setAttribute('y', y);
      rect.setAttribute('width', 140); rect.setAttribute('height', 44);
      rect.setAttribute('rx', 8);
      const text = document.createElementNS(NS, 'text');
      text.setAttribute('x', x + 70); text.setAttribute('y', y + 27);
      text.setAttribute('text-anchor', 'middle');
      text.textContent = node.label;
      g.appendChild(rect); g.appendChild(text);
      g.addEventListener('click', () => nodeClicked(node.id));
      svg.appendChild(g);
    }
    renderRouteChips();
    $('btn-run').addEventListener('click', () => Godot.emit('trace_submit', { path: route.slice() }));
    $('btn-clear').addEventListener('click', () => { route = []; refreshTrace(); });
    if (t.solved) route = ['ACCESS_REQUEST', 'GATEWAY', 'VERIFY_01', 'DOOR_CONTROL'];
    refreshTrace();
  }

  function isLinkInRoute(a, b) {
    for (let i = 0; i < route.length - 1; i++) {
      if ((route[i] === a && route[i + 1] === b) || (route[i] === b && route[i + 1] === a)) return true;
    }
    return false;
  }

  function nodeClicked(id) {
    if (data.trace.solved) return;
    // Toggle: clicking the last node removes it; otherwise append.
    if (route.length && route[route.length - 1] === id) route.pop();
    else if (!route.includes(id)) route.push(id);
    refreshTrace();
  }

  function refreshTrace() {
    document.querySelectorAll('.gnode').forEach((g) => {
      g.classList.toggle('inroute', route.includes(g.dataset.id));
    });
    document.querySelectorAll('.glink').forEach((l) => {
      const [a, b] = l.dataset.pair.split('|');
      l.classList.toggle('inroute', isLinkInRoute(a, b));
    });
    const box = $('route');
    box.innerHTML = '';
    const labels = {};
    for (const n of (data.trace ? data.trace.nodes : [])) labels[n.id] = n.label;
    route.forEach((id, i) => {
      if (i) {
        const arrow = document.createElement('span');
        arrow.className = 'arrow'; arrow.textContent = '→';
        box.appendChild(arrow);
      }
      const chip = document.createElement('span');
      chip.className = 'rchip';
      chip.innerHTML = `<span class="idx">${i + 1}</span>`;
      chip.appendChild(document.createTextNode(labels[id] || id));
      box.appendChild(chip);
    });
    if (!route.length) {
      const hint = document.createElement('span');
      hint.className = 'empty mono';
      hint.style.cssText = 'font-size:12px;color:var(--dim)';
      hint.textContent = 'Click nodes to build the route.';
      box.appendChild(hint);
    }
  }

  // ---------------- OVERRIDE ----------------
  function renderOverride() {
    const o = data.override;
    if (!o) { app.innerHTML = ''; return; }
    app.innerHTML = `
      <h3>OVERRIDE — RECOVERY PROCEDURE${o.solved ? '<span class="solved-tag">APPROVED</span>' : ''}</h3>
      <p class="desc">The recovery procedure stages are out of order. Arrange all three stages, then run
      validation. The system will reject a sequence that violates its dependencies.</p>
      <div id="stages"></div>
      <div class="actions"><button class="btn primary" id="btn-validate">RUN VALIDATION</button></div>
      <div id="feedback">Awaiting validation.</div>`;
    renderStages(o.order);
    $('btn-validate').addEventListener('click', () =>
      Godot.emit('override_submit', { order: o.order.slice() }));
  }

  function renderStages(order) {
    const box = $('stages');
    box.innerHTML = '';
    const labels = {};
    for (const s of data.override.stages) labels[s.id] = s.label;
    order.forEach((id, i) => {
      const row = document.createElement('div');
      row.className = 'stage';
      row.innerHTML = `<span class="num">${i + 1}</span><span class="slabel"></span>
        <span class="mover">
          <button class="btn" data-d="-1" ${i === 0 ? 'disabled' : ''}>▲</button>
          <button class="btn" data-d="1" ${i === order.length - 1 ? 'disabled' : ''}>▼</button>
        </span>`;
      row.querySelector('.slabel').textContent = labels[id];
      row.querySelectorAll('.mover .btn').forEach((b) => {
        b.addEventListener('click', () => {
          const d = Number(b.dataset.d);
          const j = i + d;
          if (j < 0 || j >= order.length) return;
          [order[i], order[j]] = [order[j], order[i]];
          renderStages(order);
        });
      });
      box.appendChild(row);
    });
  }

  // ---------------- GRID ----------------
  function renderGrid() {
    const g = data.grid;
    if (!g) { app.innerHTML = ''; return; }
    app.innerHTML = `
      <h3>GRID — POWER RESTORATION${g.solved ? '<span class="solved-tag">ONLINE</span>' : ''}</h3>
      <p class="desc">Route the generator's 9 units to the facility subsystems. Essential systems must
      receive their full rated load before power can be applied.</p>
      <div id="sysrows"></div>
      <div id="captext"></div>
      <div id="capbar"><div id="capfill"></div></div>
      <div class="actions"><button class="btn primary" id="btn-apply">APPLY POWER</button></div>
      <div id="feedback">Awaiting application.</div>`;
    renderSystems(g.alloc);
    $('btn-apply').addEventListener('click', () =>
      Godot.emit('grid_apply', { alloc: JSON.parse(JSON.stringify(g.alloc)) }));
  }

  function renderSystems(alloc) {
    const box = $('sysrows');
    box.innerHTML = '';
    for (const s of data.grid.systems) {
      const row = document.createElement('div');
      row.className = 'sysrow' + (s.essential ? ' essential' : '');
      row.innerHTML = `
        <span class="slabel"><b></b><small>${s.essential ? 'Essential · rated ' + s.need + ' units' : 'Non-essential · draws ' + s.need + ' units'}</small></span>
        <span class="alloc"></span>
        <span class="stepper">
          <button class="btn" data-d="-1">−</button>
          <button class="btn" data-d="1">+</button>
        </span>`;
      row.querySelector('.slabel b').textContent = s.label;
      const allocEl = row.querySelector('.alloc');
      allocEl.textContent = alloc[s.id] + ' u';
      row.querySelectorAll('.stepper .btn').forEach((b) => {
        b.addEventListener('click', () => {
          if (data.grid.solved) return;
          alloc[s.id] = Math.max(0, Math.min(s.need, alloc[s.id] + Number(b.dataset.d)));
          renderSystems(alloc);
        });
      });
      box.appendChild(row);
    }
    const used = Object.values(alloc).reduce((a, b) => a + b, 0);
    $('capfill').style.width = (used / data.grid.capacity * 100) + '%';
    $('capfill').style.background = used > data.grid.capacity ? 'var(--red)' : 'var(--cyan)';
    $('captext').textContent = `ALLOCATED ${used} / ${data.grid.capacity} UNITS`;
  }

  // ---------------- RECORDS ----------------
  function renderRecords() {
    const r = data.records;
    if (!r) { app.innerHTML = ''; return; }
    app.innerHTML = `
      <h3>RECORDS — FACILITY ARCHIVE</h3>
      <p class="desc">Collected logs and notes. Undiscovered records remain encrypted on this terminal.</p>
      <div id="reclist"></div>`;
    const box = $('reclist');
    for (const entry of r.entries) {
      const div = document.createElement('div');
      div.className = 'rec' + (entry.found ? '' : ' locked');
      div.innerHTML = `<div class="rtitle"></div><div class="rtext"></div>`;
      div.querySelector('.rtitle').textContent = entry.found ? entry.title : '████ ENCRYPTED ████';
      div.querySelector('.rtext').textContent = entry.found ? entry.text : 'Recover the matching document on-site.';
      box.appendChild(div);
    }
  }

  // ---------------- state in ----------------
  Godot.onState('trace', (t) => { data.trace = t; if (current === 'trace') renderTrace(); });
  Godot.onState('override', (o) => { data.override = o; if (current === 'override') renderOverride(); });
  Godot.onState('grid', (g) => { data.grid = g; if (current === 'grid') renderGrid(); });
  Godot.onState('records', (r) => { data.records = r; if (current === 'records') renderRecords(); });
  Godot.onState('world', () => reveal());
})();
