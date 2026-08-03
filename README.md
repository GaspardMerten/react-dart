# reactx

**React, reimplemented from scratch in pure Dart.**

Not a binding to React.js, and not Flutter. `reactx` is its own virtual-DOM
renderer with a component model, hooks, keyed reconciliation, **first-class
server-side rendering**, and a **JSX-like template syntax** — all in Dart, all
rendering to real HTML/DOM.

Flutter Web paints to a canvas and isn't built for SSR or plain-HTML output.
`reactx` takes the React approach instead: components produce a lightweight
virtual DOM that renders to an HTML string on the server and to real DOM nodes
(hydrated from that HTML) on the client.

```dart
import 'package:reactx/reactx.dart';

VNode counter(Props props) {
  final (count, setCount) = useState(0);
  return jsx(r'''
    <div class="counter">
      <p>Count: <strong>${0}</strong></p>
      <button onClick=${1}>+</button>
    </div>
  ''', [count, () => setCount((c) => c + 1)]);
}

void main() => print(renderToString(use(counter)));
// <div class="counter"><p>Count: <strong>0</strong></p><button>+</button></div>
```

---

## Why it's built this way

The core idea is one seam: the reconciler never touches the DOM. It talks only
to a **`HostAdapter`** whose nodes are opaque objects.

```
        components + hooks (useState, useEffect, useContext, …)
                              │
                       virtual DOM (VNode)
                              │
                 ┌────────────┴─────────────┐
        reconciler (fiber tree,        renderToString
        keyed diff, effects)           (server, pure Dart)
                 │
        ┌────────┴──────────┐
   DomHostAdapter        TestHost
   (package:web)     (in-memory tree)
```

Because the reconciler is host-agnostic:

- **The client** plugs in `DomHostAdapter` (the only part that uses
  `package:web`).
- **Tests** plug in `TestHost`, an in-memory tree, so the *entire* reconciler —
  hooks, effects, scheduling, keyed reconciliation, hydration — is verified
  headlessly on the Dart VM. No browser needed.
- **The server** doesn't reconcile at all: `renderToString` walks the VNode tree
  once and emits HTML, running components under a read-only hook dispatcher
  (initial state, no effects) — exactly how React behaves on the server.

Hooks work on both client and server via a swappable `Dispatcher` (React's own
internal trick): the client installs a fiber-backed dispatcher; the server
installs a read-only one. The same component code runs in both.

## Install

This repo *is* the package. From another project:

```yaml
dependencies:
  reactx:
    git: https://github.com/gaspardmerten/react-dart
```

## Building UI

Three interchangeable styles, all sugar over the `h()` hyperscript primitive:

```dart
// 1. Element helpers
div({'class': 'card'}, [h1(null, 'Title'), p(null, 'Body')]);

// 2. Hyperscript
h('div', {'class': 'card'}, [h('h1', null, 'Title')]);

// 3. jsx template (below)
jsx(r'<div class="card"><h1>${0}</h1></div>', ['Title']);
```

Children can be a `VNode`, a `String`/`num` (becomes text), a `List` (flattened),
or `null`/`false` (dropped — so `cond && child` works).

## Hooks

The full set, with the same semantics as React:

| Hook | Purpose |
|------|---------|
| `useState(initial)` | local state → `(value, setter)` |
| `useReducer(reducer, initial)` | reducer state → `(state, dispatch)` |
| `useEffect(fn, [deps])` | run after commit; return a cleanup |
| `useLayoutEffect(fn, [deps])` | run synchronously after DOM mutation |
| `useMemo(fn, [deps])` | memoize a computed value |
| `useCallback(fn, [deps])` | memoize a callback identity |
| `useRef(initial)` | mutable box that survives renders |
| `useContext(context)` | read the nearest provided value |

```dart
VNode timer(Props props) {
  final (n, setN) = useState(0);
  useEffect(() {
    final t = Timer.periodic(const Duration(seconds: 1), (_) => setN((v) => v + 1));
    return t.cancel;            // cleanup
  }, const []);                 // run once
  return p(null, 'Ticks: $n');
}
```

State setters accept a value *or* a functional updater (`setN((prev) => prev + 1)`).

## The `jsx` template syntax

An HTML/JSX-like syntax that compiles to VNodes. Use a **raw string** so the
`${n}` slots survive to the parser:

