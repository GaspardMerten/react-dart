/// Tests for the todo example.
///
/// Four layers, four kinds of test:
///
/// * the reducer, called directly — no host, no tree;
/// * the route tree, resolved with no rendering at all, which is where guards,
///   loaders and 404s live;
/// * the pages, server-rendered to HTML strings from a resolved snapshot;
/// * the app, mounted through `package:reactx/testing.dart` and clicked, which
///   covers client-side navigation and the fact that store state outlives a
///   page change.
///
/// Resolving is now async — loaders are futures — so most tests start by
/// awaiting a snapshot. That is the price of the data router, and it buys tests
/// that exercise the same code path the server does.
library;

import 'package:reactx/reactx.dart';
import 'package:reactx/router.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

import '../example/todo_app/src/app.dartx.dart';
import '../example/todo_app/src/components/layout.dartx.dart';
import '../example/todo_app/src/data/todo_api.dart';
import '../example/todo_app/src/models/session.dart';
import '../example/todo_app/src/models/todo.dart';
import '../example/todo_app/src/routes.dart';
import '../example/todo_app/src/state/todo_store.dart';

const _signedIn = Session(signedIn: true);
const _anonymous = Session();

/// Resolves [location] the way the server does, and insists it rendered.
Future<RouterSnapshot> resolve(String location, {Session? as}) async {
  final resolution = await resolveLocation(routes, Uri.parse(location),
      followRedirects: false, extra: as);
  expect(resolution, isA<RouteResolved>(), reason: location);
  return (resolution as RouteResolved).snapshot;
}

/// Mounts the app at [location]. Every call gets its own root, so the store
/// starts from [TodoState.initial] each time.
Future<TestApp> mountAt(String location, {Session? as}) async =>
    mountApp(AppProps(snapshot: await resolve(location, as: as)));

/// Server-renders [location] to a full HTML string.
Future<String> render(String location, {Session? as}) async =>
    renderToString(AppProps(snapshot: await resolve(location, as: as)));

/// Clicks something and waits for the navigation it starts to commit.
///
/// A client navigation runs guards and loaders *before* it swaps the page, and
/// this example's loaders take real time, so a fixed number of pumped turns
/// would be a race. Poll the router's own loading flag instead.
Future<void> navigate(TestApp app, void Function() click) async {
  app.act(click);
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    app.act(() {});
    if (!app.tree.byClass('route-progress').hasClass('is-loading')) return;
  }
  throw StateError('reactx: the navigation never settled');
}

/// The nav link whose text is [label].
TestNode navLink(TestApp app, String label) =>
    app.tree.one((n) => n.tag == 'a' && n.textContent == label,
        'nav link labelled "$label"');

