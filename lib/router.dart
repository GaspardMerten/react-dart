/// Routing for reactx apps.
///
/// Import it from shared component code — like `package:reactx/events.dart` it
/// resolves the platform bits (the History API vs. nothing) with a conditional
/// export, so the same tree renders on the server and hydrates in the browser.
///
/// There are two levels, and you can start at either.
///
/// **A path in a context.** `RouterScope` takes a `path` and publishes it; your
/// app keeps its own table of paths to pages.
///
/// ```dart
/// // server: the request path is an argument, never a global
/// renderToDocument(AppProps(path: request.uri.path), …);
///
/// // client: the address bar says which route was served
/// hydrateApp(AppProps(path: currentPath()));
/// ```
///
/// **A route tree.** `RouterScope` takes `routes` and owns matching, guards and
/// data loading — nested layouts through `Outlet`, `middleware` that can
/// redirect before anything renders, and `loader`s whose results reach
/// components through `useLoaderData`. Matching is ranked by specificity, so
/// the order of your table never changes which page you get.
///
/// ```dart
/// final todoRoute = Route(
///   path: 'todo/:id',
///   element: const TodoPageProps(),
///   middleware: [requireAuth],
///   loader: (context) => fetchTodo(context.params['id']!),
///   encode: (todo) => (todo as Todo).toJson(),
///   decode: (json) => Todo.fromJson(json as Map<String, Object?>),
/// );
///
/// // server: resolve, then render — loaders have already run
/// final resolution = await resolveLocation(routes, request.uri);
///
/// // client: reuse the server's data instead of fetching it again
/// final snapshot = await hydrateSnapshot(routes, uri, transferJson);
/// ```
library;

export 'src/router/router.dartx.dart';
