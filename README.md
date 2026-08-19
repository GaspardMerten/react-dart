# reactx

**React, reimplemented from scratch in pure Dart.**

Not a binding to React.js, and not Flutter. `reactx` is its own virtual-DOM
renderer with a component model, hooks, keyed reconciliation, **first-class
server-side rendering**, and **dartx** — a JSX/TSX-style file dialect that
compiles to plain Dart. All in Dart, all rendering to real HTML/DOM.

Flutter Web paints to a canvas and isn't built for SSR or plain-HTML output.
`reactx` takes the React approach instead: components produce a lightweight
virtual DOM that renders to an HTML string on the server and to real DOM nodes
(hydrated from that HTML) on the client.

```dart
// counter.dartx
import 'package:reactx/reactx.dart';

Component Counter({int start = 0}) {
  final (count, setCount) = useState(start);

  return <div class="counter">
    <p>Count: <strong>{count}</strong></p>
    <button onClick={() => setCount((c) => c + 1)}>+</button>
  </div>;
}

void main() => print(renderToString(const CounterProps()));
// <div class="counter"><p>Count: <strong>0</strong></p><button>+</button></div>
```

`dart run build_runner build` turns that into `counter.dartx.dart` — ordinary
Dart calling `h(...)`, with the line numbers preserved. The
[VS Code extension](editors/vscode) gives `.dartx` files real type errors, go
to definition and hover, by proxying to Dart's own analysis server rather than
reimplementing one.

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

### What a re-render deliberately does not do

`setState` marks a fiber dirty and schedules one microtask, so a batch of
updates is one pass. That pass then skips as much as it can:

- **an unchanged subtree** — rendering the *same* `VNode` instance again (a
  hoisted node, or one from `useMemo`) short-circuits the whole subtree;
- **a fiber an ancestor already refreshed** — dirty flags are cleared when the
  component function runs, so a parent and child that both call `setState` in
  one handler produce one render each, not two for the child;
- **listener churn** — the registered DOM listener is a stable trampoline that
  reads the current handler off the fiber, so an inline
  `onClick={() => …}` closure costs a map write per render instead of a
  `removeEventListener` + `addEventListener`;
- **untouched attributes and text** — props are diffed key by key, and a text
  node is only written when the string actually differs;
- **nodes already in position** — reordering checks placement before inserting,
  which is what stops a re-render from blurring a focused `<input>`.

Measured on the example calculator: one keypress produces **1** DOM mutation and
**0** listener registrations.

## Install

This repo *is* the package. From another project:

```yaml
dependencies:
  reactx:
    git: https://github.com/gaspardmerten/react-dart
```

## Building UI

Four interchangeable styles, all sugar over the `h()` hyperscript primitive:

```dart
// 1. dartx markup — in a .dartx file, compiled ahead of time
<div class="card"><h1>{title}</h1></div>;

// 2. Element helpers
div({'class': 'card'}, [h1(null, 'Title'), p(null, 'Body')]);

// 3. Hyperscript
h('div', {'class': 'card'}, [h('h1', null, 'Title')]);

// 4. jsx runtime template — a string, parsed on first use, no build step
jsx(r'<div class="card"><h1>${0}</h1></div>', ['Title']);
```

Children can be a `VNode`, a `String`/`num` (becomes text), a `List` (flattened),
or `null`/`false` (dropped — so `cond && child` works).

## Components take typed arguments

A component is a plain function whose **named parameters are its attributes**.
Declaring it is one word — the return type says what it is:

```dart
Component StatCard({required String label, required int value, bool wide = false}) =>
    <div class={wide ? 'card wide' : 'card'}>
      <div class="card-value">{value}</div>
      <div class="card-label">{label}</div>
    </div>;
```

`Component` is `VNode` — the body is checked exactly as it would be otherwise —
but the builder can see it, and generates the props type its call sites use. So

```dart
<StatCard label="Done" value={completed} />
```

compiles to `StatCardProps(label: 'Done', value: completed)` — an ordinary Dart
constructor call. Which means the analyzer checks it where you wrote it:

```dart
<StatCard lable="Done" value={'$completed'} />
//         ^^^^^                ^^^^^^^^^^^
// The named parameter 'lable' isn't defined.
// The named parameter 'label' is required, but there's no corresponding argument.
// The argument type 'String' can't be assigned to the parameter type 'int'.
```

