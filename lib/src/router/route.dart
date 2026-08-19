/// The route tree: matching, middleware and data loading.
///
/// This half is deliberately free of components and of the DOM. Resolving a
/// location — deciding which routes match, running the guards, fetching the
/// data — is a pure async function over a route table, so the *same* code runs
/// on the server before it renders a response and in the browser before it
/// commits a navigation. Anything that behaved differently on the two sides
/// would show up as a hydration mismatch, which is the bug class this design
/// exists to remove.
///
/// ```dart
/// final routes = <Route>[
///   Route(path: '/', element: const LayoutProps(), children: [
///     Route(
///       index: true,
///       element: const TodosPageProps(),
///       loader: (_) => loadTodos(),
///     ),
///     Route(
///       path: 'todo/:id',
///       element: const TodoPageProps(),
///       middleware: [requireAuth],
///       loader: (context) => loadTodo(context.params['id']!),
///     ),
///     Route(path: '*', element: const NotFoundPageProps()),
///   ]),
/// ];
/// ```
library;

import 'dart:async';
import 'dart:convert';

import '../escape.dart';
import '../vdom.dart';

/// Data a [Route.loader] produced, or whatever a route needs from the request.
typedef Loader = FutureOr<Object?> Function(LoaderContext context);

/// A guard that runs before the loaders of the route it is attached to.
typedef Middleware = FutureOr<MiddlewareResult> Function(RouteContext context);

/// One node of the route tree.
///
/// A route is an object, and the object *is* its identity: [useLoaderData]
/// takes the route itself rather than a name, so there is no string to mistype,
/// renaming is an IDE operation, and two packages cannot collide on `'user'`.
final class Route {
  const Route({
    this.path,
    this.element,
    this.children = const [],
    this.index = false,
    this.loader,
    this.middleware = const [],
    this.encode,
    this.decode,
    this.errorElement,
    this.title,
  }) : assert(index == false || path == null,
            'an index route matches its parent exactly, so it takes no path');

  /// The pattern this route matches, relative to its parent unless it starts
  /// with `/`.
  ///
  /// Segments beginning with `:` capture a parameter; a lone `*` matches the
  /// rest of the path and captures it as `rest`.
  final String? path;

  /// Rendered when this route matches. Children render into its `<Outlet />`.
  ///
  /// It is an element rather than a component function — `const StatsPageProps()`
  /// or, in a `.dartx` file, `<StatsPage />` — because a typed component is
  /// named by the props type it takes, and a route has no arguments to pass it.
  final VNode? element;

  final List<Route> children;

  /// Whether this is the route to use when the parent matches exactly.
  final bool index;

  /// Fetches this route's data before it renders. Loaders across the matched
  /// chain run concurrently, so a nested route does not wait for its parent.
  final Loader? loader;

  /// Guards, run root-first, before any loader. Returning [Redirect] or [Halt]
  /// abandons the navigation without any loader having run.
  final List<Middleware> middleware;

  /// Turns this route's loader data into something JSON can carry, so the
  /// server's fetch can be reused by the browser instead of repeated.
  ///
  /// Leave both this and [decode] null and the client simply re-runs the loader
  /// after hydration — correct, just slower.
  final Object? Function(Object? data)? encode;

  /// Rebuilds the loader's value from what [encode] produced.
  final Object? Function(Object? json)? decode;

  /// Rendered in place of [element] when this route's loader or middleware
  /// throws. The nearest one at or above the failure wins.
  final VNode? errorElement;

  /// Free-form metadata — a page title, a layout hint, whatever your app needs.
  /// The router never reads it.
  final Object? title;
}

/// One route matched against a location, with the parameters it captured.
final class RouteMatch {
  const RouteMatch(this.route, this.params, this.pathname);

  final Route route;

  /// Every parameter captured so far, including the ancestors'.
  final Map<String, String> params;

  /// The part of the path this route and its ancestors consumed.
  final String pathname;
}

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

/// What a [Middleware] decided.
sealed class MiddlewareResult {
  const MiddlewareResult();
}

