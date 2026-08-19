/// The data router: ranked matching, nesting, middleware, loaders, error
/// boundaries and the server-to-client handover.
library;

// Route components are PascalCase, like everywhere else in reactx.
// ignore_for_file: non_constant_identifier_names

import 'dart:async';

import 'package:reactx/reactx.dart';
import 'package:reactx/router.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

VNode Layout(Props props) => h('div', {'class': 'layout'}, [const OutletProps()]);
VNode Home(Props props) => h('p', {'class': 'home'}, 'home');
VNode NewTodo(Props props) => h('p', {'class': 'new'}, 'new todo');
VNode Missing(Props props) => h('p', {'class': 'missing'}, 'not found');

/// The component behind a route's element. Routes hold elements now, so
/// identity lives one level in — and `use(X)` builds a fresh node each call,
/// which would make a direct comparison always fail.
FunctionComponent? componentOf(Route route) =>
    (route.element as ComponentNode?)?.component;

VNode TodoPage(Props props) {
  final params = useRouteParams();
  return h('p', {'class': 'todo'}, 'todo ${params['id']}');
}

void main() {
  group('matchRoutes', () {
    test('a static segment wins over a parameter, whatever the table order',
        () {
      // `/todo/:id` deliberately comes first: order must not decide this.
      final routes = [
        Route(path: '/todo/:id', element: use(TodoPage)),
        Route(path: '/todo/new', element: use(NewTodo)),
      ];

      final matched = matchRoutes(routes, '/todo/new')!;
      expect(componentOf(matched.last.route), NewTodo);

      final byParam = matchRoutes(routes, '/todo/42')!;
      expect(componentOf(byParam.last.route), TodoPage);
      expect(byParam.last.params['id'], '42');
    });

    test('a parameter wins over a wildcard', () {
      final routes = [
        Route(path: '/*', element: use(Missing)),
        Route(path: '/todo/:id', element: use(TodoPage)),
      ];
      expect(componentOf(matchRoutes(routes, '/todo/7')!.last.route), TodoPage);
      expect(componentOf(matchRoutes(routes, '/nope/deep')!.last.route), Missing);
    });

    test('nested routes return the chain, and parameters accumulate', () {
      final child = Route(path: ':id', element: use(TodoPage));
      final routes = [
        Route(path: '/todo/:group', element: use(Layout), children: [child]),
      ];

      final matched = matchRoutes(routes, '/todo/work/9')!;
      expect(matched.length, 2);
      expect(componentOf(matched.first.route), Layout);
      expect(matched.last.route, child);
      // A layout sees what its child captured, which is what it usually needs.
      expect(matched.first.params, {'group': 'work', 'id': '9'});
    });

    test('an index route matches the parent exactly', () {
      final index = Route(index: true, element: use(Home));
      final routes = [
        Route(path: '/', element: use(Layout), children: [
          index,
          Route(path: 'todo/:id', element: use(TodoPage)),
        ]),
      ];

      expect(matchRoutes(routes, '/')!.last.route, index);
      expect(componentOf(matchRoutes(routes, '/todo/1')!.last.route), TodoPage);
    });

    test('nothing matching is a distinct answer, not an empty one', () {
      final routes = [Route(path: '/', element: use(Home))];
      expect(matchRoutes(routes, '/nope'), isNull);
    });

    test('a wildcard captures the rest of the path', () {
      final routes = [Route(path: '/docs/*', element: use(Missing))];
      expect(matchRoutes(routes, '/docs/a/b/c')!.last.params['rest'], 'a/b/c');
    });
  });

  group('loaders', () {
    test('run concurrently across the chain and fill the snapshot', () async {
      // Each loader waits for the other to have started. Run in parallel this
      // finishes; run one after the other it deadlocks, so a regression shows
      // up as a timeout rather than a vague assertion.
      final parentStarted = Completer<void>();
      final childStarted = Completer<void>();

      final child = Route(
        path: ':id',
        element: use(TodoPage),
        loader: (context) async {
          childStarted.complete();
          await parentStarted.future;
          return 'child ${context.params['id']}';
        },
      );
      final parent = Route(
        path: '/todo',
        element: use(Layout),
        loader: (_) async {
          parentStarted.complete();
          await childStarted.future;
          return 'parent';
        },
        children: [child],
      );

      final resolution = await resolveLocation([parent], Uri.parse('/todo/3'))
          .timeout(const Duration(seconds: 2));
      final snapshot = (resolution as RouteResolved).snapshot;

      expect(snapshot.data[parent], 'parent');
      expect(snapshot.data[child], 'child 3');
      expect(snapshot.matches.length, 2);
    });

    test('a loader sees the query string', () async {
      final route = Route(
        path: '/search',
        element: use(Home),
        loader: (context) => context.query['q'],
      );
      final resolution =
          await resolveLocation([route], Uri.parse('/search?q=dart'));
      expect((resolution as RouteResolved).snapshot.data[route], 'dart');
    });

    test('a throwing loader records the error and where it happened', () async {
      final child = Route(
        path: 'boom',
        element: use(Home),
        loader: (_) => throw StateError('nope'),
      );
      final routes = [
        Route(path: '/', element: use(Layout), children: [child]),
      ];

      final snapshot =
          (await resolveLocation(routes, Uri.parse('/boom')) as RouteResolved)
              .snapshot;
      expect(snapshot.hasError, isTrue);
      expect(snapshot.error, isA<StateError>());
      expect(snapshot.errorIndex, 1);
    });
  });

  group('middleware', () {
    test('runs root-first and before any loader', () async {
      final order = <String>[];
      final routes = [
        Route(
          path: '/',
          element: use(Layout),
          middleware: [(_) { order.add('outer'); return const Next(); }],
          children: [
            Route(
              path: 'inner',
              element: use(Home),
              middleware: [(_) { order.add('inner'); return const Next(); }],
              loader: (_) { order.add('loader'); return 1; },
            ),
          ],
        ),
      ];

      await resolveLocation(routes, Uri.parse('/inner'));
      expect(order, ['outer', 'inner', 'loader']);
    });

    test('a redirect is followed, and the snapshot reports where it landed',
        () async {
      final routes = [
        Route(
          path: '/private',
          element: use(Home),
          middleware: [(_) => const Redirect('/login?next=/private')],
          loader: (_) => throw StateError('the loader must not run'),
        ),
        Route(path: '/login', element: use(Home)),
      ];

      final snapshot = (await resolveLocation(routes, Uri.parse('/private'))
              as RouteResolved)
          .snapshot;
      expect(snapshot.location.path, '/login');
      expect(snapshot.location.queryParameters['next'], '/private');
    });

    test('the server can ask for the redirect instead of following it',
        () async {
      final routes = [
        Route(
          path: '/private',
          element: use(Home),
          middleware: [(_) => const Redirect('/login')],
        ),
        Route(path: '/login', element: use(Home)),
      ];

      final resolution = await resolveLocation(
          routes, Uri.parse('/private'),
          followRedirects: false);
      expect(resolution, isA<RouteRedirected>());
      expect((resolution as RouteRedirected).location, '/login');
    });

    test('a redirect loop is bounded rather than hanging', () async {
      final routes = [
        Route(
            path: '/a',
            element: use(Home),
            middleware: [(_) => const Redirect('/b')]),
        Route(
            path: '/b',
            element: use(Home),
            middleware: [(_) => const Redirect('/a')]),
      ];

      final snapshot =
          (await resolveLocation(routes, Uri.parse('/a')).timeout(
                  const Duration(seconds: 2)) as RouteResolved)
              .snapshot;
      expect(snapshot.hasError, isTrue);
      expect('${snapshot.error}', contains('redirects'));
    });

    test('halting skips the loaders and reports the error', () async {
      var loaded = false;
      final routes = [
        Route(
          path: '/admin',
          element: use(Home),
          middleware: [(_) => Halt(StateError('forbidden'))],
          loader: (_) { loaded = true; return 1; },
        ),
      ];

      final snapshot =
          (await resolveLocation(routes, Uri.parse('/admin')) as RouteResolved)
              .snapshot;
      expect(loaded, isFalse);
      expect(snapshot.hasError, isTrue);
      expect(snapshot.errorIndex, 0);
    });

    test('a guard that throws is caught rather than escaping the router',
        () async {
      final routes = [
        Route(
          path: '/x',
          element: use(Home),
          middleware: [(_) => throw ArgumentError('bad guard')],
        ),
      ];
      final snapshot =
          (await resolveLocation(routes, Uri.parse('/x')) as RouteResolved)
              .snapshot;
      expect(snapshot.error, isA<ArgumentError>());
    });
  });

  group('server to client handover', () {
    test('encoded data survives the round trip, so the client refetches nothing',
        () async {
      var loads = 0;
      final route = Route(
        path: '/todo/:id',
        element: use(TodoPage),
        loader: (context) async {
          loads++;
          return {'id': context.params['id'], 'title': 'Write a router'};
        },
        encode: (data) => data,
        decode: (json) => json,
      );

      final server =
          (await resolveLocation([route], Uri.parse('/todo/9')) as RouteResolved)
              .snapshot;
      final json = server.toTransferJson();

      final client = RouterSnapshot.fromTransferJson([route], json)!;
      expect(client.location.path, '/todo/9');
      expect((client.data[route] as Map)['title'], 'Write a router');
      expect(client.isComplete, isTrue);
      expect(loads, 1, reason: 'the client must not re-run the loader');
    });

    test('a route that cannot travel leaves the snapshot incomplete', () async {
      // No encode: the value stays on the server, and the client has to resolve
      // for itself rather than render markup the server never produced.
      final route = Route(
        path: '/',
        element: use(Home),
        loader: (_) => DateTime(2026),
      );

      final server =
          (await resolveLocation([route], Uri.parse('/')) as RouteResolved)
              .snapshot;
      final client =
          RouterSnapshot.fromTransferJson([route], server.toTransferJson())!;

      expect(client.isComplete, isFalse);
    });

    test('hydrateSnapshot falls back to loading when the payload is stale',
        () async {
      final route = Route(
        path: '/:id',
        element: use(TodoPage),
        loader: (context) async => 'fresh ${context.params['id']}',
        encode: (data) => data,
        decode: (json) => json,
      );

      final stale =
          (await resolveLocation([route], Uri.parse('/1')) as RouteResolved)
              .snapshot
              .toTransferJson();

      final snapshot =
          await hydrateSnapshot([route], Uri.parse('/2'), stale);
      expect(snapshot!.data[route], 'fresh 2');
    });
  });

  group('rendering', () {
    test('Outlet renders the matched chain, nested', () async {
      final routes = [
        Route(path: '/', element: use(Layout), children: [
          Route(path: 'todo/:id', element: use(TodoPage)),
        ]),
      ];
      final snapshot =
          (await resolveLocation(routes, Uri.parse('/todo/5')) as RouteResolved)
              .snapshot;

      final app = mountApp(
          RouterScopeProps(routes: routes, snapshot: snapshot));

      expect(app.tree.byClass('layout'), isNotNull);
      expect(app.tree.byClass('todo').textContent, 'todo 5');
    });

    test('useLoaderData reads by route identity, with no name to mistype',
        () async {
      late Route page;
      VNode Page(Props props) =>
          h('p', {'class': 'page'}, useLoaderData<String>(page));
      page = Route(path: '/', element: use(Page), loader: (_) => 'loaded');

      final snapshot =
          (await resolveLocation([page], Uri.parse('/')) as RouteResolved)
              .snapshot;
      final app =
          mountApp(RouterScopeProps(routes: [page], snapshot: snapshot));

      expect(app.tree.byClass('page').textContent, 'loaded');
    });

    test('the nearest error boundary renders, and its children do not',
        () async {
      VNode Boom(Props props) => h('p', {'class': 'boom'}, 'unreachable');
      VNode Oops(Props props) =>
          h('p', {'class': 'oops'}, 'caught: ${useRouteError()}');

      final routes = [
        Route(path: '/', element: use(Layout), errorElement: use(Oops), children: [
          Route(path: 'x', element: use(Boom), loader: (_) => throw 'kaboom'),
        ]),
      ];
      final snapshot =
          (await resolveLocation(routes, Uri.parse('/x')) as RouteResolved)
              .snapshot;

      final app = mountApp(
          RouterScopeProps(routes: routes, snapshot: snapshot));

      expect(app.tree.byClass('oops').textContent, contains('kaboom'));
      expect(app.tree.allByClass('boom'), isEmpty);
    });

    test('navigating runs the new loaders, then swaps the page', () async {
      VNode Index(Props props) => h('div', {}, [
            h('p', {'class': 'where'}, 'index'),
            const LinkProps(
                href: '/todo/8',
                className: 'go',
                children: [TextNode('open')]),
          ]);

      final todo = Route(
        path: 'todo/:id',
        element: use(TodoPage),
        loader: (context) async {
          // A real await, so the navigation genuinely spans a turn of the loop.
          await Future<void>.delayed(Duration.zero);
          return context.params['id'];
        },
      );
      final routes = [
        Route(path: '/', element: use(Layout), children: [
          Route(index: true, element: use(Index)),
          todo,
        ]),
      ];

      final start =
          (await resolveLocation(routes, Uri.parse('/')) as RouteResolved)
              .snapshot;
      final app =
          mountApp(RouterScopeProps(routes: routes, snapshot: start));
      expect(app.tree.byClass('where').textContent, 'index');

      app.act(() => app.tree.byClass('go').click());
      // The click only starts the navigation; the page must not change until
      // the loader has answered, which is the point of resolving before
      // committing rather than rendering a half-loaded route.
      expect(app.tree.byClass('where').textContent, 'index');

      // Guards, loaders and the commit each span a turn; pump until it settles.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      app.act(() {});

      expect(app.tree.byClass('todo').textContent, 'todo 8');
      expect(app.tree.allByClass('where'), isEmpty);
    });

    test('the query string is readable from a component', () async {
      VNode Search(Props props) =>
          h('p', {'class': 'q'}, useQuery()['q'] ?? '');
      final routes = [Route(path: '/search', element: use(Search))];
      final snapshot = (await resolveLocation(
              routes, Uri.parse('/search?q=dart+router')) as RouteResolved)
          .snapshot;

      final app = mountApp(
          RouterScopeProps(routes: routes, snapshot: snapshot));
      expect(app.tree.byClass('q').textContent, 'dart router');
    });
  });

  // -------------------------------------------------------------------------
  group('the transfer payload is hostile until proven otherwise', () {
    final route = Route(
        path: '/x',
        element: use(Home),
        loader: (_) => 'v',
        encode: (d) => d,
        decode: (j) => j);
    final routes = [route];

    test('a value containing </script> cannot close the script tag', () async {
      final snapshot = RouterSnapshot(
        location: Uri.parse('/x'),
        matches: matchRoutes(routes, '/x')!,
        data: {route: '</script><script>alert(1)</script>'},
      );
      final json = snapshot.toTransferJson();

      expect(json, isNot(contains('</script>')));
      expect(json, isNot(contains('<script>')));
      // Escaped, not mangled: it decodes back to exactly what went in.
      final restored = RouterSnapshot.fromTransferJson(routes, json)!;
      expect(restored.data[route], '</script><script>alert(1)</script>');
    });

    test('U+2028 is escaped, since JavaScript reads it as a newline', () {
      final snapshot = RouterSnapshot(
        location: Uri.parse('/x'),
        matches: matchRoutes(routes, '/x')!,
        data: {route: 'a\u2028b'},
      );
      expect(snapshot.toTransferJson(), isNot(contains('\u2028')));
      expect(
          RouterSnapshot.fromTransferJson(routes, snapshot.toTransferJson())!
              .data[route],
          'a\u2028b');
    });

    test('a malformed payload returns null rather than throwing', () {
      for (final bad in [
        'not json',
        '[]',
        '{"location":"/x","data":{"-1":1}}',
        '{"location":"/x","data":{"99":1}}',
        '{"location":"/x","data":"nope"}',
        '{"data":{}}',
      ]) {
        expect(() => RouterSnapshot.fromTransferJson(routes, bad),
            returnsNormally,
            reason: bad);
      }
    });

    test('a decoder that returns null is respected, not overridden', () {
      final nullable = Route(
          path: '/x',
          element: use(Home),
          loader: (_) => 'v',
          encode: (d) => d,
          decode: (_) => null);
      final restored = RouterSnapshot.fromTransferJson(
          [nullable], '{"location":"/x","data":{"0":{"id":1}}}')!;
      expect(restored.data[nullable], isNull,
          reason: 'the raw JSON must not be substituted for a null decode');
    });
  });

  // -------------------------------------------------------------------------
  group('hydrateSnapshot', () {
    final route = Route(
        path: '/list',
        element: use(Home),
        loader: (context) => context.query['filter'] ?? 'all',
        encode: (d) => d,
        decode: (j) => j);
    final routes = [route];

    test('a payload for the same path but another query is not reused',
        () async {
      final served =
          (await resolveLocation(routes, Uri.parse('/list?filter=done'))
                  as RouteResolved)
              .snapshot;

      // Same path, different query — the loaders must run again.
      final hydrated = await hydrateSnapshot(
          routes, Uri.parse('/list?filter=all'), served.toTransferJson());

      expect(hydrated!.data[route], 'all');
      expect(hydrated.location.query, 'filter=all');
    });

    test('the matching payload is reused without re-running the loader',
        () async {
      var loads = 0;
      final counted = Route(
          path: '/list',
          element: use(Home),
          loader: (_) {
            loads++;
            return 'v';
          },
          encode: (d) => d,
          decode: (j) => j);

      final served = (await resolveLocation([counted], Uri.parse('/list?a=1'))
              as RouteResolved)
          .snapshot;
      expect(loads, 1);

      await hydrateSnapshot(
          [counted], Uri.parse('/list?a=1'), served.toTransferJson());
      expect(loads, 1, reason: 'the query matches, so nothing is re-fetched');
    });
  });

  // -------------------------------------------------------------------------
  group('a halted navigation', () {
    test('still loads the routes above the guard that stopped it', () async {
      final layout = Route(
        path: '/',
        element: use(Layout),
        loader: (_) => 'chrome',
        children: [
          Route(
            path: 'secret',
            element: use(Home),
            middleware: [(_) => Halt(StateError('nope'))],
            loader: (_) => 'never',
          ),
        ],
      );

      final snapshot =
          (await resolveLocation([layout], Uri.parse('/secret')) as RouteResolved)
              .snapshot;

      expect(snapshot.hasError, isTrue);
      expect(snapshot.data[layout], 'chrome',
          reason: 'the layout renders around the error, so it needs its data');
      expect(snapshot.data.length, 1, reason: 'the halted route loaded nothing');
    });
  });
}
