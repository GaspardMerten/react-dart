# Changelog

## 0.3.0

**Fixes from a full framework review.** Three subsystems were reviewed
independently; every finding below was reproduced before it was fixed, and each
one now has a regression test.

*Security*

- `RouterSnapshot.toTransferJson()` escapes `<`, `>` and U+2028/9. Its output is
  documented as going inside a `<script>`, so a loaded value containing
  `</script>` was stored XSS in any app that followed the docs. The escaping
  belongs in the framework, not in each app's server file — the todo example
  had it, which is exactly how the hole stayed invisible.
- The SSR renderer validates tag and attribute *names*. Values were already
  escaped and quoted; a name is written into the tag raw, so one built from data
  could inject a second attribute.
- `RouterSnapshot.fromTransferJson` no longer throws on a negative index — the
  one function whose contract is "a bad payload returns null".

*Hydration* — three ways the DOM and the fiber tree could end up disagreeing:

- A server node that does not match the tree is replaced **in its own slot**
  instead of being appended, so a mismatch no longer reverses sibling order and
  poisons every later diff.
- Server nodes the client tree never claims are removed instead of being left
  visible forever.
- An adopted element is diffed against the attributes it actually carries, so an
  attribute the server set and the client dropped is removed.

*Reconciler*

- Two siblings with the same key can no longer adopt the same fiber, which used
  to render only the last of them and then run its cleanups twice.
- `Root.unmount()` clears store state, the dirty set and the effect queues.
  Re-rendering an unmounted root used to see the previous session's data.
- `useReducer` reads the current reducer rather than the one captured at mount,
  so a reducer closing over props is no longer permanently stale.
- A `ref` that is swapped or dropped while its element stays mounted is cleared.
- Effect cleanups run as a phase before any new effect, and unmount runs
  children's cleanups before their parent's — both matching React.

*Performance*

- Children are only repositioned when something actually moved, and a
  single-child update (every component render) skips the keyed machinery.
- A provider change now suspends bailouts only for subtrees that actually read
  the context that changed; a theme toggle no longer re-renders the whole app.
- Store selections are a `Set`, so tearing down *n* `useSelect` rows is no
  longer O(n²).
- The flattened route table is computed once per table instead of once per
  match, and `RouterScope` hands out a stable context value.

*dartx*

- `<Card>{count}</Card>` compiles. A component whose first child was an
  expression was read as a type-argument list and passed through untouched —
  invalid Dart, no diagnostic. `<void Function()>[]` was the mirror image, valid
  Dart reported as a bad tag.
- An apostrophe in markup nested inside a `{…}` expression no longer swallows
  the rest of the file, and markup inside a string interpolation is compiled
  rather than copied through.
- An out-of-range numeric entity is left as written instead of crashing the
  build with an unlocated `RangeError`.
- The same attribute twice is now an error rather than a silent last-wins.
- The props generator reserves the member names it declares, keeps the
  nullability of function-typed parameters, refuses to collide with an existing
  `FooProps`, and positions its diagnostics on the right line.

*Dev server*

- App restarts are serialized, so two quick saves cannot orphan a server process
  that holds its port and outlives shutdown. SIGTERM now stops the child too,
  not just Ctrl-C.
- Process output subscriptions are cancelled, watchers for deleted directories
  are pruned, and a watcher that dies says so instead of silently ending live
  reload.
- SSE framing escapes `\r`, and the client reverses the framing for every event
  — a JSON payload containing a newline used to arrive corrupted.

**Hot reload keeps component state.** A save now *reassembles* the tree the way
Flutter does — every mounted component re-runs in place against the new code,
and no fiber is unmounted — instead of re-entering `main()` and re-rendering
from the root. Two consequences: `useState` in the component you just edited
survives (it used to reset), and whatever else your entrypoint does no longer
happens again on every save. Measured end to end in a browser: edit a
component's markup, and its half-typed input is still half-typed.

**Typed props** — a component's named parameters are its attributes.

- Declaring one is a return type: `Component StatCard({required String label,
  required int value})`. `Component` *is* `VNode`, so the body is checked as
  before, but the builder can see it and generates the props type its markup
  call sites construct — `<StatCard label="Done" value={n} />` compiles to
  `StatCardProps(label: 'Done', value: n)`, and the analyzer checks every
  attribute name and value where you wrote it. A misspelled attribute, a missing
  required one, or a `String` where an `int` belongs is now a compile error
  instead of a `null` three frames into a render.