There is exactly one place a component's arguments are declared — its own
parameter list — so `required`, defaults, nullability and types are just Dart,
and nothing can drift out of sync.

| You write | You get |
|---|---|
| `{required int value}` | a required attribute, checked at every call site |
| `{int value = 0}` | an optional attribute with a default |
| `{List<VNode> children = const []}` | the element's children, typed |
| *(nothing)* | `key` — every component accepts one |
| `@memoized` | skip the re-render when the arguments are unchanged |

Attributes keep HTML's spelling. `class` and `for` are Dart keywords, so they
map to parameters named `className` and `htmlFor`, and `aria-label` maps to
`ariaLabel`; the markup is unchanged.

<details>
<summary>What the builder generates</summary>

```dart
final class StatCardProps extends ComponentProps {
  const StatCardProps({
    required this.label,
    required this.value,
    this.wide = false,
    super.key,
  });

  final String label;
  final int value;
  final bool wide;

  @override
  String get name => 'StatCard';
  @override
  VNode build() => StatCard(label: label, value: value, wide: wide);
  @override
  List<Object?> get fields => [label, value, wide];
}
```

A `ComponentProps` **is** a `VNode`, so constructing it is writing the element —
there is no props map on the path at all. Element identity is the generated
type rather than a closure, so the reconciler no longer depends on how the
toolchain happens to name tear-offs.

Hand-writing one is fine too, but you should not have to: components live in
`.dartx` files, including the framework's own (`Link`, `Outlet` and
`RouterScope` are in `lib/src/router/router.dartx`). A `.dartx` file *is* a Dart
file — the transpiler only intervenes where markup appears — so a component file
with no markup in it still gets its props types generated, and the compiled
`.dartx.dart` is what ships.

</details>

### `VNode` still means the untyped form

`VNode Foo(Props props)` with `use(Foo, {'a': 1})` is unchanged, so existing code
keeps compiling and `use()` remains the way to build a node from a component
function. The two return types now tell the two forms apart on sight:
`Component` takes typed arguments, `VNode Function(Props)` reads an untyped map.
dartx markup always emits the typed form.

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
| `useStore(store)` | shared state → `(state, dispatch)` |
| `useSelect(store, sel)` | one slice of shared state |
| `useDispatch(store)` | write to a store without subscribing |

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

## dartx — markup as a language, not a string

A `.dartx` file **is** a Dart file. The transpiler streams it through untouched
and only takes over where markup appears in expression position, so imports,
classes, patterns, records — anything Dart can express — keep working. Compile
with `dart run build_runner build`; `app.dartx` becomes `app.dartx.dart`, which
you import like any other file.

```dart
VNode TodoList(Props props) {
  final (items, setItems) = useState<List<String>>(const ['Learn reactx']);

  return <section class="todos">
    <h2>Todos ({items.length})</h2>
    <ul>
      {[for (final (i, item) in items.indexed) <li key={i}>{item}</li>]}
    </ul>
    <button onClick={() => setItems([...items, 'New'])}>Add</button>
  </section>;
}
```

| Syntax | Meaning |
|--------|---------|
| `<div>` | host element — a lowercase name becomes a tag string |
| `<Counter />`, `<widgets.Card />` | component — compiled to `use(Counter, …)`, so the name is **type-checked** |
| `{expression}` | any Dart expression, as a child or an attribute value |
| `attr="literal"` | a plain string; use `attr={'a $b'}` to interpolate |
| `attr` | shorthand for `attr={true}` |
| `{...props}` | spread a `Map<String, Object?>` into the props |
| `key={x}` | reconciliation key, exactly as in React |
| `<>…</>` | fragment |
| `{/* … */}`, `<!-- … -->` | comments, dropped from the output |
| `<br>`, `<img src="…">` | HTML void elements may omit the slash |
| `&amp;` `&nbsp;` `&#8230;` | HTML entities are decoded |

Two properties are worth calling out:

* **Line numbers are preserved.** Markup is emitted with padding newlines so
  line *N* of the generated Dart is line *N* of your `.dartx`. Analyzer errors,
  stack traces and breakpoints land where you wrote the code — no source map
  needed.
* **Components are statically checked.** `<Counter />` emits
  `use(Counter, …)`, whose first parameter is a `FunctionComponent` — a typo or
  a non-component is a compile error, not a runtime one.

### Where markup is recognised