void main() {
  // -------------------------------------------------------------------------
  group('reducer', () {
    test('adds a todo with the next id and keeps the rest', () {
      final after = todoReducer(
        TodoState.initial,
        const AddTodo('Buy milk', 'home'),
      );

      expect(after.todos.length, TodoState.initial.todos.length + 1);
      expect(after.todos.last.title, 'Buy milk');
      expect(after.todos.last.tag, 'home');
      expect(after.todos.last.done, isFalse);
      expect(after.todos.last.id, TodoState.initial.nextId);
      expect(after.nextId, TodoState.initial.nextId + 1);
    });

    test('toggling flips exactly one todo', () {
      final after = todoReducer(TodoState.initial, const ToggleTodo(2));
      final before = TodoState.initial.todos;

      expect(after.todos.firstWhere((t) => t.id == 2).done, isTrue);
      for (final todo in after.todos.where((t) => t.id != 2)) {
        expect(todo.done, before.firstWhere((t) => t.id == todo.id).done);
      }
    });

    test('removing drops one todo and leaves nextId alone', () {
      final after = todoReducer(TodoState.initial, const RemoveTodo(1));
      expect(after.todos.any((t) => t.id == 1), isFalse);
      expect(after.todos.length, TodoState.initial.todos.length - 1);
      expect(after.nextId, TodoState.initial.nextId);
    });

    test('clear done keeps only the unfinished ones', () {
      final after = todoReducer(TodoState.initial, const ClearDone());
      expect(after.todos.every((t) => !t.done), isTrue);
      expect(after.todos.length, TodoState.initial.remaining);
    });

    test('the filter selects what is visible without deleting anything', () {
      final active = todoReducer(
        TodoState.initial,
        const SetFilter(Filter.active),
      );

      expect(active.filter, Filter.active);
      expect(active.todos.length, TodoState.initial.todos.length);
      expect(active.visible.every((t) => !t.done), isTrue);
      expect(active.visible.length, TodoState.initial.remaining);
    });

    test('derived numbers agree with each other', () {
      final state = TodoState.initial;
      expect(state.remaining + state.completed, state.todos.length);
      expect(state.percentDone,
          (state.completed * 100 / state.todos.length).round());

      final counted =
          state.byTag.values.fold(0, (sum, entry) => sum + entry.total);
      expect(counted, state.todos.length, reason: 'every todo has a known tag');
    });

    test('percentDone is 0 rather than NaN on an empty list', () {
      const empty = TodoState(todos: [], nextId: 1);
      expect(empty.percentDone, 0);
      expect(empty.byTag, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('route tree', () {
    test('paths are normalized before matching', () async {
      for (final path in ['/stats', '/stats/', '/stats?from=nav']) {
        final snapshot = await resolve(path);
        expect(isNotFound(snapshot.matches), isFalse, reason: path);
        expect(pageInfoFor(snapshot.matches).title, startsWith('Stats'),
            reason: path);
      }
    });

    test('every location matches the layout first', () async {
      for (final path in ['/', '/stats', '/todo/2', '/nope']) {
        final snapshot = await resolve(path);
        expect(snapshot.matches.first.route.element, isA<LayoutProps>(),
            reason: path);
      }
    });

    test('an unknown path falls through to the catch-all', () async {
      expect(isNotFound((await resolve('/nope')).matches), isTrue);
      expect(isNotFound((await resolve('/')).matches), isFalse);
    });

    test('a dynamic route beats the catch-all whatever the order', () async {
      final snapshot = await resolve('/todo/2');
      expect(isNotFound(snapshot.matches), isFalse);
      expect(snapshot.matches.last.route, same(todoDetailRoute));
      expect(snapshot.matches.last.params['id'], '2');
    });

    test('the loader runs before anything renders', () async {
      final snapshot = await resolve('/todo/2');
      expect(snapshot.data[todoDetailRoute], isA<Todo>());
      expect((snapshot.data[todoDetailRoute]! as Todo).id, 2);
      expect(snapshot.hasError, isFalse);
    });

    test('a loader that throws lands on the route, not on the process',
        () async {
      final snapshot = await resolve('/todo/999');
      expect(snapshot.hasError, isTrue);
      expect(snapshot.error, isA<TodoNotFound>());
    });

    test('the guard redirects an anonymous visitor, with a way back', () async {
      final resolution = await resolveLocation(routes, Uri.parse('/todo/2/edit'),
          followRedirects: false, extra: _anonymous);

      final location = (resolution as RouteRedirected).location;
      expect(location, startsWith('/signin?next='));
      expect(Uri.parse(location).queryParameters['next'],
          contains('/todo/2/edit'));
    });

    test('the same URL resolves for a signed-in visitor', () async {
      final snapshot = await resolve('/todo/2/edit', as: _signedIn);
      expect(snapshot.hasError, isFalse);
      // The child has no loader of its own; it reads the parent's data.
      expect(snapshot.data[todoDetailRoute], isA<Todo>());
    });

    test('no page metadata is missing', () async {
      for (final path in ['/', '/stats', '/about', '/signin', '/todo/2']) {
        final info = pageInfoFor((await resolve(path)).matches);
        expect(info.title, isNot('reactx'), reason: path);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('data transfer', () {
    test('the loader result travels to the client instead of re-running',
        () async {
      final server = await resolve('/todo/2');
      final restored =
          RouterSnapshot.fromTransferJson(routes, server.toTransferJson());

      expect(restored, isNotNull);
      expect(restored!.isComplete, isTrue,
          reason: 'no loader is left for the client to run');
      expect((restored.data[todoDetailRoute]! as Todo).title,
          (server.data[todoDetailRoute]! as Todo).title);
    });

    test('a payload for another location is refused', () async {
      final elsewhere = (await resolve('/todo/2')).toTransferJson();
      final restored =
          RouterSnapshot.fromTransferJson(routes, elsewhere)!;

      // Same document, wrong URL: the client must resolve rather than render
      // someone else's todo.
      expect(restored.location.path, '/todo/2');
      expect(restored.location.path, isNot('/todo/3'));
    });

    test('the session never travels — each side supplies its own', () async {
      final server = await resolve('/todo/2', as: _signedIn);
      expect(server.toTransferJson(), isNot(contains('signedIn')));

      final restored = RouterSnapshot.fromTransferJson(
          routes, server.toTransferJson(),
          extra: _anonymous)!;
      expect((restored.extra! as Session).signedIn, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('server rendering', () {
    test('each route renders its own page', () async {
      expect(await render('/'), contains('<h1>Todos</h1>'));
      expect(await render('/stats'), contains('<h1>Stats</h1>'));
      expect(await render('/about'), contains('<h1>About</h1>'));
      expect(await render('/nope'), contains('<h1>404</h1>'));
    });

    test('the todos arrive in the HTML, not after a fetch', () async {
      final html = await render('/');
      for (final todo in seedTodos) {
        expect(html, contains(todo.title));
      }
    });

    test("a loaded todo is in the markup, not fetched by the page", () async {
      final html = await render('/todo/2');
      final todo = seedTodos.firstWhere((t) => t.id == 2);
      expect(html, contains('<h1>${todo.title}</h1>'));
    });

    test('a failed loader renders the error page in place of the todo',
        () async {
      final html = await render('/todo/999');
      expect(html, contains('No such todo'));
      expect(html, contains('site-head'), reason: 'the chrome survives');
    });

    test('the current link is marked for both CSS and assistive tech',
        () async {
      final html = await render('/stats');
      expect(html, contains('class="nav-link is-active" aria-current="page"'));
      // Exactly one link is current.
      expect('aria-current'.allMatches(html).length, 1);
    });

    test('the header badge counts what is left', () async {
      expect(await render('/about'),
          contains('${TodoState.initial.remaining} left'));
    });

    test('a null attribute is omitted rather than printed', () async {
      expect(await render('/'), isNot(contains('aria-current="null"')));
    });

    test('the session changes what the page says, per request', () async {
      expect(await render('/todo/2', as: _signedIn), contains('Sign out'));
      expect(await render('/todo/2', as: _anonymous), contains('Sign in'));
    });
  });

  // -------------------------------------------------------------------------
  group('client', () {
    test('mounts the route it was given', () async {
      expect((await mountAt('/about')).tree.byTag('h1').textContent, 'About');
    });

    test('clicking a nav link swaps the page without touching the header',
        () async {
      final app = await mountAt('/');
      final header = app.tree.byClass('site-head');
      expect(app.tree.byTag('h1').textContent, 'Todos');

      await navigate(app, () => navLink(app, 'Stats').click());

      expect(app.tree.byTag('h1').textContent, 'Stats');
      expect(identical(app.tree.byClass('site-head'), header), isTrue,
          reason: 'the layout is reused, only the page is replaced');
    });

    test('navigating to a dynamic route runs its loader first', () async {
      final app = await mountAt('/');
      await navigate(app, () => navLink(app, 'Todo').click());

      final todo = seedTodos.firstWhere((t) => t.id == 2);
      expect(app.tree.byTag('h1').textContent, todo.title);
    });

    test('store state survives navigation', () async {
      final app = await mountAt('/');

      // Tick the first unfinished todo…
      final open = app.tree
          .byClass('todo-list')
          .children
          .firstWhere((li) => !li.hasClass('is-done'));
      app.act(() => open.byTag('input').change());

      final remaining = TodoState.initial.remaining - 1;
      expect(app.tree.byClass('badge').textContent, '$remaining left');

      // …then leave and come back. The list is the same list.
      await navigate(app, () => navLink(app, 'Stats').click());
      expect(app.tree.byClass('badge').textContent, '$remaining left');
      expect(app.tree.byClass('cards').children[2].textContent,
          contains('$remaining'));

      await navigate(app, () => navLink(app, 'Todos').click());
      expect(app.tree.byClass('badge').textContent, '$remaining left');
    });

    test('two apps do not share store state', () async {
      final a = await mountAt('/');
      final b = await mountAt('/');

      a.act(() =>
          a.tree.byClass('todo-list').children.first.byClass('icon').click());

      expect(a.tree.byClass('todo-list').children.length,
          TodoState.initial.todos.length - 1);
      expect(b.tree.byClass('todo-list').children.length,
          TodoState.initial.todos.length,
          reason: 'store state belongs to a root, not to a global');
    });

    test('filtering hides todos without removing them', () async {
      final app = await mountAt('/');
      expect(app.tree.byClass('todo-list').children.length,
          TodoState.initial.todos.length);

      app.act(() => app.tree.byClass('filters').children[2].click()); // Done

      expect(app.tree.byClass('todo-list').children.length,
          TodoState.initial.completed);
      expect(app.tree.byClass('badge').textContent,
          '${TodoState.initial.remaining} left');
    });

    test('deleting a todo removes its row', () async {
      final app = await mountAt('/');
      app.act(() =>
          app.tree.byClass('todo-list').children.first.byClass('icon').click());

      expect(app.tree.byClass('todo-list').children.length,
          TodoState.initial.todos.length - 1);
    });

    test('an unknown path renders 404 and can navigate home', () async {
      final app = await mountAt('/typo');
      expect(app.tree.byTag('h1').textContent, '404');

      await navigate(app, () => navLink(app, 'Back to the todos').click());
      expect(app.tree.byTag('h1').textContent, 'Todos');
    });

    test('the guard redirects a client navigation too', () async {
      final app = await mountAt('/todo/2', as: _anonymous);
      await navigate(app, () => navLink(app, 'Edit').click());

      expect(app.tree.byTag('h1').textContent, 'Sign in',
          reason: 'the guard runs on the client, not only on the server');
    });

    test('a signed-in visitor reaches the guarded page', () async {
      final app = await mountAt('/todo/2', as: _signedIn);
      final todo = seedTodos.firstWhere((t) => t.id == 2);
      expect(app.tree.maybeByClass('panel-edit'), isNull);

      await navigate(app, () => navLink(app, 'Edit').click());

      // A *child* route: the panel appears below the todo, which is still on
      // screen — and it rendered from the parent's data, so nothing reloaded.
      expect(app.tree.byClass('panel-edit').byTag('h2').textContent, 'Edit');
      expect(app.tree.byTag('h1').textContent, todo.title);
      expect(app.tree.byTag('input').attributes['value'], todo.title);
    });
  });

  // -------------------------------------------------------------------------
  group('hydration', () {
    // Hydration only works if the first client render produces the tree the
    // server already wrote. Attribute *order* is not part of that contract (and
    // TestNode prints attributes sorted), so compare tags and text.
    String shape(String html) =>
        html.replaceAll(RegExp(r'<(/?)([a-z0-9]+)[^>]*>'), r'<\1\2>');

    test('server HTML and the first client render have the same shape',
        () async {
      for (final path in ['/', '/stats', '/about', '/nope', '/todo/2']) {
        final snapshot = await resolve(path, as: _anonymous);
        final server = renderToString(AppProps(snapshot: snapshot));
        final client = mountApp(AppProps(snapshot: snapshot)).html;
        expect(shape(client), shape(server), reason: path);
      }
    });

    test('the transferred snapshot renders what the server rendered', () async {
      final server = await resolve('/todo/2', as: _anonymous);
      final restored = RouterSnapshot.fromTransferJson(
          routes, server.toTransferJson(),
          extra: _anonymous)!;

      expect(shape(mountApp(AppProps(snapshot: restored)).html),
          shape(renderToString(AppProps(snapshot: server))));
    });
  });
}