/// Carry on to the next guard, and eventually to the loaders.
final class Next extends MiddlewareResult {
  const Next();
}

/// Abandon this navigation and go somewhere else instead.
final class Redirect extends MiddlewareResult {
  const Redirect(this.location, {this.replace = true});

  /// Where to go, as a path that may carry a query string.
  final String location;

  /// Whether the aborted entry should be replaced rather than pushed — the
  /// usual choice for a guard, so Back does not bounce off it again.
  final bool replace;
}

/// Abandon this navigation and render the error boundary.
final class Halt extends MiddlewareResult {
  const Halt(this.error);
  final Object error;
}

/// What a guard is given.
class RouteContext {
  RouteContext({
    required this.location,
    required this.params,
    required this.match,
    this.extra,
  });

  /// The full target, query string included.
  final Uri location;

  final Map<String, String> params;

  /// The route this guard is attached to.
  final RouteMatch match;

  /// Whatever the caller of [resolveLocation] passed in — the request's session
  /// on the server, the browser's on the client.
  ///
  /// Guards need this. Whether a user may open a page is almost never a
  /// function of the URL alone, and a router that only hands over the location
  /// forces the answer into a global, which is exactly what breaks when one
  /// server renders two users' pages at once.
  final Object? extra;

  /// Shorthand for `location.queryParameters`.
  Map<String, String> get query => location.queryParameters;
}

/// What a loader is given: everything in [RouteContext], plus the values other
/// guards left behind.
class LoaderContext extends RouteContext {
  LoaderContext({
    required super.location,
    required super.params,
    required super.match,
    super.extra,
  });
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/// Splits a path into its segments, ignoring empties so `/a//b/` is `[a, b]`.
List<String> _segments(String path) =>
    path.split('/').where((s) => s.isNotEmpty).toList();

/// A root-to-leaf chain, flattened out of the tree so it can be scored.
class _Branch {
  _Branch(this.chain, this.pattern, this.score);

  final List<Route> chain;
  final List<String> pattern;