The one place dartx and Dart genuinely collide is `<`. The transpiler treats it
as markup only in expression position (after `=`, `(`, `,`, `[`, `return`,
`=>`, `?`, `:`, `&&`, a collection `for`/`if` header, …) and never inside a
string or comment. It also recognises Dart's own angle brackets, so these stay
untouched:

```dart
final names = <String>[];              // typed literal, not a <String> element
final m = <String, Object?>{};         // ditto
Map<String, List<int>> byKey = {};     // generics
if (a < b && b > c) { … }              // comparisons
final v = decode<Model>(json);         // generic invocation
```

A name is a host element when it is lowercase and undotted (`div`,
`my-widget`); anything else is a Dart reference (`Counter`, `widgets.Card`).

Two corners to know about:

* Markup inside a **string interpolation** (`'${<b>x</b>}'`) is not recognised —
  strings are copied through verbatim, exactly as the Dart lexer sees them.
* `<Foo>[…]` is read as a typed literal, not as a component with a child
  starting with `[`. Wrap the child (`<Foo>{['…']}</Foo>`) in the rare case you
  meant the latter.

### The toolchain

```bash
dart run build_runner build          # compile every .dartx in the package
dart run build_runner watch          # …and keep compiling

dart run reactx:dartx lib/ web/      # one-off compile, no build_runner
dart run reactx:dartx --check lib/   # CI: report problems, write nothing
dart run reactx:dartx --server       # JSON-lines check server, used by editors
```

Errors point into the `.dartx` file:

```
dartx: lib/app.dartx:24:7: closing tag `</section>` does not match opening `<div>`
```

### Editor support

[`editors/vscode`](editors/vscode) is a VS Code extension for `.dartx`. Install
it with `npm install && npx @vscode/vsce package && code --install-extension
dartx-0.2.0.vsix`.

It ships a **language server** — `dart run reactx:dartx_lsp` — which is a proxy
in front of Dart's own analysis server rather than a second analyser:

```
  editor  ──  Page.dartx, line 5  ──▶  dartx lsp
                                          │  transpile, map the position
                                          ▼
  dart language-server  ◀──  Page.dartx.dart, line 5
                                          │
  editor  ◀──  an error on Page.dartx line 5  ──┘
```

So `<StatCard value={'three'} />` is underlined in the `.dartx`, on the line
that wrote it, with the analyser's own message; go to definition on `<StatCard>`
opens `Component StatCard(…)` in the file that declares it; and hover reports
the declared type of an argument. The editor never learns that a generated file
exists.

Find all references on a component lists the `<StatCard …>` elements that use
it. That one needs a redirection rather than a translation: the markup does not
compile to a call to `StatCard`, it compiles to `StatCardProps(…)`, so asking
the analyser the literal question finds one line of generated machinery and not
a single real call site. The request is retargeted onto the props type.

All of it works because the transpiler preserves line numbers exactly, which
leaves only the column to recover — done by identifier, since compilation
preserves the order of identifiers on a line. One limit worth knowing:
completion inside a complete element works, but completion *mid-tag* does not,
because an unclosed tag has nothing to compile.

On top of that: highlighting, the transpiler's own markup diagnostics (which
the analyser cannot produce, since it never sees the markup), closing-tag
insertion, snippets, and commands for the build_runner round trip.

## The `jsx` runtime template syntax

The original string-template syntax still works and needs no build step —
useful for a quick script, or for markup assembled at runtime. Use a **raw
string** so the `${n}` slots survive to the parser:

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
renderToString(App);                         // -> HTML fragment
renderToDocument(App,                        // -> full <!doctype html> page
    title: 'My app', bootstrapScript: 'main.dart.js');

renderToString(use(App, {'title': 'Hi'}));   // pass props to the root
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
  runApp(App);

  // Or hydrate server-rendered markup in #root, adopting existing DOM:
  hydrateApp(App);
}
```

Hydration walks the existing server markup and **adopts** the nodes instead of
recreating them, then attaches event listeners and wires up state.

### Reading values from DOM events

Handlers receive the native event as an `Object`, because its real type
(`web.Event`) can't be named from a component the server also renders. Import
`package:reactx/events.dart` and read through it:

```dart
import 'package:reactx/events.dart';

