/// The server: resolves any URL, renders it to HTML, and serves the client
/// bundle.
///
/// ```
/// dart run build_runner build                                          # .dartx -> .dart
/// dart compile js -O2 example/todo_app/main.dart -o example/todo_app/main.dart.js
/// dart run example/todo_app/server.dart                                # http://localhost:8080
/// ```
///
/// There is no `index.html` anywhere in this example. Every response is
/// rendered on demand from the same components the browser then hydrates, which
/// is what makes these real URLs rather than client-side illusions:
/// `curl -s localhost:8080/todo/2` returns the finished page, todo included.
///
/// The interesting part is that this file barely knows the app. It hands the
/// request to `resolveLocation` and then does what the answer says:
///
/// * [RouteRedirected] — a guard refused, so answer 302 and let the browser ask
///   again. Rendering the sign-in page under `/todo/2/edit` would put the wrong
///   URL in the address bar and in everyone's history.
/// * [RouteNotFound], or a match that fell through to the catch-all — 404, so
///   crawlers and uptime checks agree with the human reading the page.
/// * [RouteResolved] — render it, and embed what the loaders returned so the
///   browser does not fetch it all over again.
library;

import 'dart:io';

import 'package:reactx/reactx.dart';
import 'package:reactx/router.dart';

import 'src/app.dartx.dart';
import 'src/data/todo_api.dart';
import 'src/models/session.dart';
import 'src/routes.dart';
import 'src/styles.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(_option(args, '--port') ?? '') ?? 8080;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('reactx todo app → http://localhost:$port');
  stdout.writeln('try: /  /todo/2  /todo/2/edit  /todo/999  /stats  /about');

  await for (final request in server) {
    try {
      await _handle(request);
    } catch (error, stack) {
      stderr.writeln('$error\n$stack');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }
}

Future<void> _handle(HttpRequest request) async {
  final path = normalizePath(request.uri.path);

  // The dart2js bundle and its source map sit next to this file.
  if (path == '/main.dart.js' || path == '/main.dart.js.map') {
    return _serveAsset(request, path.substring(1));
  }
  if (path == '/favicon.ico') {
    request.response.statusCode = HttpStatus.noContent;
    return request.response.close();
  }

  // Setting a cookie is the server's job, so signing in and out are ordinary
  // endpoints rather than routes. They are deliberately *not* `/signin`: that
  // is the page the guard redirects to, and if visiting it signed you in the
  // guard would be decorative.
  if (path == '/session/in') return _setSession(request, signedIn: true);
  if (path == '/signout') return _setSession(request, signedIn: false);

  return _servePage(request);
}

/// Resolves [request] and writes whatever the answer turns out to be.
Future<void> _servePage(HttpRequest request) async {
  final session =
      Session.fromCookieHeader(request.headers.value(HttpHeaders.cookieHeader));

  final resolution = await resolveLocation(
    routes,
    request.uri,
    // A redirect is an HTTP answer here, not something to follow internally.
    followRedirects: false,
    // Who is asking, as a value. Two requests resolved concurrently in this
    // one isolate cannot see each other's session — the reason this is a
    // parameter rather than a global.
    extra: session,
  );

  switch (resolution) {
    case RouteRedirected(:final location):
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, location);
      return request.response.close();

    case RouteNotFound():
      return _writeHtml(request, HttpStatus.notFound,
          '<!doctype html><meta charset="utf-8"><title>Not found</title>'
          '<p>No route matched.');

    case RouteResolved(:final snapshot):
      final info = pageInfoFor(snapshot.matches);
      final html = renderToDocument(
        // The snapshot is a *prop*, not ambient state — the same tree renders
        // any location, and one server can render several at once without them
        // interfering.
        AppProps(snapshot: snapshot),
        title: info.title,
        head: '$styles\n'
            '<meta name="description" content="${_attr(info.description)}">\n'
            '${_transferScript(snapshot)}',
        bootstrapScript: '/main.dart.js',
      );

      request.response
        ..statusCode = _statusFor(snapshot)
        ..headers.contentType = ContentType.html
        ..headers.set('cache-control', 'no-store')
        ..write(html);
      return request.response.close();
  }
}

/// The status code a rendered page deserves.
///
/// The page is rendered either way — a human gets the error boundary's
/// explanation rather than a bare status line — but the *code* has to tell the
/// truth, because crawlers, caches and uptime checks read only that. A missing
/// todo is a 404 whether you asked for `/nope` or for `/todo/999`.
int _statusFor(RouterSnapshot snapshot) {
  if (isNotFound(snapshot.matches)) return HttpStatus.notFound;
  return switch (snapshot.error) {
    null => HttpStatus.ok,
    TodoNotFound() => HttpStatus.notFound,
    _ => HttpStatus.internalServerError,
  };
}

/// The loaders' results, on their way to the browser.
///
/// Only routes with an `encode` travel; the rest are re-loaded on the client,
/// which is the safe default for values JSON cannot express.
///
/// Every `<` becomes its `<` escape — same JSON, but a todo titled
/// `</script>` can no longer close the tag early and turn its own title into
/// markup. JSON has no structural `<`, so this only ever touches string
/// contents.
String _transferScript(RouterSnapshot snapshot) {
  final json = snapshot.toTransferJson().replaceAll('<', r'\u003c');
  return '<script id="$routerTransferId" type="application/json">$json</script>';
}

/// Flips the demo session cookie and sends you back where you were going.
Future<void> _setSession(HttpRequest request, {required bool signedIn}) async {
  final next = request.uri.queryParameters['next'] ?? '/';
  final cookie = Cookie(sessionCookie, signedIn ? '1' : '')
    ..path = '/'
    ..httpOnly = false // the client half reads it too, to resolve the same way
    ..maxAge = signedIn ? 3600 : 0;

  request.response
    ..statusCode = HttpStatus.found
    ..cookies.add(cookie)
    // Only same-site paths, so `?next=` cannot be used to bounce someone to
    // another origin.
    ..headers.set(HttpHeaders.locationHeader,
        next.startsWith('/') && !next.startsWith('//') ? next : '/');
  await request.response.close();
}

Future<void> _serveAsset(HttpRequest request, String name) async {
  final file = File.fromUri(Platform.script.resolve(name));
  if (!file.existsSync()) {
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('$name is missing — run:\n'
          '  dart compile js -O2 example/todo_app/main.dart '
          '-o example/todo_app/main.dart.js\n');
    return request.response.close();
  }

  request.response.headers.contentType = name.endsWith('.map')
      ? ContentType('application', 'json')
      : ContentType('application', 'javascript');
  await request.response.addStream(file.openRead());
  await request.response.close();
}

Future<void> _writeHtml(HttpRequest request, int status, String body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.html
    ..write(body);
  await request.response.close();
}

String _attr(String value) => value.replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