- Putting the marker in the signature rather than in an annotation means it
  cannot be forgotten separately from what it marks, and tells the two forms
  apart on sight: `Component` takes typed arguments, `VNode Function(Props)`
  reads an untyped map.
- Arguments are declared in exactly one place — the parameter list — so
  `required`, defaults, nullability and types are Dart's, and nothing can drift.
  `key` is understood without declaring it, and a `List<VNode> children`
  parameter receives the element's children.
- `@memoized` replaces wrapping a component in `memo`: the generated type
  compares its arguments field by field. It is the only annotation left, and it
  appears on the rare component that wants it rather than on all of them.
- Element identity is the generated props type rather than a closure, so the
  reconciler no longer depends on how the toolchain names tear-offs.
- Attributes keep HTML's spelling: `class` and `for` map to `className` and
  `htmlFor`, and `aria-label` maps to `ariaLabel`. A spread on a component is
  now an error — the arguments are named, so pass them.
- `Route.component` / `errorComponent` are now `Route.element` / `errorElement`
  and hold a node (`const TodoPageProps()`), because a typed component is named
  by the type it takes and a route has no arguments to pass it.
- `Link` declares what it forwards; anything else goes in its `attributes` map,
  rather than every undeclared prop silently reaching the `<a>`.
- Components live in `.dartx` files — including the router's own, which moved
  there and dropped 118 lines of hand-written props classes. A `.dartx` file is
  a Dart file the transpiler only touches where markup appears, so a component
  file with no markup still gets generation, and no `part` directive or second
  builder is needed.
- The untyped form is unchanged: `VNode Foo(Props props)` with
  `use(Foo, {'a': 1})` still compiles, and `use(Foo)` is how you put a
  map-based component where a node is wanted.
- Fixed: a client navigation resolved with no `extra`, so a guard reading the
  session bounced a signed-in visitor the moment they clicked a link.
  `RouterScope` now carries it, defaulting to whatever resolved the snapshot the
  server sent.
- Fixed: a route with both a component and children could not match its own
  path — `/todo/:id` was reachable only as `/todo/:id/edit`.

**Stores** — shared state without a provider per store.

- `defineStore(initial, reducer)` declares one; the object *is* its identity, so
  there is no string key to mistype, rename works from the IDE, and two packages
  cannot collide. Read it with `useStore` (whole state), `useSelect(store, sel)`
  (re-renders only when that slice changes), or `useDispatch` (never subscribes).
- State lives on the `Root` being rendered — or on one request's server
  renderer — never in a static. Concurrent SSR stays correct, and every
  `createRoot` in a test starts clean.
- The dispatch function is identical across renders, so it is safe as a `memo`
  prop or a `useEffect` dependency.

**Route trees** — nesting, guards and data loading, on top of the router below.

- `Route` describes a tree: nested `children` rendered through `Outlet`, `index`
  routes, `:param` segments and a trailing `*`.
- **Matching is ranked by specificity, not table order.** Static beats param
  beats wildcard, so `/todo/new` wins over `/todo/:id` wherever each was
  written — the wrong-page-by-ordering bug is gone by construction.
- `middleware` runs root-first, before any loader, returning `Next()`,
  `Redirect(...)` or `Halt(...)`. An outer guard therefore settles access before
  an inner loader can fetch anything.
- `loader` fetches a route's data; loaders across the matched chain run
  **concurrently**, so a three-deep route costs one round trip, not three.
  Results reach components through `useLoaderData(route)` — keyed by the route
  object, so there is no string to mistype and rename works from the IDE.
- `resolveLocation` is a pure async function over the table, so the server and
  the browser reach the same answer. `followRedirects: false` hands a guard's
  redirect back so the server can emit a real 302 instead of rendering the
  destination under the wrong URL.
- The server's fetches travel to the client: `snapshot.toTransferJson()` embeds
  what `Route.encode` allows, and `hydrateSnapshot` reuses it — or re-runs the
  loaders when a route declined to travel, so the first client render always
  matches the markup it adopts.
- `errorElement` renders the nearest boundary at or above a failing loader or
  guard, and stops the descent.
- Navigation resolves before it commits — the old page stays up, with
  `useNavigation().isLoading` true, until the new data lands. Overlapping
  navigations are ticketed so a slow loader cannot overwrite a newer one.