<input value={draft} onInput={onValue(setDraft)} />
<input type="checkbox" onChange={onChecked(setDone)} />
<form onSubmit={(e) { preventDefault(e); submit(); }}>
<button onClick={on(() => setOpen(true))}>Open</button>
```

| Helper | Gives you |
|---|---|
| `valueOf(e)` / `onValue(fn)` | the value of an `<input>`, `<textarea>` or `<select>` |
| `checkedOf(e)` / `onChecked(fn)` | a checkbox or radio's state |
| `keyOf(e)` / `onKey(fn)` | `event.key` |
| `on(fn)` | drops the event for handlers that don't want it |
| `preventDefault(e)`, `stopPropagation(e)` | the obvious |
| `listenKeys(fn)` | a document-level `keydown` subscription that returns its own unsubscribe, so `useEffect(() => listenKeys(fn), const [])` just works |

That library is a **conditional export**: real `package:web` calls in the
browser, inert stubs on the VM. So one component file works in both places and
you never write a platform shim.

Do not reach into the event yourself with `dynamic`. `web.Event` is a
js_interop extension type whose members are erased, so `(event as dynamic)
.target` compiles to a lookup the real object doesn't have and throws under
dart2js. If you need something these helpers don't cover, add it behind the same
conditional export rather than casting to `dynamic`.

## Context

```dart
final theme = createContext('light');

VNode app(Props p) => theme.provider(value: 'dark', children: [use(toolbar)]);
VNode toolbar(Props p) => div(null, 'theme: ${useContext(theme)}');
```

## Stores

Context answers "what does this subtree see". Most shared state is not that —
it is one thing the whole app reads, and wrapping the tree in a provider per
store is ceremony. A **store** is declared once and read from anywhere:

```dart
final todos = defineStore(TodoState.initial, todoReducer);   // top level

VNode Badge(Props props) {
  final remaining = useSelect(todos, (s) => s.remaining);    // re-renders only
  return span(null, '$remaining left');                      // when this moves
}

VNode AddButton(Props props) {
  final dispatch = useDispatch(todos);                       // never subscribes
  return button({'onClick': on(() => dispatch(const AddTodo()))}, 'Add');
}
```

**The store object is the identity.** There is no name to type, so a typo is a
compile error, rename works from the IDE, and two packages cannot collide on
`'user'`.

**The state is not in the store.** It lives on the `Root` that is rendering, or
on the renderer handling one server request. That is what keeps SSR correct —
two requests in one isolate never see each other's data — and what gives every
`createRoot` in a test a clean slate. A global would break both.

| Hook | Re-renders when |
|---|---|
| `useStore(store)` | anything in the state changes |
| `useSelect(store, (s) => s.x)` | `s.x` changes (compared with `==`) |
| `useDispatch(store)` | never — for components that only write |

`dispatch` is the same object on every render, so it is safe as a `memo` prop or
a `useEffect` dependency.

## Routing

`package:reactx/router.dart` keeps the server, the address bar and the tree in
agreement. The path is a **prop**, never a global — so one server can render
several routes at once, and the client's first render provably matches the
markup it hydrates.

```dart
// app.dartx
Component App({String? path}) => <RouterScope path={path}>
      <nav>
        <Link href="/" class="tab" activeClass="on">Todos</Link>
        <Link href="/stats" class="tab" activeClass="on">Stats</Link>
      </nav>
      <RouteOutlet />
    </RouterScope>;

// server.dart — the request path goes in
renderToDocument(AppProps(path: request.uri.path), …);

// main.dart — the address bar says which route was served
hydrateApp(AppProps(path: currentPath()));
```

| | |
|---|---|
| `RouterScope` | holds the path, listens for Back/Forward |
| `Link` | a real `<a href>` that navigates without reloading; `activeClass`, `exact`, `replace`, and an `attributes` map for anything else the `<a>` should carry |
| `useRoutePath()` / `useNavigate()` | read the path / change it |
| `matchPath('/todo/:id', path)`, `useParams(pattern)` | path parameters; a trailing `*` captures the rest |

That is the whole of the path-only mode. The route *table* stays in your app,
and so does what a 404 means. See `example/todo_app/src/routes.dart`.

### Route trees: nesting, guards and data

Give `RouterScope` a `routes` list instead and it takes over matching, guards
and data loading. Everything below is additive — the path-only mode above keeps
working unchanged.

```dart
final todoRoute = Route(
  path: 'todo/:id',                       // relative to its parent
  element: const TodoPageProps(),         // the element to render
  middleware: [requireAuth],              // runs before any loader
  loader: (context) => fetchTodo(context.params['id']!),
  encode: (todo) => (todo as Todo).toJson(),      // so the client can reuse it
  decode: (json) => Todo.fromJson(json as Map<String, Object?>),
  errorElement: const TodoErrorProps(),
);

