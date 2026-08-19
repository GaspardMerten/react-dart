/// The snippet the dev server injects into every page it proxies.
///
/// Plain JS on purpose: it has to run before (and independently of) the app's
/// own bundle, so that a *failed* build still shows you why. It talks to
/// `/__reactx` over Server-Sent Events and owns three pieces of UI — a status
/// pill that is always visible in the corner, a panel of session statistics
/// behind a click on it, and a full-screen overlay for build errors.
///
/// The statistics live in `sessionStorage`, not in a variable, because the one
/// thing that would otherwise reset them is exactly the thing worth counting: a
/// forced hot *restart*. Surviving the reload it is reporting on is the whole
/// point.
library;

/// Injected verbatim, just before `</body>`.
const devClient = r'''
<style>
  #__reactx {
    position: fixed; right: 12px; bottom: 12px; z-index: 2147483646;
    font: 500 12px/1 system-ui, -apple-system, "Segoe UI", sans-serif;
    color: #e8eaf0; user-select: none;
  }
  #__reactx .pill {
    display: flex; align-items: center; cursor: pointer;
    padding: .4rem .5rem; border-radius: 999px;
    background: #1b1f2af2; border: 1px solid #ffffff24;
    box-shadow: 0 6px 20px #00000059; backdrop-filter: blur(6px);
    transition: border-color .2s ease;
  }
  #__reactx .pill:hover { border-color: #ffffff40; }
  #__reactx .dot {
    width: 8px; height: 8px; border-radius: 50%; background: #4ade80;
    flex: none; transition: background .2s ease;
  }
  /* The label is collapsed rather than hidden, so the pill is always there but
     never in the way until you point at it. */
  #__reactx .label {
    max-width: 0; overflow: hidden; white-space: nowrap; opacity: 0;
    transition: max-width .25s ease, opacity .2s ease, margin .25s ease;
  }
  #__reactx:hover .label, #__reactx.open .label {
    max-width: 220px; opacity: 1; margin: 0 .35rem 0 .5rem;
  }
  #__reactx[data-state="building"] .dot {
    background: #fbbf24; animation: __reactx-pulse 1s infinite;
  }
  #__reactx[data-state="error"] .dot { background: #f87171; }
  #__reactx[data-state="offline"] .dot { background: #94a3b8; }
  @keyframes __reactx-pulse {
    0% { box-shadow: 0 0 0 0 #fbbf2466; } 70% { box-shadow: 0 0 0 6px #fbbf2400; }
    100% { box-shadow: 0 0 0 0 #fbbf2400; }
  }

  #__reactx .panel {
    display: none; position: absolute; right: 0; bottom: 34px; width: 268px;
    padding: .85rem .9rem; border-radius: 12px;
    background: #12151ef7; border: 1px solid #ffffff24;
    box-shadow: 0 12px 40px #00000073; backdrop-filter: blur(10px);
    cursor: default;
  }
  #__reactx.open .panel { display: block; }
  #__reactx .panel h3 {
    margin: 0 0 .7rem; font-size: 12px; font-weight: 600; letter-spacing: .02em;
    display: flex; align-items: center; justify-content: space-between;
  }
  #__reactx .panel h3 .mode { color: #93c5fd; font-variant-numeric: tabular-nums; }
  #__reactx .row {
    display: flex; justify-content: space-between; gap: 1rem;
    padding: .22rem 0; color: #9aa4b8;
  }
  #__reactx .row b {
    font-weight: 600; color: #e8eaf0;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-variant-numeric: tabular-nums;
  }
  #__reactx .row.warn b { color: #fbbf24; }
  #__reactx .spark {
    display: flex; align-items: flex-end; gap: 2px; height: 30px;
    margin: .6rem 0 .15rem; padding-top: .3rem;
    border-top: 1px solid #ffffff14;
  }
  #__reactx .spark i {
    flex: 1; min-height: 2px; border-radius: 1px; background: #4ade8099;
  }
  #__reactx .spark i.slow { background: #fbbf2499; }
  #__reactx .hint { margin-top: .5rem; color: #6b7488; font-size: 11px; }

  #__reactx-overlay {
    position: fixed; inset: 0; z-index: 2147483647; display: none;
    padding: 6vh 6vw; overflow: auto; background: #0f1116f2;
    color: #fca5a5; backdrop-filter: blur(3px);
    font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  #__reactx-overlay h2 {
    margin: 0 0 1rem; color: #f87171;
    font: 600 15px/1.4 system-ui, -apple-system, sans-serif;
  }
  #__reactx-overlay pre { margin: 0; white-space: pre-wrap; word-break: break-word; }
  #__reactx-overlay .hint { margin-top: 1.5rem; color: #94a3b8; }
</style>
<div id="__reactx" data-state="ready">
  <div class="panel"></div>
  <div class="pill" title="reactx dev server — click for details">
    <span class="dot"></span><span class="label">ready</span>
  </div>
</div>
<div id="__reactx-overlay"><h2>Build failed</h2><pre></pre>
  <div class="hint">Fix the error and save — this closes itself.</div></div>
<script>
(function () {
  var root = document.getElementById('__reactx');
  var pill = root.querySelector('.pill');
  var label = root.querySelector('.label');
  var panel = root.querySelector('.panel');
  var overlay = document.getElementById('__reactx-overlay');
  var pre = overlay.querySelector('pre');
  var wasOffline = false;
  var startedAt = Date.now();

  // -- session statistics ---------------------------------------------------
  // Kept in sessionStorage so a forced restart does not erase the count of
  // forced restarts.
  var KEY = '__reactx.stats';
  var stats;
  try {
    stats = JSON.parse(sessionStorage.getItem(KEY));
  } catch (e) { /* corrupt or unavailable */ }
  if (!stats || typeof stats !== 'object') stats = null;
  stats = stats || {
    reloads: 0,        // hot reloads applied in place
    restarts: 0,       // full page reloads we were forced into
    lastReason: '',    // why the last restart happened
    libraries: 0,      // libraries swapped, total
    times: [],         // server ms per hot reload
    applied: [],       // client ms to fetch + swap + re-render
    info: null
  };

  function save() {
    try { sessionStorage.setItem(KEY, JSON.stringify(stats)); } catch (e) {}
  }

  // The exact inverse of the server's SSE framing, in one left-to-right pass.
  // A chain of regexes gets this wrong: a literal backslash followed by `n`
  // would come out as a newline.
  function unescapeSse(data) {
    var out = '';
    for (var i = 0; i < data.length; i++) {
      if (data[i] !== '\\' || i + 1 >= data.length) {
        out += data[i];
        continue;
      }
      var next = data[++i];
      out += next === 'n' ? '\n' : next === 'r' ? '\r' : next;
    }
    return out;
  }

  function forcedRestart(reason) {
    stats.restarts++;
    stats.lastReason = reason;
    save();
    location.reload();
  }

  // -- rendering ------------------------------------------------------------

  function show(state, text) {
    root.dataset.state = state;
    label.textContent = text;
  }

  function ms(value) { return Math.round(value) + ' ms'; }

  function mean(list) {
    if (!list.length) return 0;
    var total = 0;
    for (var i = 0; i < list.length; i++) total += list[i];
    return total / list.length;
  }

  function row(name, value, warn) {
    return '<div class="row' + (warn ? ' warn' : '') + '"><span>' + name +
        '</span><b>' + value + '</b></div>';
  }

  function sparkline(list) {
    if (list.length < 2) return '';
    var recent = list.slice(-24);
    var peak = Math.max.apply(null, recent);
    var bars = '';
    for (var i = 0; i < recent.length; i++) {
      var height = Math.max(6, Math.round((recent[i] / peak) * 100));
      bars += '<i class="' + (recent[i] > peak * 0.75 ? 'slow' : '') +
          '" style="height:' + height + '%" title="' + ms(recent[i]) + '"></i>';
    }
    return '<div class="spark">' + bars + '</div>';
  }

  function uptime() {
    var seconds = Math.round((Date.now() - startedAt) / 1000);
    if (seconds < 60) return seconds + 's';
    var minutes = Math.floor(seconds / 60);
    return minutes + 'm ' + (seconds % 60) + 's';
  }

  function renderPanel() {
    var info = stats.info || {};
    var times = stats.times;
    var html = '<h3>reactx dev <span class="mode">' +
        (info.mode || '…') + (info.compiler ? ' · ' + info.compiler : '') +
        '</span></h3>';

    if (info.initialBuildMs) {
      html += row('First build', ms(info.initialBuildMs));
    }
    html += row('Hot reloads', String(stats.reloads));

    if (times.length) {
      html += row('Last', ms(times[times.length - 1]) + ' + ' +
          ms(stats.applied[stats.applied.length - 1] || 0));
      html += row('Average', ms(mean(times)));
      html += row('Fastest', ms(Math.min.apply(null, times)));
      html += row('Slowest', ms(Math.max.apply(null, times)));
      html += row('Libraries swapped', String(stats.libraries));
      if (info.initialBuildMs) {
        html += row('vs first build',
            Math.round(info.initialBuildMs / Math.max(1, mean(times))) +
            '× faster');
      }
    }

    html += row('Forced restarts', String(stats.restarts), stats.restarts > 0);
    if (stats.lastReason) {
      html += row('Last restart', stats.lastReason, true);
    }
    html += row('Page age', uptime());
    html += sparkline(times);
    html += '<div class="hint">' +
        (times.length ? 'Server compile + browser apply, per save.'
                      : 'Save a file to see timings.') +
        '</div>';
    panel.innerHTML = html;
  }

  pill.addEventListener('click', function () {
    root.classList.toggle('open');
    if (root.classList.contains('open')) renderPanel();
  });
  document.addEventListener('click', function (e) {
    if (!root.contains(e.target)) root.classList.remove('open');
  });
  // Keep the numbers honest while the panel sits open.
  setInterval(function () {
    if (root.classList.contains('open')) renderPanel();
  }, 1000);

  // -- the event stream -----------------------------------------------------

  function connect() {
    var es = new EventSource('/__reactx');

    es.addEventListener('info', function (e) {
      try { stats.info = JSON.parse(unescapeSse(e.data)); save(); } catch (err) {}
      if (root.classList.contains('open')) renderPanel();
    });

    es.addEventListener('ready', function () {
      overlay.style.display = 'none';
      show('ready', 'ready');
      // The server came back after being gone: it has restarted with new code.
      if (wasOffline) {
        wasOffline = false;
        forcedRestart('server restarted');
      }
    });

    es.addEventListener('building', function (e) {
      show('building', e.data || 'rebuilding…');
    });

    // A full rebuild the page cannot absorb in place.
    es.addEventListener('reload', function (e) {
      var detail = '';
      try { detail = ' (' + JSON.parse(unescapeSse(e.data)).ms + ' ms)'; } catch (err) {}
      show('building', 'restarting');
      forcedRestart('hot restart' + detail);
    });

    // A hot reload: patch the new libraries into the running program, then let
    // reactx rebuild from them. Any failure here falls back to a page reload —
    // a lost scroll position beats a page running half-updated code.
    es.addEventListener('hot-reload', function (e) {
      var plan;
      try {
        plan = JSON.parse(unescapeSse(e.data));
      } catch (err) {
        forcedRestart('malformed reload payload');
        return;
      }
      show('building', 'hot reloading');
      var began = Date.now();
      Promise.resolve(window.__reactxReady)
        .then(function () {
          return dartDevEmbedder.hotReload([plan.file], plan.libraries);
        })
        .then(function () {
          // Read the hook off the library each time: after the swap the
          // property holds the newly compiled function, while anything captured
          // earlier would still point at the old code.
          //
          // It re-runs the mounted tree in place rather than re-entering
          // main(), and answers with how many roots it found. Zero means
          // nothing is mounted yet — there is no tree to reassemble, so the
          // honest move is a restart rather than a silently ignored save.
          var roots = dartDevEmbedder.importLibrary(plan.entry)
              .reactxHotReload();
          if (roots === 0) {
            forcedRestart('nothing mounted yet');
            return;
          }

          stats.reloads++;
          stats.libraries += (plan.libraries || []).length;
          stats.times.push(plan.ms || 0);
          stats.applied.push(Date.now() - began);
          if (stats.times.length > 60) {
            stats.times.shift();
            stats.applied.shift();
          }
          save();

          overlay.style.display = 'none';
          show('ready', 'reloaded in ' + ms(plan.ms || 0));
          if (root.classList.contains('open')) renderPanel();
          setTimeout(function () {
            if (root.dataset.state === 'ready') show('ready', 'ready');
          }, 2500);
        })
        .catch(function (err) {
          console.error('reactx: hot reload failed, reloading the page', err);
          forcedRestart('hot reload failed');
        });
    });

    es.addEventListener('error-report', function (e) {
      show('error', 'build failed');
      pre.textContent = unescapeSse(e.data);
      overlay.style.display = 'block';
    });

    es.onerror = function () {
      es.close();
      wasOffline = true;
      show('offline', 'reconnecting…');
      setTimeout(connect, 600);
    };
  }

  connect();
})();
</script>
''';
