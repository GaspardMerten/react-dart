/// File-system routing: a directory of pages in, a `Route` tree out.
///
/// The model is TanStack Router's rather than Next.js's, and the difference is
/// the whole point. Next resolves files at runtime; this **generates the route
/// table you would otherwise have written by hand**, as ordinary [Route]
/// objects. Nothing scans a directory when your app starts, the server and the
/// browser share one table, and everything the hand-written form can do stays
/// available — a route the conventions cannot express is still just a `Route`
/// you add to the list.
///
/// It also keeps the property that makes the router safe to refactor. Loader
/// data is read by route *object*, not by name, so the generated table declares
/// `final todoIdRoute = Route(…)` and a page says `useLoaderData(todoIdRoute)`.
/// There is no string to mistype and no two routes that can collide.
///
/// ## The conventions
///
/// ```
/// routes/
///   layout.dartx              the shell; renders <Outlet/>
///   page.dartx                /
///   stats/page.dartx          /stats
///   todo/[id]/page.dartx      /todo/:id
///   todo/[id]/error.dartx     what renders when that route's loader throws
///   todo/[id]/edit/page.dartx /todo/:id/edit
///   (marketing)/about/page.dartx   /about — a parenthesised folder groups
///                                  files without adding a path segment
///   [...rest]/page.dartx      the catch-all
/// ```
///
/// A `layout.dartx` wraps its own directory and everything below it, and a
/// `page.dartx` beside one becomes that layout's index route — the same nesting
/// rule Next uses, because it is the one people already know.
///
/// ## What a page file may declare
///
/// Beside its component, a page can declare any of `loader`, `middleware`,
/// `encode`, `decode` and `title` at the top level. They are picked up by name,
/// syntactically, exactly as `@component` and `@scoped` are:
///
/// ```dart
/// Component TodoPage() => …;
///
/// Future<Todo> loader(LoaderContext context) =>
///     fetchTodo(context.params['id']!);
/// const middleware = [requireSignedIn];
/// ```
library;

import '../dartx/css.dart' show scopeIdFor;

/// One file the conventions recognise.
enum RouteFileKind { page, layout, error }

/// The file names that produce a route, in both extensions.
///
/// Everything else under the routes directory is ordinary code — a component, a
/// helper — and is never read by the generator.
const routeFileNames = {
  'page.dartx', 'page.dart',
  'layout.dartx', 'layout.dart',
  'error.dartx', 'error.dart',
};

/// A file found under the routes directory.
final class RouteFile {
  const RouteFile({
    required this.path,
    required this.kind,
    required this.component,
    this.declares = const {},
  });

  /// Slash-separated and relative to the routes directory, without the file:
  /// `todo/[id]`, or `''` for the root.
  final String path;
  final RouteFileKind kind;

  /// The `Component` function the file declares.
  final String component;

  /// Which of `loader`, `middleware`, `encode`, `decode`, `title` it declares.
  final Set<String> declares;
}

/// Reads a route file's source for everything the generator needs.
///
/// Syntactic, like the rest of the toolchain: no resolution, no reading of
/// other files, so the builder stays fast and cannot deadlock on itself.
RouteFile? readRouteFile(String path, String source) {
  final file = path.split('/').last;
  final kind = switch (file) {
    'page.dartx' || 'page.dart' => RouteFileKind.page,
    'layout.dartx' || 'layout.dart' => RouteFileKind.layout,
    'error.dartx' || 'error.dart' => RouteFileKind.error,
    _ => null,
  };
  if (kind == null) return null;

  final component = _componentIn(source);
  if (component == null) return null;

  final directory = path.contains('/')
      ? path.substring(0, path.lastIndexOf('/'))
      : '';

  return RouteFile(
    path: directory,
    kind: kind,
    component: component,
    declares: {
      for (final name in const ['loader', 'middleware', 'encode', 'decode', 'title'])
        if (_declares(source, name)) name,
    },
  );
}

String? _componentIn(String source) =>
    RegExp(r'\bComponent\s+([A-Za-z_$][\w$]*)\s*\(').firstMatch(source)?.group(1);

bool _declares(String source, String name) => RegExp(
      '^(?:const|final|[A-Za-z_\$][\\w<>,?\\s\$]*)\\s+$name\\s*[=(]',
      multiLine: true,
    ).hasMatch(source);