```dart
jsx(r'''
  <ul class="list ${0}">
    ${1}
    <li>static</li>
  </ul>
''', [modifier, itemsList]);
```

| Syntax | Meaning |
|--------|---------|
| `${n}` (text/child) | insert `args[n]` (VNode, String, list, …) |
| `attr=${n}` | pass `args[n]` through unchanged (handlers, `style` maps) |
| `attr="a ${n}"` | string-interpolate into the attribute |
| `<${n} .../>` | render component `args[n]` (a `FunctionComponent`) |
| `<>…</>` | fragment |
| `<!-- … -->` | comment (dropped) |

Templates are parsed once and cached. Structural indentation is stripped so
template whitespace doesn't leak into output.

## Server-side rendering

```dart
renderToString(use(app));                    // -> HTML fragment
renderToDocument(use(app),                   // -> full <!doctype html> page
    title: 'My app', bootstrapScript: 'main.dart.js');
```

Supports escaping, void elements (`<br>`, `<img>`…), `className`/`htmlFor`
mapping, `style` maps, boolean attributes, context providers, and
`dangerouslySetInnerHTML`. Event handlers are omitted (they can't be
serialized).

## Client: mount and hydrate

From a **web** entrypoint, import `package:reactx/dom.dart`:

```dart
import 'package:reactx/dom.dart';

void main() {
  // Fresh client-only render:
  runApp(use(app));

  // Or hydrate server-rendered markup in #root, adopting existing DOM:
  hydrateApp(use(app));
}
```

Hydration walks the existing server markup and **adopts** the nodes instead of
recreating them, then attaches event listeners and wires up state.

## Context

```dart
final theme = createContext('light');

VNode app(Props p) => theme.provider(value: 'dark', children: [use(toolbar)]);
VNode toolbar(Props p) => div(null, 'theme: ${useContext(theme)}');
```

## build_runner: precompiling templates

The runtime `jsx()` parser is fast and cached, but you can eliminate parsing
entirely. The included builder scans for `jsx(r'...')` calls and generates
`h(...)` construction code — the Babel-for-JSX step, made optional.

```bash
dart run build_runner build
```

For `example/app.dart` this emits `example/app.reactx.g.dart` with a
`registerAppTemplates()` function. Call it once at startup to warm the cache:

```dart
import 'app.reactx.g.dart';

void main() {
  registerAppTemplates();  // precompiled templates now bypass the parser
  runApp(use(app));
}
```

Without this step the very same templates still work — they're just parsed
lazily on first use.

## Running the example

```bash
dart run build_runner build            # generate precompiled templates
dart run example/server.dart > example/index.html   # SSR to HTML
dart compile js example/main.dart -o example/main.dart.js   # client bundle
# serve example/ and open index.html — the page hydrates and becomes interactive
```

## Testing headlessly

The whole runtime is tested on the VM via `TestHost`:

```dart
final host = TestHost();
final root = createRoot(host, host.root);
root.render(use(counter));

root.act(() => find(host.root, 'button')!.dispatch('click'));  // deterministic
expect(find(host.root, 'span')!.children.single.text, '1');
```

`root.act(fn)` runs `fn` then synchronously flushes state updates and effects —
the equivalent of React's `act()`.

```bash
dart test        # 47 tests: vdom, hooks, reconciler, ssr, jsx, hydration, builder
```

## Layout

```
lib/
  reactx.dart            platform-neutral barrel (VM/server safe)
  dom.dart               browser client barrel (package:web)
  builder.dart           build_runner entrypoint
  src/
    vdom.dart            VNode types, h(), normalizeChildren
    elements.dart        div/span/button/… helpers
    hooks.dart           hooks + the Dispatcher indirection
    context.dart         createContext / providers
    host.dart            HostAdapter + in-memory TestHost
    reconciler.dart      fiber tree, keyed diff, effects, scheduler, hydration
    ssr.dart             renderToString / renderToDocument
    jsx.dart             template parser + AST + cache
    dom.dart             DomHostAdapter + runApp/hydrateApp
    builder/             jsx precompiler (emitter + Builder)
```

## Limitations & roadmap

- Synchronous reconciler (no time-slicing / concurrent mode).
- No `React.memo`-style bailout yet — a component render re-renders its subtree.
- Hydration assumes markup matches the tree; avoid adjacent bare-text siblings
  (the server collapses them into one text node).
- Class components aren't included — function components + hooks only.

## License

MIT — see [LICENSE](LICENSE).