final routes = [
  Route(path: '/', element: const LayoutProps(), children: [
    Route(
      index: true,
      element: const TodosPageProps(),
      loader: (_) => loadTodos(),
    ),
    Route(path: 'todo/new', element: const NewTodoProps()),  // beats todo/:id
    todoRoute,
    Route(path: '*', element: const NotFoundProps()),
  ]),
];
```

`Layout` renders `<Outlet />` where its children belong; nesting is just that,
repeated.

**Matching is ranked by specificity, not by table order.** A static segment
beats a parameter, which beats a wildcard, so `/todo/new` wins over
`/todo/:id` no matter which you wrote first — the silent wrong-page footgun in
order-sensitive routers.

**Middleware** runs root-first, before any loader, and returns `Next()`,
`Redirect('/login')` or `Halt(error)`. An outer `requireAuth` therefore settles
the question before an inner loader can fetch anything.

**Loaders across the matched chain run concurrently**, so a three-deep route is
one round-trip deep, not three. They see `context.params`, `context.query` and
the full `context.location`.

**Same code on both sides.** `resolveLocation` is a pure async function over the
table, so the server and the browser reach the same answer:

```dart
// server.dart — loaders have already run by the time you render
final resolution = await resolveLocation(routes, request.uri,
    followRedirects: false);           // so a guard can emit a real 302
switch (resolution) {
  case RouteRedirected(:final location): return redirect(302, location);
  case RouteNotFound():                 return notFound();
  case RouteResolved(:final snapshot):
    // embed snapshot.toTransferJson() in the page
    renderToDocument(AppProps(snapshot: snapshot), …);
}

// main.dart — reuse the server's fetches instead of repeating them
final snapshot = await hydrateSnapshot(routes, currentUri(), transferJson);
hydrateApp(AppProps(snapshot: snapshot));
```

`hydrateSnapshot` reuses the transferred data when every matched loader could be
encoded, and re-runs the loaders otherwise — either way the first client render
matches the markup it is adopting. A route with no `encode` simply does not
travel, which is the safe default for values JSON cannot express.

| | |
|---|---|
| `Outlet` | renders the next match in the chain |
| `useLoaderData(route)` | the data that route's loader produced — **keyed by the route object**, so there is no name to mistype and rename just works |
| `useRouteParams()` / `useQuery()` | every captured parameter / the parsed query string |
| `useNavigation()` | `idle` or `loading`, and where to — for spinners and disabled buttons |
| `useMatches()` | the matched chain, for breadcrumbs |
| `useRouteError()` | inside an `errorElement` |
| `matchRoutes(routes, path)` | the ranked matcher, standalone |

Navigation resolves **before** it commits: clicking a link leaves the current
page on screen, with `useNavigation().isLoading` true, until the new route's
data has arrived. Overlapping navigations are ticketed, so a slow loader can
never overwrite a newer one that already landed.

Errors from a loader or guard render the nearest `errorElement` at or above
the failure, and its children do not render at all — a route that could not load
its data has no business drawing.

### Routes from the file system

Writing that table by hand is fine, and for a handful of routes it is the
clearest thing in the app. Past that, the shape of the tree is already visible
in the directory, so `build_runner` can write the table for you.

The model is TanStack Router's rather than Next.js's, and the difference
matters: **nothing scans a directory at runtime.** The generator emits
`routes.g.dart` — the same `Route` objects you would have typed — and the server
and the browser share it. Open the file and you can read exactly what you got.

```
lib/routes/
  layout.dartx                 the shell; renders <Outlet />
  page.dartx                   /
  stats/page.dartx             /stats
  todo/[id]/page.dartx         /todo/:id
  todo/[id]/error.dartx        rendered when that route's loader throws
  todo/[id]/edit/page.dartx    /todo/:id/edit
  (marketing)/about/page.dartx /about — a (parenthesised) folder groups files
                               without adding a path segment
  [...rest]/page.dartx         the catch-all