/// The Dart source of the generated route table.
///
/// [files] maps a path relative to the routes directory to that file's source.
/// [importPrefix] is prepended to every generated import, so the output can sit
/// beside the routes directory or above it.
String generateRoutes(Map<String, String> files, {String importPrefix = ''}) {
  final found = <RouteFile>[];
  for (final entry in files.entries) {
    final file = readRouteFile(entry.key, entry.value);
    if (file != null) found.add(file);
  }
  if (found.isEmpty) return _emptyTable();

  // Aliased imports, so two pages may both declare `loader` without colliding.
  final aliases = <String, String>{};
  final imports = <String>[];
  final ordered = [...files.keys]..sort();
  for (final path in ordered) {
    final file = readRouteFile(path, files[path]!);
    if (file == null) continue;
    final alias = '_${_identifier(path.replaceAll(RegExp(r'\.dartx?$'), ''))}';
    aliases[path] = alias;
    final target = path.endsWith('.dartx') ? '$path.dart' : path;
    final uri = '$importPrefix$target';
    // A `\$id` folder is a perfectly good path and a string interpolation, so
    // the URI is written raw when it contains one.
    final quoted = uri.contains(r'$') ? "r'$uri'" : "'$uri'";
    imports.add('import $quoted as $alias;');
  }

  final tree = _Node.root();
  for (final path in ordered) {
    final file = readRouteFile(path, files[path]!);
    if (file == null) continue;
    tree.add(file.path.isEmpty ? const [] : file.path.split('/'), file, path);
  }

  final declarations = <String>[];
  final taken = <String>{};
  final roots = tree.emit(aliases, declarations, const [], const [], taken);

  return '''
// GENERATED from the routes directory — do not edit.
//
// Every route below is an ordinary `Route`, so anything the file conventions
// cannot express can still be written by hand and added to `routes`.
//
// ignore_for_file: type=lint
library;

import 'package:reactx/router.dart';

${imports.join('\n')}

${declarations.join('\n\n')}

/// The route table, in the shape `RouterScope` expects.
final routes = <Route>[
${roots.map((r) => '  $r,').join('\n')}
];
''';
}

String _emptyTable() => '''
// GENERATED from the routes directory — do not edit.
//
// No `page.dartx` was found, so there is nothing to route to yet.
//
// ignore_for_file: type=lint
library;

import 'package:reactx/router.dart';

final routes = <Route>[];
''';

/// A directory in the routes tree.
final class _Node {
  _Node(this.segment);
  _Node.root() : segment = '';

  final String segment;
  final Map<String, _Node> children = {};
  RouteFile? page;
  RouteFile? layout;
  RouteFile? error;
  String? pagePath;
  String? layoutPath;
  String? errorPath;

  void add(List<String> segments, RouteFile file, String path) {
    if (segments.isEmpty) {
      switch (file.kind) {
        case RouteFileKind.page:
          page = file;
          pagePath = path;
        case RouteFileKind.layout:
          layout = file;
          layoutPath = path;
        case RouteFileKind.error:
          error = file;
          errorPath = path;
      }
      return;
    }
    final head = segments.first;
    (children[head] ??= _Node(head)).add(segments.skip(1).toList(), file, path);
  }

  /// Emits declarations for this node and returns the identifiers a parent
  /// should list as its children.
  ///
  /// [pending] are path segments from ancestors that produced no route of their
  /// own — a plain folder contributes to the path of whatever is below it.
  /// [ancestry] is the whole path so far, including the parts a layout already
  /// consumed. Names come from it rather than from [pending], so two different
  /// `edit/` folders do not both want to be `editRoute`.
  List<String> emit(
    Map<String, String> aliases,
    List<String> out,
    List<String> pending,
    List<String> ancestry,
    Set<String> taken,
  ) {
    final own = [...pending, if (segment.isNotEmpty) ..._pathOf(segment)];
    final full = [...ancestry, if (segment.isNotEmpty) ..._pathOf(segment)];

    // A layout owns everything below it; without one, children carry the path
    // forward themselves.
    if (layout != null) {
      final childIds = <String>[];
      if (page != null) {
        childIds.add(_declare(
            out, aliases, page!, pagePath!, const [], full, taken,
            index: true, error: error, errorPath: errorPath));
      }
      for (final child in _sorted(children)) {
        childIds.addAll(child.emit(aliases, out, const [], full, taken));
      }
      final id = _declare(out, aliases, layout!, layoutPath!, own, full, taken,
          children: childIds,
          error: page == null ? error : null,
          errorPath: page == null ? errorPath : null);
      return [id];
    }

    final ids = <String>[];
    if (page != null) {
      final childIds = <String>[
        for (final child in _sorted(children))
          ...child.emit(aliases, out, const [], full, taken)
      ];
      ids.add(_declare(out, aliases, page!, pagePath!, own, full, taken,
          children: childIds, error: error, errorPath: errorPath));
    } else {
      for (final child in _sorted(children)) {
        ids.addAll(child.emit(aliases, out, own, full, taken));
      }
    }
    return ids;
  }

