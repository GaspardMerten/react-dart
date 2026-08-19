// GENERATED from the routes directory — do not edit.
//
// Every route below is an ordinary `Route`, so anything the file conventions
// cannot express can still be written by hand and added to `routes`.
//
// ignore_for_file: type=lint
library;

import 'package:reactx/router.dart';

import 'routes/[...rest]/page.dartx.dart' as __rest_page;
import 'routes/about/page.dartx.dart' as _about_page;
import 'routes/layout.dartx.dart' as _layout;
import 'routes/page.dartx.dart' as _page;
import 'routes/signin/page.dartx.dart' as _signin_page;
import 'routes/stats/page.dartx.dart' as _stats_page;
import 'routes/todo/[id]/edit/page.dartx.dart' as _todo_id_edit_page;
import 'routes/todo/[id]/error.dartx.dart' as _todo_id_error;
import 'routes/todo/[id]/page.dartx.dart' as _todo_id_page;

final indexRoute = Route(
  index: true,
  element: const _page.TodosPageProps(),
  title: _page.title,
);

final aboutRoute = Route(
  path: 'about',
  element: const _about_page.AboutPageProps(),
  title: _about_page.title,
);

final signinRoute = Route(
  path: 'signin',
  element: const _signin_page.SignInPageProps(),
  title: _signin_page.title,
);

final statsRoute = Route(
  path: 'stats',
  element: const _stats_page.StatsPageProps(),
  title: _stats_page.title,
);

final todoIdEditRoute = Route(
  path: 'edit',
  element: const _todo_id_edit_page.TodoEditPageProps(),
  middleware: _todo_id_edit_page.middleware,
  title: _todo_id_edit_page.title,
);

final todoIdRoute = Route(
  path: 'todo/:id',
  element: const _todo_id_page.TodoDetailPageProps(),
  loader: _todo_id_page.loader,
  encode: _todo_id_page.encode,
  decode: _todo_id_page.decode,
  title: _todo_id_page.title,
  errorElement: const _todo_id_error.TodoErrorPageProps(),
  children: [
    todoIdEditRoute,
  ],
);

final catchAllRoute = Route(
  path: '*',
  element: const __rest_page.NotFoundPageProps(),
  title: __rest_page.title,
);

final rootRoute = Route(
  element: const _layout.LayoutProps(),
  children: [
    indexRoute,
    aboutRoute,
    signinRoute,
    statsRoute,
    todoIdRoute,
    catchAllRoute,
  ],
);

/// The route table, in the shape `RouterScope` expects.
final routes = <Route>[
  rootRoute,
];