```

`[id]` captures a parameter and `[...rest]` is the catch-all; TanStack's own
`$id` and bare `$` work too. A `layout.dartx` wraps its directory and everything
below it, and the `page.dartx` beside one becomes that layout's index route.

Everything else a route carries is declared **in the page file**, picked up by
name:

```dart
// lib/routes/todo/[id]/page.dartx
Component TodoPage() {
  final todo = useLoaderData<Todo>(todoIdRoute);   // the generated route object
  return <article>{todo.title}</article>;
}

Future<Todo> loader(LoaderContext context) => fetchTodo(context.params['id']!);
Object? encode(Object? todo) => (todo! as Todo).toJson();
Object? decode(Object? json) => Todo.fromJson(json! as Map<String, Object?>);
const middleware = [requireSignedIn];
const title = PageInfo('Todo', 'One todo, loaded by its route.');
```

The generated names are derived from the path — `todo/[id]` is `todoIdRoute`,
the root layout is `rootRoute`, the catch-all is `catchAllRoute` — and
`useLoaderData` still takes the **route object**, so nothing here is a string
you can mistype.

Turn it on in `build.yaml`:

```yaml
targets:
  $default:
    builders:
      reactx|routes:
        enabled: true
        # defaults; set them if your routes live elsewhere
        options:
          routes: lib/routes
          output: lib/routes.g.dart
