/// Who is asking — the value a guard needs and the URL cannot give it.
///
/// This is passed to `resolveLocation(..., extra: session)` by whichever half
/// of the app is resolving: the server builds it from the request's cookie, the
/// browser from `document.cookie`. It is deliberately *not* a global. One
/// server process renders many users' pages at once, and a global would let one
/// request's identity leak into another's markup.
library;

/// The cookie both halves agree on. A real app would sign this.
const sessionCookie = 'reactx_demo_session';

class Session {
  const Session({this.signedIn = false});

  final bool signedIn;

  /// Reads a session out of a raw `Cookie:` header value, from either side.
  factory Session.fromCookieHeader(String? header) => Session(
        signedIn: header != null && header.contains('$sessionCookie=1'),
      );
}
