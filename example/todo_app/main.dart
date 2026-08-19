/// The browser half. Compile with:
///
/// ```
/// dart compile js -O2 example/todo_app/main.dart -o example/todo_app/main.dart.js
/// ```
///
/// Hydration has exactly one rule: the first client render must produce the
/// tree the server already wrote. That is why this entrypoint resolves the
/// location *before* mounting rather than rendering a placeholder and filling
/// it in — `hydrateSnapshot` reuses the data the server put in the page when it
/// travelled intact, and runs the loaders itself when it did not.
library;

import 'dart:async';

import 'package:reactx/dom.dart';
import 'package:reactx/router.dart';
import 'package:web/web.dart' as web;

import 'src/app.dartx.dart';
import 'src/models/session.dart';
import 'src/routes.dart';

Future<void> main() async {
  // The server's loader results, if they travelled. Null on a page the server
  // could not encode, which just means the loaders run again here.
  final transfer = web.document.getElementById(routerTransferId)?.textContent;

  // Who is asking. The server reads this from the request's `Cookie:` header
  // and the browser from `document.cookie`, so the guards reach the same
  // verdict on both sides and the hydrated markup matches.
  final session = Session.fromCookieHeader(web.document.cookie);

  final snapshot = await hydrateSnapshot(
    routes,
    Uri.parse(currentPath()),
    transfer,
    extra: session,
  );

  hydrateApp(AppProps(snapshot: snapshot));
}