```

`reactx serve` regenerates the table itself, with the same generator, so adding
`routes/about/page.dartx` is live before you have finished saving it.

A route the conventions cannot express is still an ordinary `Route` — write it
by hand and add it to the list. `example/todo_app` is the whole thing working:
nine files, one guard, one loader, and a `routes.dart` that holds only what a
directory layout genuinely cannot say.

**Known limits.** No optional segments (`/a/:b?`) or regex constraints; no
per-route code splitting; loaders do not revalidate on their own — a navigation
to the same location re-runs them, nothing else does.

## `reactx serve` — hot reload on save

```bash
dart run reactx:serve example/todo_app          # http://localhost:8080
```

It watches the directory, compiles `.dartx` in process, recompiles only the
libraries that changed, and patches them into the page **while it keeps
running**. The page is never reloaded, so what you had typed, scrolled to or put
in a store is still there afterwards. A save costs on the order of 20–60 ms,
against ~2.9 s to rebuild a `dart compile js` bundle.

Your `server.dart` is hot reloaded too. It runs with the VM service open, and a
save calls `reloadSources` on the live isolate instead of killing it: the
`HttpServer` keeps its socket and the handler you registered at startup starts
running the new code, in ~180 ms. If the VM declines the reload — a changed
class hierarchy, say — the process restarts, which is always correct and merely
slower.

A status indicator sits in the bottom-right corner. It is always visible, names
what it is doing when you hover it (`compiling for hot reload`, `reloaded in
42 ms`, `reconnecting…`), and opens a panel of session statistics when you click
it: mode and compiler, first-build time, reloads applied, last / average /
fastest / slowest, libraries swapped, how much faster a save is than the first
build, how many forced restarts you have had and why the last one happened, and
a sparkline of recent timings. Build errors become a full-page overlay instead
of a line that scrolled past in a terminal.

### What survives a save, and what does not

| | |
|---|---|
| Store state, router state, anything on the `Root` | **survives** |
| `useState` in components outside the file you edited | **survives** |
| `useState` in components *inside* the file you edited | **survives** |
| Everything your `main()` does — timers, listeners, one-time setup | runs once, at startup |
| Top-level and `static` variables | keep their values |

The rule behind the table is Flutter's: a reload does not restart the app, it
**reassembles** it. Every mounted component is re-run in place against the code
that was just swapped in, and no fiber is ever unmounted — so nothing has any
state to lose. `main()` is not re-entered, which is why a save cannot register
your timers a second time.

Nothing is remounted because nothing is re-identified: the fibers are already
there, and where the reconciler *does* compare (the children a re-render
produces), identity is the generated props type, which DDC preserves across a
library redefine.

Top-level variables behave exactly as they do under the Dart VM's hot reload —
a changed *initializer* needs a restart to take effect, and the indicator says
so when the server forces one.

### Requirements

Hot reload needs a DDC-compiled `dart_sdk.js`, which in practice means a Flutter
SDK on the machine; set `REACTX_DART_SDK_JS` if yours lives somewhere unusual.
Without one, the server prints the reason on startup and falls back to the older
hot **restart** — a rebuild plus a page reload, where no state survives.

Your `server.dart` only has to accept `--port`; the dev server picks the port it
runs on and proxies to it, so the SSR entrypoint you develop against is the real
one. It also serves the client bundle at the URL your server already points at,
so nothing in your app needs to know which compiler is behind it.

## build_runner: two builders

```bash
dart run build_runner build
```

| Builder | Input | Output |
|---|---|---|
| `reactx\|dartx` | `app.dartx` | `app.dartx.dart` — the markup compiled, plus a props type for each `Component` function |
| `reactx\|jsx_precompiler` | `jsx(r'…')` calls in `.dart` | `app.reactx.g.dart` — a `registerAppTemplates()` that fills the template cache so nothing is parsed at runtime |

The dartx builder applies to any package that depends on reactx. The
precompiler is opt-in per path (see `build.yaml`) and is only relevant if you
use runtime templates; without it those templates still work, just parsed
lazily on first use.

## Running the example

```bash
dart run build_runner build                         # compiles example/app.dartx
dart run example/server.dart > example/index.html   # SSR to HTML
dart compile js -O4 example/main.dart -o example/main.dart.js   # client bundle
# serve example/ and open index.html — the page hydrates and becomes interactive
```

### The todo app — five routes

`example/todo_app/` is a small but complete site: a todo list, a `/todo/:id`
page loaded by its route, a guarded edit panel nested inside it, plus stats and
about — sharing one store, each a real URL that returns finished HTML.

```bash
dart run reactx:serve example/todo_app     # then edit anything and watch
```

It is the reference for how the pieces fit — typed components, the resolved
location as an argument, one `defineStore` with no wrapper, `useSelect` in the
header so it does not re-render when you switch filters,
`@memoized` on the rows, a loader whose result travels to the
browser, a guard that answers with a real 302, and a real 404 for both an
unknown URL and a todo that does not exist. Its README walks through the
structure; `test/todo_app_test.dart` covers the reducer, the route tree, the
data transfer, the server output and client-side navigation.

### The calculator app

`example/calculator/` is a fuller app: a working calculator with a keypad,
keyboard bindings, and an error state. Its arithmetic is a pure state machine
(`CalcState` + `calcReducer`) driven through `useReducer`, so the same component
renders on the server and hydrates on the client, and the logic is testable
without a DOM.

```bash
dart run build_runner build
dart run example/calculator/server.dart > example/calculator/index.html
dart compile js -O4 example/calculator/main.dart -o example/calculator/main.dart.js
# open example/calculator/index.html
```

Covered by `test/calculator_test.dart` (VM, via `TestHost`) and
`test/calculator_browser_test.dart` (real browser: hydration, clicks, keyboard).

## Bundle size

Measured with `dart compile js -O4` (dart2js 3.10.7) and `gzip -9`:

| Client bundle | raw | gzip |
|---|---|---|
| one component — `useState`, a button, `hydrateApp` | 90.5 KB | **28.6 KB** |
| the full calculator — reducer, keypad, keyboard bindings | 98.9 KB | **31.3 KB** |

The shape to note: dart2js does whole-program, closed-world tree shaking, so
the cost is a **fixed floor, not a slope**. The Dart runtime and the reactx
reconciler dominate; the entire calculator adds under 3 KB gzip on top of
hello-world. Application code is close to free.

Two things follow:

- **Always pass `-O4`.** Without it the same calculator is 53.9 KB gzip —
  1.7× larger for one flag.
- **The bundle doesn't block first paint.** SSR emits complete markup, so a
  server-rendered page displays, styled and readable, with JavaScript disabled
  entirely; the bundle only buys interactivity. Load it with `defer` and the
  floor is a deferred upgrade rather than a render-blocking cost.

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

`package:reactx/testing.dart` wraps that up with a query API, so a test reads
like the page:

```dart
import 'package:reactx/testing.dart';

final app = mountApp(use(App, {'path': '/'}));

app.act(() => app.tree.byClass('nav-link').click());
expect(app.tree.byTag('h1').textContent, 'Stats');
expect(app.tree.allByClass('todo').length, 4);
```

`byClass` / `byTag` / `byText` / `byAttr` / `allByClass` / `textContent` /
`hasClass`, and `click` / `change` / `input` / `submit`. A miss throws with the
markup it searched, rather than a null-check failure.

```bash
dart test        # VM suite: vdom, hooks, reconciler, ssr, dartx, jsx,
                 # hydration, builders, and the example apps
