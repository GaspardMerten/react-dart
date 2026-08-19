/// Server-side rendering entrypoint for the calculator.
///
/// ```
/// dart run build_runner build                    # compiles calculator.dartx
/// dart run example/calculator/server.dart > example/calculator/index.html
/// ```
///
/// The emitted page references `main.dart.js` (compile `main.dart` next to it),
/// which hydrates the very same tree in the browser.
library;

import 'dart:io';

import 'package:reactx/reactx.dart';

// Generated from calculator.dartx by `dart run build_runner build`.
import 'calculator.dartx.dart';

const _styles = '''
<style>
  :root {
    color-scheme: dark;
    --bg: #11131a;
    --panel: #1b1f2a;
    --key: #272d3b;
    --key-hi: #333b4d;
    --accent: #f0883e;
    --text: #eef1f7;
    --muted: #8b93a7;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    padding: 2rem 1rem;
    background: var(--bg);
    color: var(--text);
    font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  .app { width: min(22rem, 100%); text-align: center; }
  h1 { font-size: 1.25rem; font-weight: 600; margin: 0 0 .25rem; }
  .lede, .hint { color: var(--muted); font-size: .8rem; margin: 0 0 1.25rem; }
  .hint { margin: 1rem 0 0; }

  .calc {
    background: var(--panel);
    border-radius: 18px;
    padding: 1rem;
    box-shadow: 0 20px 45px rgb(0 0 0 / .45);
  }
  .screen {
    padding: .75rem .5rem 1rem;
    text-align: right;
    overflow: hidden;
  }
  .tape {
    color: var(--muted);
    font-size: .85rem;
    height: 1.4em;
    font-variant-numeric: tabular-nums;
  }
  .value {
    font-size: clamp(1.9rem, 11vw, 2.75rem);
    font-weight: 300;
    letter-spacing: -.02em;
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
  .value.is-error { color: var(--accent); font-size: 2rem; }

  .keypad {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: .5rem;
  }
  .key {
    appearance: none;
    border: 0;
    border-radius: 12px;
    padding: .9rem 0;
    font: inherit;
    font-size: 1.15rem;
    color: var(--text);
    background: var(--key);
    cursor: pointer;
    transition: background .12s ease, transform .06s ease;
  }
  .key:hover { background: var(--key-hi); }
  .key:active { transform: translateY(1px); }
  .key:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .key.fn { background: #323847; color: var(--muted); font-size: 1rem; }
  .key.fn:hover { background: #3c4356; }
  .key.op { background: var(--accent); color: #1a1200; font-weight: 600; }
  .key.op:hover { background: #ff9d55; }
  .key.wide { grid-column: span 2; }
</style>''';

void main() {
  stdout.write(renderToDocument(
    CalculatorApp,
    title: 'reactx calculator',
    bootstrapScript: 'main.dart.js',
    head: _styles,
  ));
}