- New hooks: `useRouteParams`, `useQuery`, `useNavigation`, `useMatches`,
  `useLoaderData`, `useLoaderDataOrNull`, `useRouteError`. New standalone
  `matchRoutes`.
- Fixed: query strings were dropped entirely — `currentPath()` read only
  `location.pathname`, so `?filter=done` could not survive a navigation and the
  server and client could disagree about the page.

**Routing** — new `package:reactx/router.dart`.

- `RouterScope` (seeded from a `path` prop: the request path on the server,
  `currentPath()` in the browser), `Link` with `activeClass`/`exact`/`replace`
  and pass-through props, and `useRouter` / `useRoutePath` / `useNavigate` /
  `useParams`.
- `matchPath('/todo/:id', path)` for parameters, plus a trailing `*`.
- Platform bits resolve through a conditional export, as `events.dart` does, so
  routed component code still renders on the VM.

**Development server** — new `dart run reactx:serve <dir>`, hot reload on save.

- Watches the directory, compiles `.dartx` in process, recompiles only the
  libraries that changed, and patches them into the running page. **State
  survives**: the page is never reloaded, so what you had typed, scrolled to or
  put in a store is still there.
- Around **20–60 ms** per save, against ~2.9 s for a `dart compile js` bundle,
  because a save emits a few kilobytes of JS instead of the whole program.
- This needed a different compiler. `dart compile js` produces one bundle with
  no library boundaries, so the only way to apply a change is to reload the
  page; the server now drives DDC's library-bundle format through
  `frontend_server`, and hands the changed libraries to the module loader's
  `dartDevEmbedder.hotReload`.
- After the swap the dev entrypoint re-enters your `main()`. Components from
  libraries the edit did not touch keep their identity, so their fibers — and
  their `useState` — are updated in place. Components *in* the edited library
  are new function objects, so those subtrees remount: local state there
  resets, while store state, which lives on the `Root`, does not. Top-level
  variables keep their values, exactly as under the Dart VM's hot reload.
- Needs a DDC-compiled `dart_sdk.js`, which in practice means a Flutter SDK on
  the machine (`REACTX_DART_SDK_JS` overrides the search). Without one the
  server prints why and falls back to the previous hot restart, rather than
  silently losing your state.
- Your SSR server is hot reloaded too, not restarted. It runs with the VM
  service open, and a save calls `reloadSources` on the live isolate — the
  `HttpServer` keeps its socket and the handler registered at startup simply
  starts running the new code, in about 180 ms rather than a second of process
  startup. When the VM declines a reload the server restarts, which is always
  correct, just slower.
- Injects a status indicator into the page (idle / rebuilding / offline) and
  shows build errors as a full-page overlay rather than leaving a stale page and
  a message in the terminal. A hot reload that fails for any reason falls back
  to a page reload: a lost scroll position beats a page running half-new code.
- The indicator is always visible, names the current status on hover
  (`compiling for hot reload`, `reloaded in 42 ms`, …) and opens a panel of
  session statistics on click: mode and compiler, first-build time, reloads
  applied, last / average / fastest / slowest, libraries swapped, how much
  faster a save is than the first build, forced restarts and why the last one
  happened, plus a sparkline of recent timings. The numbers live in
  `sessionStorage`, so the count of forced restarts survives the restart it is
  counting.
- Proxies to your own `server.dart`, which keeps the app's SSR entrypoint the
  real one — it just has to accept `--port`.
- Watches each directory with its own flat watcher: `Directory.watch(recursive:
  true)` is documented as supported on Linux but delivers no events on some SDK
  builds, and a dev server that silently stops noticing saves is worse than
  none.

**Testing** — new `package:reactx/testing.dart`.

- `mountApp(app)` returns a `TestApp` (tree, `act`, `html`), and an extension on
  `TestNode` adds `byClass` / `byTag` / `byText` / `byAttr` / `allByClass` /
  `textContent` / `hasClass` and `click` / `change` / `input` / `submit`.
- Failures name what was actually in the tree instead of throwing on a null.

**Dev-mode guardrails.** All behind `assert`, so a release build pays nothing.

- A hook called conditionally now throws naming both hooks, instead of silently
  reading another hook's slot.
- Duplicate sibling keys are reported — previously the keyed diff just paired up
  the wrong nodes.
- Hydration mismatches are reported, and the mismatched server node is discarded
  rather than adopted as the wrong kind of host node. Needs the new optional
  `HostAdapter.tagOf`, which defaults to `null` (check disabled) so existing
  adapters keep working.