```

The dartx transpiler has its own suite (`test/dartx_test.dart`) covering the
grammar, the Dart-versus-markup decisions, line fidelity and error positions;
`test/dartx_example_test.dart` renders what the builder actually generated from
`example/app.dartx`. The VS Code extension's tag logic is tested separately with
`cd editors/vscode && node --test`.

There is also a real-browser suite (`test/browser_test.dart`, `@TestOn('browser')`)
that compiles to JS and drives the actual DOM — event dispatch, hydration
adoption, and input focus. It's skipped by the VM run above; run it against a
Chrome/Chromium binary with:

```bash
# uses google-chrome from PATH, or set CHROME_EXECUTABLE
dart test -p chrome test/browser_test.dart
```

## Layout

```
lib/
  reactx.dart            platform-neutral barrel (VM/server safe)
  dom.dart               browser client barrel (package:web)
  events.dart            DOM event helpers (conditional: web / VM stub)
  router.dart            RouterScope, Link, useRoutePath, matchPath
  testing.dart           mountApp + a query API over TestNode
  hot_reload.dart        used by the entrypoint `reactx serve` generates
  dartx.dart             the .dartx transpiler (build-time)
  builder.dart           build_runner entrypoints
  src/
    vdom.dart            VNode types, h(), normalizeChildren
    elements.dart        div/span/button/… helpers
    hooks.dart           hooks + the Dispatcher indirection
    context.dart         createContext / providers
    host.dart            HostAdapter + in-memory TestHost
    reconciler.dart      fiber tree, keyed diff, effects, scheduler, hydration
    ssr.dart             renderToString / renderToDocument
    jsx.dart             runtime template parser + AST + cache
    dom.dart             DomHostAdapter + runApp/hydrateApp
    events/              event helpers, one file per platform
    router/              routing + History API, one file per platform
      route.dart         the route tree: ranked matching, guards, loaders
      router.dart        RouterScope, Outlet, Link, the hooks
    routes/
      file_routes.dart   a routes directory -> the generated Route table
      generate_io.dart   the same, for a real directory (the dev server)
    store.dart           Store + defineStore (state lives on the Root)
    diagnostics.dart     the dev-mode warning sink
    hot_reload.dart      the flag that makes runApp reuse its Root
    devserver/           `reactx serve`: watch, recompile, swap, overlay
      dev_server.dart    proxy, watchers, SSE, the rebuild pipeline
      ddc_compiler.dart  frontend_server in DDC library-bundle mode
      vm_service.dart    reloadSources, to reload the SSR server in place
      client.dart        the status pill, stats panel, and reload client
    dartx/
      scanner.dart       where Dart ends and markup begins
      parser.dart        markup grammar -> AST
      ast.dart           the markup AST
      emitter.dart       AST -> Dart, with line-for-line fidelity
      transpiler.dart    the pass that ties them together
      diagnostics.dart   positions and errors
    builder/             the three Builders
bin/
  dartx.dart             CLI: compile, --check, --server
  serve.dart             CLI: the development server
editors/
  vscode/                VS Code extension for .dartx
```

## Limitations & roadmap

- Synchronous reconciler (no time-slicing / concurrent mode).
- A component cannot have type parameters: a generic component would need a
  generic props type, and markup has nowhere to write the type argument.
- A component written in a plain `.dart` file has to hand-write its props class
  (or be called with `use()` and a map) — generation runs in the dartx builder,
  over `.dartx` files.
- `memo` compares arguments one level deep. Markup children are rebuilt every
  render, so a memoized component that takes children rarely bails out — memo
  pays off on leaves with plain-value arguments.
- No async data loading during SSR: `renderToString` is synchronous, so fetch
  before you render and pass the result in as props.
- Hydration assumes markup matches the tree; avoid adjacent bare-text siblings
  (the server collapses them into one text node).
- Class components aren't included — function components + hooks only.
- dartx has no source maps yet; it preserves line numbers instead, which covers
  the analyzer and stack traces but not column-accurate debugging.
- dartx does not treat `<script>`/`<style>` as raw-text elements: markup inside
  them is parsed as markup.

## License

MIT — see [LICENSE](LICENSE).
