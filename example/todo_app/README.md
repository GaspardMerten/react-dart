# One component tree, five routes, no JavaScript framework

A small but complete site built with `reactx`: a todo list, a todo detail page
loaded by its route, a guarded edit panel nested inside it, a stats page and an
about page — sharing one store, all server-rendered and then hydrated. Every URL
is a real URL that returns finished HTML.

```
dart run build_runner build                                          # .dartx -> .dart
dart compile js -O2 example/todo_app/main.dart -o example/todo_app/main.dart.js
dart run example/todo_app/server.dart                                # http://localhost:8080
```

Then try, in this order:

1. `curl -s localhost:8080/todo/2` — the whole page comes back rendered, the
   todo included. Its loader ran on the server; nothing is fetched afterwards.
2. Click **Stats** in the nav — no reload; only `<main>` changes.
3. Tick a todo on the list, go to **Stats** — the bars have already moved. Go
   back — the list is as you left it.
4. Click **Edit** on a todo — a guard sends you to `/signin`, because the URL
   alone does not say whether you may open it.
5. Sign in and click Edit again — the panel opens *below* the todo, at
   `/todo/2/edit`. It is a real location: reload it, or press Back to close it.
6. Visit `/todo/999` — the loader throws, the route's error element renders in
   place of the page, and the response is a real `404`.
7. Click the **reactx todos** brand — that one *is* a full round-trip, and the
   page looks identical. Server and client render the same tree.

## Layout

```
example/todo_app/
  server.dart              resolves any URL, renders it, serves the client bundle
  main.dart                hydrates the same tree in the browser
  src/
    app.dartx              the whole shell: one RouterScope
    routes.dart            what the folder names cannot say: the guard, the page
                           metadata type, and a re-export of the generated table
    routes.g.dart          GENERATED — the Route tree, written by build_runner
    styles.dart            the stylesheet, inlined into every response
    routes/                the URL space, as folders
      layout.dartx         the shell: header, nav, navigation indicator, footer
      page.dartx           /
      about/page.dartx     /about
      signin/page.dartx    /signin
      stats/page.dartx     /stats
      todo/[id]/
        page.dartx         /todo/:id       — loader, encode, decode, title
        error.dartx        that route's error boundary
        edit/page.dartx    /todo/:id/edit  — const middleware = [requireSignedIn]
      [...rest]/page.dartx anything else
    models/
      todo.dart            Todo, Filter, seed data — imports nothing from reactx
      session.dart         who is asking; the value a guard needs
    data/
      todo_api.dart        what a loader talks to — imports nothing from reactx
    state/
      todo_store.dart      actions, reducer, and one defineStore declaration
    components/
      todo_form.dartx      controlled input + tag select
      todo_item.dartx      one row
      filter_bar.dartx     All / Active / Done
      stat_card.dartx      a labelled number — the clearest look at typed props
```

**The route table is generated, not scanned.** `routes/` is the URL space, and
`dart run build_runner build` turns it into `routes.g.dart` — ordinary `Route`
objects, the file this example used to keep by hand. Open it: there is no magic
to take on faith, and a route the conventions cannot express is still a `Route`
you add to the list yourself. What each route *does* stays in its own page file,
picked up by name: `loader`, `middleware`, `encode`, `decode`, `title`.

The rule the structure follows: **each layer may only import from the layer
below it.** Pages use components and the store; components use the store and the
models; models and the data layer import nothing. That is why `todoReducer` and
the route tree can both be tested with no host, no DOM and no browser — see
`test/todo_app_test.dart`.

## The ideas worth stealing

**A component's parameters are its attributes.** `stat_card.dartx` is the whole
story:

```dart
Component StatCard({required String label, required int value}) => …;
```

`<StatCard label="Done" value={state.completed} />` compiles to
`StatCardProps(label: 'Done', value: state.completed)`, so a misspelled
attribute or a `String` where the `int` goes is a compile error on that line.
Nothing reads a map, and nothing casts.

**The resolved location is an argument, not a global.** `server.dart` renders
`AppProps(snapshot: snapshot)`; `main.dart` renders the same thing built from
the document it is hydrating. One server can resolve several requests
concurrently without them interfering — including their *sessions*, which is why
`Session` is passed to `resolveLocation(..., extra:)` rather than kept in a
static.

**The router owns what is easy to get wrong.** Which route wins is decided by
specificity, not by the order of the generated table. Whether you may open a route is
decided by `requireSignedIn` before any loader runs, so `TodoEditPage` has no
idea it is protected. And a route's data is fetched before its page renders, so
no page has a loading branch, a `useEffect`, or an opinion about which of the
server and the browser got there first.

**The server's fetches travel.** `snapshot.toTransferJson()` rides in the page;
`hydrateSnapshot` reuses it instead of loading `/todo/2` twice. Delete the
route's `encode`/`decode` and everything still works — the client just fetches
again.

**The store has no wrapper and no name.** `todoStore` is one `defineStore`
declaration; the object itself is the identity, so nothing wraps the tree and
there is no string to mistype. Its state lives on the root being rendered — the
client `Root`, or one server request's renderer — which is what keeps concurrent
SSR correct.

**Components subscribe to exactly what they read.** `useStore` for the whole
state, `useSelect(todoStore, (s) => s.remaining)` for the header badge (it does
not re-render when you switch filters), `useDispatch` for components that only
write (the form never re-renders when the list changes). Rows are `@memoized`,
so ticking one leaves the others alone.

**Platform differences live in one conditional export.** `package:reactx/router.dart`
resolves to the History API in the browser and to no-ops on the VM, so the whole
app stays testable on the Dart VM. Event access follows the same pattern through
`package:reactx/events.dart` — no `dynamic`, which silently breaks under
dart2js.

**Components are PascalCase, and now it is enforced.** dartx reads a lowercase
tag as an HTML element, so `<Layout>` only resolves to a component because the
function is capitalised — a lowercase `Component` function is a build error
saying so, rather than a tag that silently never matches.

## Things this example deliberately does not do

- **No persistence.** Reloading resets to the seed list, and the edit form is
  inert. Adding `localStorage` means reading it in a `useEffect` *after*
  hydration, not during the first render — otherwise the client's first tree
  differs from the server's.
- **No real backend.** `data/todo_api.dart` is the seed list plus a 120 ms
  delay. The delay is not decoration: it is why `useNavigation()` has something
  to report and why transferring the server's results is worth doing.
- **No signed session.** The cookie is a bare `1`. A real app would sign it, and
  would not let the client read it — here both halves read it so the guards
  reach the same verdict on both sides.
- **Typing into the form is browser-only.** `onValue` is a no-op on the VM
  (there is no DOM event to read), so the headless tests exercise `AddTodo`
  through the reducer and click everything else.