  Iterable<_Node> _sorted(Map<String, _Node> children) {
    final keys = [...children.keys]..sort((a, b) {
        // A catch-all is written last for readability; matching is ranked by
        // specificity, so the order genuinely does not decide anything.
        final wildA = a.startsWith('[...');
        final wildB = b.startsWith('[...');
        if (wildA != wildB) return wildA ? 1 : -1;
        return a.compareTo(b);
      });
    return keys.map((k) => children[k]!);
  }
}

/// `[id]` -> `:id`, `[...rest]` -> `*`, `(group)` -> nothing.
///
/// TanStack's own spelling is accepted too — `$id` for a parameter and a lone
/// `$` for the catch-all — because people arriving from it type that first.
List<String> _pathOf(String segment) {
  if (segment.startsWith('(') && segment.endsWith(')')) return const [];
  if (segment.startsWith('[...') && segment.endsWith(']')) return const ['*'];
  if (segment.startsWith('[') && segment.endsWith(']')) {
    return [':${segment.substring(1, segment.length - 1)}'];
  }
  if (segment == r'$') return const ['*'];
  if (segment.startsWith(r'$')) return [':${segment.substring(1)}'];
  return [segment];
}

String _declare(
  List<String> out,
  Map<String, String> aliases,
  RouteFile file,
  String filePath,
  List<String> path,
  List<String> full,
  Set<String> taken, {
  bool index = false,
  List<String> children = const [],
  RouteFile? error,
  String? errorPath,
}) {
  final alias = aliases[filePath]!;
  final id = _unique(
    _routeIdentifier(full,
        index: index, layout: file.kind == RouteFileKind.layout),
    taken,
  );

  final fields = <String>[
    if (index) '  index: true',
    if (!index && path.isNotEmpty) "  path: '${path.join('/')}'",
    if (!index && path.isEmpty && file.kind != RouteFileKind.layout) '  index: true',
    '  element: const $alias.${file.component}Props()',
    for (final name in const ['loader', 'middleware', 'encode', 'decode', 'title'])
      if (file.declares.contains(name)) '  $name: $alias.$name',
    if (error != null && errorPath != null)
      '  errorElement: const ${aliases[errorPath]!}.${error.component}Props()',
    if (children.isNotEmpty)
      '  children: [\n${children.map((c) => '    $c,').join('\n')}\n  ]',
  ];

  out.add('final $id = Route(\n${fields.join(',\n')},\n);');
  return id;
}

/// Keeps names unique when two different paths reduce to the same words.
String _unique(String name, Set<String> taken) {
  if (taken.add(name)) return name;
  for (var i = 2;; i++) {
    if (taken.add('$name$i')) return '$name$i';
  }
}

/// `todo/:id` -> `todoIdRoute`. Stable, so a page can name its own route.
String _routeIdentifier(List<String> path, {bool index = false, bool layout = false}) {
  // A catch-all has no word in it at all, and would otherwise be named as
  // though it were the index.
  if (path.isNotEmpty && path.last == '*') return 'catchAllRoute';

  final words = path
      .expand((s) => s.split(RegExp(r'[^A-Za-z0-9]+')))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return layout ? 'rootRoute' : 'indexRoute';

  final name = StringBuffer(words.first.toLowerCase());
  for (final word in words.skip(1)) {
    name
      ..write(word[0].toUpperCase())
      ..write(word.substring(1).toLowerCase());
  }
  if (index) name.write('Index');
  return '$name${layout ? 'Layout' : ''}Route';
}

String _identifier(String path) {
  final cleaned = path.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  // A leading digit is not a Dart identifier, and a path may well start with
  // one; the scope helper gives a stable suffix for anything unusable.
  return RegExp(r'^[A-Za-z_]').hasMatch(cleaned)
      ? cleaned
      : 'r${scopeIdFor(path)}';
}
