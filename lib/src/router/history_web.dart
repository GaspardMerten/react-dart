/// Browser implementation of the router's host hooks.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The location the browser is currently showing, query string included.
///
/// The query is part of the location, not decoration on it: a router that drops
/// it cannot round-trip `?filter=done` through a navigation, and the server
/// would render a different page than the client.
String currentPath() =>
    '${web.window.location.pathname}${web.window.location.search}';

/// Adds an entry to the session history without reloading the page.
void pushPath(String path) => web.window.history.pushState(null, '', path);

/// Swaps the current entry instead of adding one — for redirects, where going
/// Back should not land the user on the page that redirected them.
void replacePath(String path) =>
    web.window.history.replaceState(null, '', path);

/// Calls [onPath] when the user presses Back or Forward. Returns the
/// unsubscribe function, which is exactly the shape `useEffect` wants.
void Function() listenPopState(void Function(String path) onPath) {
  void handle(web.Event _) => onPath(currentPath());

  final listener = handle.toJS;
  web.window.addEventListener('popstate', listener);
  return () => web.window.removeEventListener('popstate', listener);
}