- A component that throws during render logs its path through the tree
  (`App > Layout > TodoList`) before the original error is rethrown untouched.
- `reactxWarning` is the sink for all of the above; replace it to capture.

**Other**

- `memo(Component, {areEqual})` — the props-based bailout to go with the
  identity one. Respects context changes and a component's own pending state.
- Fixed: `checked={false}` / `selected={false}` removed the attribute but left
  the DOM *property* set, so state could never un-check a box the user had
  checked.
- The example gained `example/todo_app`: a three-page site — todo list, stats,
  about — server-rendered per route with a real 404, then hydrated.

## 0.2.0

**dartx** — markup becomes part of the language instead of a string.

- New `.dartx` file dialect: ordinary Dart with JSX/TSX-style markup wherever an
  expression is allowed. Expression children and attributes (`{count}`,
  `onClick={…}`), spreads (`{...props}`), fragments (`<>…</>`), keys, HTML void
  elements without the slash, HTML entities, and `{/* … */}` comments.
- The transpiler (`package:reactx/dartx.dart`) distinguishes markup from Dart's
  own angle brackets, so `<String>[]`, `Map<K, V>`, `a < b` and
  `decode<Model>(json)` are left alone.
- Generated Dart is **line-for-line** with the `.dartx` source, so analyzer
  errors, stack traces and breakpoints point at what you wrote.
- Component tags compile to `use(Component, …)`, which is typed — a bad
  component name is now a compile error rather than a runtime one.
- `build_runner` builder (`.dartx` → `.dartx.dart`), applied automatically to
  packages that depend on reactx.
- `dart run reactx:dartx` CLI: compile, `--check` for CI, and `--server` for
  editors (JSON lines over stdin/stdout, no VM startup per keystroke).
- VS Code extension in `editors/vscode`: highlighting, live diagnostics,
  closing-tag insertion, snippets, and build_runner commands.
- The examples are now written in dartx; the runtime `jsx(r'…')` template
  syntax and its precompiler are unchanged and still supported.

**Less boilerplate.**

- New `package:reactx/events.dart`: `onValue`, `onChecked`, `onKey`, `on`,
  `valueOf`, `checkedOf`, `keyOf`, `targetIdOf`, `preventDefault`,
  `stopPropagation`, `listenKeys`. Reading an input's value no longer needs a
  hand-written js_interop shim per app — and no longer needs `dynamic`, which
  silently broke under dart2js. The barrel is conditionally exported, so
  component code that uses it still imports on the VM and in tests.
- Entrypoints take a component directly: `runApp(App)`, `hydrateApp(App)`,
  `renderToString(App)`, `renderToDocument(App, …)`. Passing a `VNode` (for
  props: `use(App, {'title': 'Hi'})`) works exactly as before, via `asVNode`.

**Reconciler.**

- Identical-`VNode` bailout: re-rendering the same node instance skips its
  subtree — the equivalent of Flutter's `const` widget short-circuit. Fibers in
  the skipped subtree can still update themselves via `setState`.
- Dirty-flag dedupe: a fiber refreshed by a dirty ancestor is dropped from the
  same flush instead of rendering twice.
- Stable event listeners: the host listener is a trampoline that reads the
  current handler off the fiber, so an inline `onClick={() => …}` closure no
  longer detaches and re-attaches on every render. On the example calculator
  this took a keypress from 38 listener operations to 0, with DOM mutations
  unchanged at 1. Fixes handlers not being unbound when a prop went from a
  function to `null`.

## 0.1.0

Initial release — React, reimplemented in pure Dart.

- Virtual DOM (`VNode`) with `h()` hyperscript and HTML element helpers.
- Function components with hooks: `useState`, `useReducer`, `useEffect`,
  `useLayoutEffect`, `useMemo`, `useCallback`, `useRef`, `useContext`.
- Context via `createContext` / providers.
- Host-agnostic reconciler: fiber tree, keyed reconciliation, effect
  scheduling, batched `act()`, and hydration — all testable headlessly through
  an in-memory `TestHost`.
- Server-side rendering: `renderToString` / `renderToDocument`.
- Browser client renderer over `package:web`: `runApp` / `hydrateApp`.
- `jsx(...)` template syntax: an HTML/JSX-like runtime compiler with a parse
  cache.
- Optional `build_runner` precompiler that turns `jsx(r'...')` calls into direct
  `h(...)` construction.