  /// Higher wins. Static text beats a parameter, which beats a wildcard, so
  /// `/todo/new` is preferred over `/todo/:id` no matter how the table is
  /// ordered — the ordering footgun other small routers leave you with.
  final int score;
}

const _staticScore = 10;
const _paramScore = 4;
const _wildcardScore = 1;
const _indexBonus = 2;

List<_Branch> _flatten(List<Route> routes) {
  final branches = <_Branch>[];

  void walk(Route route, List<Route> parents, List<String> prefix) {
    final chain = [...parents, route];
    var pattern = prefix;
    var score = 0;

    final path = route.path;
    if (path != null) {
      // A leading slash resets to the root, the way an absolute link does.
      pattern = path.startsWith('/')
          ? _segments(path)
          : [...prefix, ..._segments(path)];
      for (final segment in _segments(path)) {
        score += segment == '*'
            ? _wildcardScore
            : segment.startsWith(':')
                ? _paramScore
                : _staticScore;
      }
    }

    for (final child in route.children) {
      walk(child, chain, pattern);
    }

    // A route is matchable when it can terminate a match: an index route, a
    // leaf, or a parent that renders something of its own — `/todo/:id` is a
    // page *and* the parent of `/todo/:id/edit`, and refusing to match it at
    // its own path would be a strange thing for a router to insist on. An index
    // child still wins the exact path, through [_indexBonus].
    if (route.index || route.children.isEmpty || route.element != null) {
      branches.add(_Branch(
        chain,
        pattern,
        score + (route.index ? _indexBonus : 0) + _prefixScore(prefix),
      ));
    }
  }

  for (final route in routes) {
    walk(route, const [], const []);
  }

  branches.sort((a, b) => b.score != a.score
      ? b.score.compareTo(a.score)
      : b.pattern.length.compareTo(a.pattern.length));
  return branches;
}

/// Ancestors already contributed their own score through [prefix]; counting the
/// prefix again keeps deeper, more specific branches ahead of shallow ones.
int _prefixScore(List<String> prefix) => prefix.length;

/// The flattened, ranked branches of [routes], computed once per table.
///
/// Flattening walks the whole tree, allocates a branch per matchable route and
/// sorts them. A route table is built once and matched against on every request
/// and every navigation, so doing that work per match is pure waste. Keyed on
/// the list's identity, which is what an app has: one `final routes = [...]`.
final _branchCache = Expando<List<_Branch>>('reactx.routeBranches');

List<_Branch> _branchesOf(List<Route> routes) =>
    _branchCache[routes] ??= _flatten(routes);

/// Matches [path] against [routes], returning the chain from the root to the
/// matched leaf, or null when nothing matches.
///
/// Branches are tried most-specific first, so the order of your table does not
/// change the outcome.
List<RouteMatch>? matchRoutes(List<Route> routes, String path) {
  final actual = _segments(path);

  for (final branch in _branchesOf(routes)) {
    final params = <String, String>{};
    var consumed = 0;
    var matched = true;

    for (var i = 0; i < branch.pattern.length; i++) {
      final want = branch.pattern[i];
      if (want == '*') {
        params['rest'] = actual.skip(i).join('/');
        consumed = actual.length;
        break;
      }
      if (i >= actual.length) {
        matched = false;
        break;
      }
      if (want.startsWith(':')) {
        params[want.substring(1)] = Uri.decodeComponent(actual[i]);
      } else if (want != actual[i]) {
        matched = false;
        break;
      }
      consumed = i + 1;
    }

    if (!matched || consumed != actual.length) continue;

    // Every route in the chain sees the whole parameter set; a layout often
    // needs the id its child captured.
    var depth = 0;
    return [
      for (final route in branch.chain)
        RouteMatch(
          route,
          Map.unmodifiable(params),
          '/${branch.pattern.take(++depth).join('/')}',
        ),
    ];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// The outcome of resolving a location.
sealed class RouteResolution {
  const RouteResolution();
}

/// The location matched, the guards allowed it, and the data is loaded.
final class RouteResolved extends RouteResolution {
  const RouteResolved(this.snapshot);
  final RouterSnapshot snapshot;
}

/// A guard sent the navigation somewhere else.
final class RouteRedirected extends RouteResolution {
  const RouteRedirected(this.location, {this.replace = true});
  final String location;
  final bool replace;
}

/// Nothing matched. Give this its own case rather than a null so a 404 is a
/// decision the app makes, with a status code, rather than a blank screen.
final class RouteNotFound extends RouteResolution {
  const RouteNotFound(this.location);
  final Uri location;
}

/// Everything the tree needs to render one location.
final class RouterSnapshot {
  const RouterSnapshot({
    required this.location,
    required this.matches,
    required this.data,
    this.extra,
    this.error,
    this.errorIndex,
  });

  final Uri location;
  final List<RouteMatch> matches;

  /// Whatever was passed to [resolveLocation] — the session, usually. Never
  /// serialised: each side supplies its own, because it describes the caller
  /// rather than the page.
  final Object? extra;

  /// Loader results, keyed by the route object itself.
  final Map<Route, Object?> data;

  /// Set when a loader or guard threw; [errorIndex] is where in [matches].
  final Object? error;
  final int? errorIndex;

  bool get hasError => error != null;

  /// Whether every matched loader's data is present.
  ///
  /// A snapshot rebuilt on the client is incomplete when a route declined to
  /// travel — no [Route.encode] — and the caller has to resolve the location
  /// properly before hydrating, or the first client render will not match the
  /// server's markup.
  bool get isComplete => matches.every(
      (m) => m.route.loader == null || data.containsKey(m.route));

  /// The JSON the server embeds so the browser can skip the fetches the server
  /// already did.
  ///
  /// Only routes with an [Route.encode] are carried; the rest are re-loaded on
  /// the client, which is the safe default for values JSON cannot express.
  ///
  /// The result is **safe to put inside a `<script>` element**, which is the
  /// only place it is ever used. Four characters are escaped to their `\uXXXX`
  /// form: `<` and `>` so a loaded value containing `</script>` cannot close
  /// the tag and turn its own contents into markup, and U+2028/U+2029, which
  /// JSON permits raw inside a string but JavaScript treats as line
  /// terminators. JSON has no structural `<`, `>` or line separator, so this
  /// changes nothing about what parses back out.
  ///
  /// Doing it here rather than at the call site is deliberate: this is the
  /// function whose output is documented as going into a page, so this is where
  /// the escaping belongs. Leaving it to the caller means every app has to
  /// remember, and the one that forgets has stored XSS.
  String toTransferJson() {
    final entries = <String, Object?>{};
    for (var i = 0; i < matches.length; i++) {
      final route = matches[i].route;
      final encode = route.encode;
      if (encode == null || !data.containsKey(route)) continue;
      entries['$i'] = encode(data[route]);
    }
    return escapeForScript(jsonEncode({'location': '$location', 'data': entries}));
  }

  /// Rebuilds a snapshot on the client from [json], without running loaders.
  ///
  /// Returns null when the payload does not describe the location being
  /// hydrated — a stale document, say — so the caller falls back to resolving
  /// normally instead of rendering someone else's data.
  static RouterSnapshot? fromTransferJson(List<Route> routes, String json,
      {Object? extra}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;

    final location = Uri.tryParse(decoded['location'] as String? ?? '');
    if (location == null) return null;

    final matches = matchRoutes(routes, location.path);
    if (matches == null) return null;

    final payload = decoded['data'];
    final data = <Route, Object?>{};
    if (payload is Map<String, Object?>) {
      for (final entry in payload.entries) {
        final index = int.tryParse(entry.key);
        // A negative index parses fine and would index off the front of the
        // list. This function's whole contract is that a bad payload returns
        // null rather than throwing, so it has to be checked at both ends.
        if (index == null || index < 0 || index >= matches.length) continue;
        final route = matches[index].route;
        // `?? entry.value` would be wrong: a decoder that legitimately returns
        // null (a record that no longer exists) would get the raw JSON map
        // instead, and the page would fail on the cast rather than see null.
        final decode = route.decode;
        data[route] = decode == null ? entry.value : decode(entry.value);
      }
    }
    return RouterSnapshot(
        location: location, matches: matches, data: data, extra: extra);
  }
}

/// Runs the guards and loaders for [location] against [routes].
///
/// Guards run first and in order from the root down, so an outer `requireAuth`
/// settles the question before an inner route's loader can leak anything.
/// Loaders then run *concurrently*: they are independent by construction, and
/// serialising them would make a three-deep route three round-trips deep.
/// Pass `followRedirects: false` on the server to get [RouteRedirected] back
/// instead: a 302 with a `Location` header is a better answer than rendering
/// the destination under the original URL.
Future<RouteResolution> resolveLocation(
  List<Route> routes,
  Uri location, {
  int maxRedirects = 5,
  bool followRedirects = true,
  Object? extra,
}) async {
  var target = location;

  for (var hop = 0;; hop++) {
    final matches = matchRoutes(routes, target.path);
    if (matches == null) return RouteNotFound(target);

    final guarded = await _runMiddleware(matches, target, extra);
    if (guarded case final Redirect redirect) {
      if (!followRedirects) {
        return RouteRedirected('${_resolveAgainst(target, redirect.location)}',
            replace: redirect.replace);
      }
      if (hop >= maxRedirects) {
        return RouteResolved(RouterSnapshot(
          location: target,
          matches: matches,
          data: const {},
          extra: extra,
          error: StateError(
              'reactx router: more than $maxRedirects redirects, starting at '
              '$location'),
          errorIndex: 0,
        ));
      }
      // Loop rather than recurse so the redirect budget is obviously bounded.
      target = _resolveAgainst(target, redirect.location);
      continue;
    }
    if (guarded case (final Halt halt, final int index)) {
      // The routes *above* the halt still render — the error boundary is drawn
      // inside whatever layout was already allowed — so their loaders have to
      // run, or a layout calling `useLoaderData` throws instead of framing the
      // error. Only the halted route and its children are skipped.
      final allowed = await _runLoaders(matches.sublist(0, index), target, extra);
      return RouteResolved(RouterSnapshot(
        location: target,
        matches: matches,
        data: allowed.data,
        extra: extra,
        error: halt.error,
        errorIndex: index,
      ));
    }

    return RouteResolved(await _runLoaders(matches, target, extra));
  }
}

/// Runs guards root-first, returning the first non-[Next] result with the index
/// of the route that produced it.
Future<Object?> _runMiddleware(
    List<RouteMatch> matches, Uri location, Object? extra) async {
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    for (final guard in match.route.middleware) {
      final MiddlewareResult result;
      try {
        result = await guard(RouteContext(
          location: location,
          params: match.params,
          match: match,
          extra: extra,
        ));
      } catch (error) {
        return (Halt(error), i);
      }
      switch (result) {
        case Next():
          continue;
        case Redirect():
          return result;
        case Halt():
          return (result, i);
      }
    }
  }
  return null;
}

Future<RouterSnapshot> _runLoaders(
    List<RouteMatch> matches, Uri location, Object? extra) async {
  final data = <Route, Object?>{};
  Object? failure;
  int? failureIndex;

  await Future.wait([
    for (var i = 0; i < matches.length; i++)
      if (matches[i].route.loader case final loader?)
        Future(() async {
          final match = matches[i];
          try {
            data[match.route] = await loader(LoaderContext(
              location: location,
              params: match.params,
              match: match,
              extra: extra,
            ));
          } catch (error) {
            // Keep the shallowest failure: it owns the widest error boundary,
            // and reporting a child's failure inside a parent that also failed
            // would be misleading.
            if (failureIndex == null || i < failureIndex!) {
              failure = error;
              failureIndex = i;
            }
          }
        })
  ]);

  return RouterSnapshot(
    location: location,
    matches: matches,
    data: data,
    extra: extra,
    error: failure,
    errorIndex: failureIndex,
  );
}

/// The snapshot to hydrate with: the server's, when it travelled intact.
///
/// Call this in a client entrypoint before `hydrateApp`. It reuses the data the
/// server already fetched when every loader could be encoded, and otherwise
/// runs the loaders itself — either way the first client render matches the
/// markup it is adopting.
///
/// ```dart
/// void main() async {
///   final json = readTransferScript();          // your <script> tag
///   final snapshot = await hydrateSnapshot(routes, currentUri(), json);
///   hydrateApp(use(App, {'routes': routes, 'snapshot': snapshot}));
/// }
/// ```
Future<RouterSnapshot?> hydrateSnapshot(
  List<Route> routes,
  Uri location,
  String? transferJson, {
  Object? extra,
}) async {
  if (transferJson != null) {
    final restored =
        RouterSnapshot.fromTransferJson(routes, transferJson, extra: extra);
    if (restored != null &&
        sameLocation(restored.location, location) &&
        restored.isComplete) {
      return restored;
    }
  }
  final resolution = await resolveLocation(routes, location, extra: extra);
  return switch (resolution) {
    RouteResolved(:final snapshot) => snapshot,
    _ => null,
  };
}

/// Whether two locations name the same page, query string included.
///
/// The query is part of what a loader saw, so ignoring it means a cached
/// document for `?filter=done` can hydrate under `?filter=all` and show the
/// wrong data with no way to notice. Parameter *order* is not meaningful, so it
/// is normalised away.
bool sameLocation(Uri a, Uri b) {
  if (_path(a) != _path(b)) return false;
  final left = a.queryParameters;
  final right = b.queryParameters;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

String _path(Uri uri) {
  var path = uri.path;
  if (!path.startsWith('/')) path = '/$path';
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// Resolves a redirect target that may be relative, keeping any query string.
Uri _resolveAgainst(Uri current, String location) {
  final parsed = Uri.parse(location);
  if (parsed.hasScheme || location.startsWith('/')) {
    return Uri(
      path: parsed.path.isEmpty ? '/' : parsed.path,
      query: parsed.hasQuery ? parsed.query : null,
    );
  }
  return current.resolve(location);
}
