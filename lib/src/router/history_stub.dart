/// VM/server implementation of the router's host hooks.
///
/// There is no ambient location on the server: the request path is handed to
/// the tree as a prop (see `server.dart`), so [currentPath] is only a fallback.
/// Navigation and Back/Forward do not exist either, which is why the other two
/// are no-ops rather than errors — the same component code has to run here.
library;

/// The default path when nothing supplies one.
String currentPath() => '/';

/// No session history off the browser.
void pushPath(String path) {}

/// No session history off the browser.
void replacePath(String path) {}

/// Nothing to subscribe to; hands back a no-op cleanup.
void Function() listenPopState(void Function(String path) onPath) => () {};
