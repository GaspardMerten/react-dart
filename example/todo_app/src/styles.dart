/// The stylesheet, as a Dart constant.
///
/// It lives in Dart rather than in a `.css` file for one reason: the server
/// inlines it into every rendered page, so a route always arrives fully styled
/// in the first response — no second request, no flash of unstyled content.
library;

const styles = '''
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f7fb;
    --panel: #ffffff;
    --line: #e3e6ef;
    --text: #171a21;
    --muted: #6b7280;
    --accent: #4f46e5;
    --accent-soft: #eceafe;
    --done: #16a34a;
    --shadow: 0 1px 2px rgb(16 24 40 / .06), 0 8px 24px rgb(16 24 40 / .06);
    --radius: 12px;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0f1116;
      --panel: #171a21;
      --line: #262b36;
      --text: #e8eaf0;
      --muted: #98a0b3;
      --accent: #8b85ff;
      --accent-soft: #232043;
      --done: #4ade80;
      --shadow: 0 1px 2px rgb(0 0 0 / .4), 0 12px 32px rgb(0 0 0 / .35);
    }
  }

  * { box-sizing: border-box; }

  body {
    margin: 0;
    min-height: 100vh;
    background: var(--bg);
    color: var(--text);
    font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
  }

  #root {
    max-width: 46rem;
    margin: 0 auto;
    padding: 1.5rem 1.25rem 3rem;
    display: flex;
    flex-direction: column;
    min-height: 100vh;
  }

  a { color: inherit; }

  /* ---- header ---------------------------------------------------------- */

  .site-head {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding-bottom: 1.25rem;
    border-bottom: 1px solid var(--line);
    flex-wrap: wrap;
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: .5rem;
    font-weight: 650;
    text-decoration: none;
    letter-spacing: -.01em;
  }

  .brand-mark {
    display: grid;
    place-items: center;
    width: 1.6rem;
    height: 1.6rem;
    border-radius: 8px;
    background: var(--accent);
    color: #fff;
    font-size: .9rem;
  }

  .nav { display: flex; gap: .25rem; margin-left: auto; }

  .nav-link {
    padding: .35rem .7rem;
    border-radius: 999px;
    text-decoration: none;
    color: var(--muted);
    font-size: .92rem;
    transition: background .12s ease, color .12s ease;
  }
  .nav-link:hover { background: var(--line); color: var(--text); }
  .nav-link.is-active { background: var(--accent-soft); color: var(--accent); }

  .badge {
    font-size: .8rem;
    color: var(--muted);
    border: 1px solid var(--line);
    border-radius: 999px;
    padding: .2rem .6rem;
    white-space: nowrap;
  }

  /* ---- page ------------------------------------------------------------ */

  .page { flex: 1; padding: 1.75rem 0; }
  .stack { display: flex; flex-direction: column; gap: 1.25rem; }

  .page-head h1 { font-size: 1.6rem; margin: 0 0 .25rem; letter-spacing: -.02em; }
  h2 { font-size: 1.05rem; margin: .5rem 0 0; }
  .lede, .hint, .empty { color: var(--muted); margin: 0; }
  .hint { font-size: .9rem; }
  .hint .nav-link { padding: 0; color: var(--accent); }
  .hint .nav-link:hover { background: none; text-decoration: underline; }

  .empty {
    padding: 1.5rem;
    text-align: center;
    border: 1px dashed var(--line);
    border-radius: var(--radius);
  }

  /* ---- form ------------------------------------------------------------ */

  .todo-form { display: flex; gap: .5rem; flex-wrap: wrap; }

  .input, .select {
    font: inherit;
    color: inherit;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: .55rem .75rem;
  }
  .input { flex: 1; min-width: 12rem; }
  .input:focus-visible, .select:focus-visible, .btn:focus-visible,
  .chip:focus-visible, .nav-link:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }

  .btn {
    font: inherit;
    border: 1px solid transparent;
    border-radius: 10px;
    padding: .55rem 1rem;
    cursor: pointer;
    background: var(--panel);
    color: inherit;
    transition: background .12s ease, opacity .12s ease;
  }
  .btn.primary { background: var(--accent); color: #fff; font-weight: 550; }
  .btn.primary:disabled { opacity: .45; cursor: default; }
  .btn.ghost { border-color: var(--line); color: var(--muted); }
  .btn.ghost:hover { color: var(--text); }
  .btn.icon { padding: .2rem .55rem; font-size: 1.1rem; line-height: 1; }
  .btn.ghost:not(.icon) { align-self: flex-start; font-size: .9rem; }

  .filters { display: flex; gap: .4rem; }

  .chip {
    font: inherit;
    font-size: .88rem;
    padding: .3rem .8rem;
    border-radius: 999px;
    border: 1px solid var(--line);
    background: transparent;
    color: var(--muted);
    cursor: pointer;
  }
  .chip.is-on {
    background: var(--accent-soft);
    border-color: transparent;
    color: var(--accent);
    font-weight: 550;
  }

  /* ---- list ------------------------------------------------------------ */

  .todo-list {
    list-style: none;
    margin: 0;
    padding: 0;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
    overflow: hidden;
  }

  .todo {
    display: flex;
    align-items: center;
    gap: .75rem;
    padding: .7rem .9rem;
    border-top: 1px solid var(--line);
  }
  .todo:first-child { border-top: 0; }

  .todo-main {
    display: flex;
    align-items: center;
    gap: .7rem;
    flex: 1;
    cursor: pointer;
    min-width: 0;
  }
  .todo-main input { width: 1.05rem; height: 1.05rem; accent-color: var(--accent); }
  .todo-title { overflow-wrap: anywhere; }
  .todo.is-done .todo-title { text-decoration: line-through; color: var(--muted); }

  .tag {
    font-size: .72rem;
    text-transform: uppercase;
    letter-spacing: .04em;
    padding: .15rem .5rem;
    border-radius: 6px;
    background: var(--line);
    color: var(--muted);
  }
  .tag-work  { background: #dbeafe; color: #1d4ed8; }
  .tag-home  { background: #dcfce7; color: #15803d; }
  .tag-learn { background: #fee2e2; color: #b91c1c; }

  @media (prefers-color-scheme: dark) {
    .tag-work  { background: #1e3a8a40; color: #93c5fd; }
    .tag-home  { background: #14532d40; color: #86efac; }
    .tag-learn { background: #7f1d1d40; color: #fca5a5; }
  }

  /* ---- stats ----------------------------------------------------------- */

  .cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: .75rem; }

  .card {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    padding: 1rem;
    box-shadow: var(--shadow);
  }
  .card-value { font-size: 1.9rem; font-weight: 600; letter-spacing: -.03em; }
  .card-label { color: var(--muted); font-size: .85rem; }

  .progress-block { display: flex; flex-direction: column; gap: .4rem; }
  .progress-head {
    display: flex;
    justify-content: space-between;
    font-size: .85rem;
    color: var(--muted);
  }
  .progress {
    flex: 1;
    height: .5rem;
    border-radius: 999px;
    background: var(--line);
    overflow: hidden;
  }
  .progress-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 999px;
    transition: width .2s ease;
  }

  .bars { list-style: none; margin: 0; padding: 0; display: grid; gap: .6rem; }
  .bar-row { display: flex; align-items: center; gap: .75rem; }
  .bar-row .tag { width: 4.5rem; text-align: center; }
  .bar-count {
    font-size: .85rem;
    color: var(--muted);
    font-variant-numeric: tabular-nums;
    width: 2.5rem;
    text-align: right;
  }

  /* ---- about ----------------------------------------------------------- */

  .steps { margin: 0; padding-left: 1.2rem; display: grid; gap: .6rem; }
  code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .88em;
    background: var(--line);
    padding: .1rem .35rem;
    border-radius: 5px;
  }
  .tree {
    margin: 0;
    padding: 1rem;
    overflow-x: auto;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .82rem;
    line-height: 1.5;
    color: var(--muted);
  }

  /* ---- routing --------------------------------------------------------- */

  /* Always present, so a navigation fades a bar in rather than reflowing the
     page under the pointer that started it. */
  .route-progress {
    height: 2px;
    border-radius: 2px;
    background: var(--accent);
    opacity: 0;
    transform: scaleX(0);
    transform-origin: left;
    transition: opacity .12s ease, transform .5s ease-out;
  }
  .route-progress.is-loading {
    opacity: 1;
    /* Not 1: the bar shows that work started, and claiming it is finished
       before the loaders return would be a lie. */
    transform: scaleX(.7);
  }

  .visually-hidden {
    position: absolute;
    width: 1px; height: 1px;
    margin: -1px; padding: 0; border: 0;
    clip-path: inset(50%);
    overflow: hidden;
    white-space: nowrap;
  }

  /* ---- detail page ----------------------------------------------------- */

  .detail {
    margin: 0;
    display: grid;
    grid-template-columns: auto 1fr;
    gap: .5rem 1.25rem;
    align-items: center;
    padding: 1rem 1.15rem;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    box-shadow: var(--shadow);
  }
  .detail dt { color: var(--muted); font-size: .85rem; }
  .detail dd { margin: 0; }

  .row { display: flex; gap: .6rem; flex-wrap: wrap; align-items: center; }
  .row .btn.ghost:not(.icon) { align-self: auto; }

  .note {
    margin: 0;
    color: var(--muted);
    font-size: .87rem;
  }

  /* The nested `/todo/:id/edit` route, rendered through the detail page's
     outlet — a child route as a panel, not as a replacement. */
  .panel-edit {
    display: flex;
    flex-direction: column;
    gap: .75rem;
    padding: 1rem 1.15rem;
    background: var(--accent-soft);
    border: 1px solid var(--line);
    border-radius: var(--radius);
  }
  .panel-edit h2 { margin: 0; font-size: 1rem; }
  .panel-edit .todo-form { margin: 0; }

  .error-detail {
    margin: 0;
    padding: .85rem 1rem;
    overflow-x: auto;
    background: var(--panel);
    border: 1px solid var(--line);
    border-left: 3px solid #ef4444;
    border-radius: var(--radius);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .85rem;
    color: var(--muted);
  }

  /* ---- footer ---------------------------------------------------------- */

  .site-foot {
    display: flex;
    gap: 1rem;
    align-items: baseline;
    justify-content: space-between;
    padding-top: 1.25rem;
    border-top: 1px solid var(--line);
    color: var(--muted);
    font-size: .85rem;
  }

  .foot-link { white-space: nowrap; }
  .foot-link:hover { color: var(--text); }

  @media (max-width: 34rem) {
    .cards { grid-template-columns: 1fr; }
    .nav { margin-left: 0; order: 3; width: 100%; }
    .badge { margin-left: auto; }
  }
</style>''';
