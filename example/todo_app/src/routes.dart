/// Everything about routing that the file conventions do not cover.
///
/// The table itself is generated: `routes/` maps a folder to a URL, so there is
/// no list here to keep in sync with the pages. What is left is the handful of
/// things a directory layout cannot express — a guard, the shape of page
/// metadata, and two questions the server asks about a resolved location — plus
/// a re-export, so the rest of the app has one import rather than two.
///
/// ```
/// routes/
///   layout.dartx              the chrome, with an <Outlet />
///   page.dartx                /
///   about/page.dartx          /about
///   signin/page.dartx         /signin
///   stats/page.dartx          /stats
///   todo/[id]/page.dartx      /todo/:id   — loader, encode, decode, title
///   todo/[id]/error.dartx                 — rendered when that loader throws
///   todo/[id]/edit/page.dartx /todo/:id/edit — middleware
///   [...rest]/page.dartx      the catch-all
/// ```
///
/// Nothing scans that directory at runtime. `dart run build_runner build`
/// writes `routes.g.dart`, an ordinary `Route` tree — open it and you will find
/// the file this example used to have, only nobody typed it. A route the
/// conventions cannot express is still a `Route` you can add to the list.
library;

import 'package:reactx/router.dart';

import 'models/session.dart';
import 'routes.g.dart';

export 'routes.g.dart';

/// The id of the `<script>` the server's loader results ride in, agreed on by
/// `server.dart` (which writes it) and `main.dart` (which reads it). One
/// constant rather than the same string typed twice.
const routerTransferId = '__reactx_router';

/// Page metadata, hung off [Route.title]. The router never reads it; the server
/// uses it for `<title>` and the description meta tag.
///
/// A page declares its own: `const title = PageInfo('Stats · reactx', '…');`
/// at the top level of the page file, which the generator picks up by name.
class PageInfo {
  const PageInfo(this.title, this.description);
  final String title;
  final String description;
}

/// Sends anyone without a session to the sign-in page, remembering where they
/// were going.
///
/// A guard is a plain function: it gets the location and whatever the caller
/// passed as `extra`, and answers with [Next], [Redirect] or [Halt]. A page
/// opts in with `const middleware = [requireSignedIn];` — see
/// `routes/todo/[id]/edit/page.dartx`, which is protected without knowing it.
MiddlewareResult requireSignedIn(RouteContext context) {
  final session = context.extra;
  if (session is Session && session.signedIn) return const Next();
  return Redirect('/signin?next=${Uri.encodeComponent('${context.location}')}');
}

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
///
/// [catchAllRoute] is generated from `routes/[...rest]/`, and this compares the
/// route *object*. There is no name to mistype.
bool isNotFound(List<RouteMatch> matches) =>
    matches.isNotEmpty && identical(matches.last.route, catchAllRoute);
