/// The route tree: the one place that maps a URL to a page.
///
/// This is a `Route` tree rather than a flat table, so the router owns the
/// parts that are easy to get wrong — which route wins, whether you may open
/// it, and having its data ready before it renders. Both halves of the app read
/// this same list: the server to resolve a request, the client to resolve a
/// navigation.
///
/// Two things are worth reading closely:
///
/// * `*` is written *after* `todo/:id` and never steals from it, because
///   matching is ranked by specificity rather than by order. Shuffling this
///   file cannot change which page you get.
/// * `TodoEditPage` has no idea it is protected. `requireSignedIn` settles that
///   before any loader runs, so the page never has to remember to check.
library;

import 'package:reactx/router.dart';

import 'components/layout.dartx.dart';
import 'data/todo_api.dart';
import 'models/session.dart';
import 'models/todo.dart';
import 'pages/about_page.dartx.dart';
import 'pages/not_found_page.dartx.dart';
import 'pages/sign_in_page.dartx.dart';
import 'pages/stats_page.dartx.dart';
import 'pages/todo_detail_page.dartx.dart';
import 'pages/todo_edit_page.dartx.dart';
import 'pages/todo_error_page.dartx.dart';
import 'pages/todos_page.dartx.dart';

/// The id of the `<script>` the server's loader results ride in, agreed on by
/// `server.dart` (which writes it) and `main.dart` (which reads it). One
/// constant rather than the same string typed twice.
const routerTransferId = '__reactx_router';

/// Page metadata, hung off [Route.title]. The router never reads it; the server
/// uses it for `<title>` and the description meta tag.
class PageInfo {
  const PageInfo(this.title, this.description);
  final String title;
  final String description;
}

/// Sends anyone without a session to the sign-in page, remembering where they
/// were going.
///
/// A guard is a plain function: it gets the location and whatever the caller
/// passed as `extra`, and answers with [Next], [Redirect] or [Halt].
MiddlewareResult requireSignedIn(RouteContext context) {
  final session = context.extra;
  if (session is Session && session.signedIn) return const Next();
  return Redirect('/signin?next=${Uri.encodeComponent('${context.location}')}');
}

/// `/todo/:id` — declared on its own so pages can name it in `useLoaderData`.
///
/// The route object is the key. There is no `'todo'` string to keep in sync
/// between the table and the page that reads its data.
final todoDetailRoute = Route(
  path: 'todo/:id',
  element: const TodoDetailPageProps(),
  title: const PageInfo('Todo · reactx', 'One todo, loaded by its route.'),
  loader: (context) => fetchTodo(context.params['id']!),
  // With these, the server's fetch travels to the browser inside the page and
  // the client does not repeat it. Drop them and everything still works — the
  // client just loads it again.
  encode: (todo) => encodeTodo(todo! as Todo),
  decode: (json) => decodeTodo(json! as Map<String, Object?>),
  errorElement: const TodoErrorPageProps(),
  children: [
    Route(
      path: 'edit',
      element: const TodoEditPageProps(),
      title: const PageInfo('Edit · reactx', 'Behind a guard.'),
      middleware: [requireSignedIn],
    ),
  ],
);

/// The index route: what `/` renders.
///
/// It deliberately has *no* loader. The list is owned by `todoStore` and the
/// user edits it, so a loader here would fetch a value the page then ignores —
/// which is the wrong lesson. Loaders are for data the URL identifies and the
/// page cannot invent; `/todo/:id` below is that case.
final todosRoute = Route(
  index: true,
  element: const TodosPageProps(),
  title: const PageInfo(
      'Todos · reactx', 'A todo list rendered on the server, then hydrated.'),
);

/// The catch-all, named so the server can tell a 404 from a page.
final notFoundRoute = Route(
  path: '*',
  element: const NotFoundPageProps(),
  title: const PageInfo('Not found · reactx', 'No such page.'),
);

/// The whole tree. [Layout] is the root route: it renders the chrome and an
/// `<Outlet />` where the page goes.
final routes = <Route>[
  Route(
    path: '/',
    element: const LayoutProps(),
    children: [
      todosRoute,
      Route(
        path: 'stats',
        element: const StatsPageProps(),
        title: const PageInfo(
            'Stats · reactx', 'Progress by tag, derived from the store.'),
      ),
      Route(
        path: 'about',
        element: const AboutPageProps(),
        title: const PageInfo(
            'About · reactx', 'How this Dart app is put together.'),
      ),
      Route(
        path: 'signin',
        element: const SignInPageProps(),
        title: const PageInfo('Sign in · reactx', 'The guard sent you here.'),
      ),
      todoDetailRoute,
      notFoundRoute,
    ],
  ),
];

/// The metadata for a resolved location: the deepest route that carries any.
PageInfo pageInfoFor(List<RouteMatch> matches) {
  for (final match in matches.reversed) {
    if (match.route.title case final PageInfo info) return info;
  }
  return const PageInfo('reactx', 'A reactx app.');
}

/// Whether a resolved location fell through to the catch-all, so the server can
/// answer 404 rather than 200 with a "not found" page — a distinction crawlers
/// and monitoring both care about.
bool isNotFound(List<RouteMatch> matches) =>
    matches.isNotEmpty && identical(matches.last.route, notFoundRoute);
